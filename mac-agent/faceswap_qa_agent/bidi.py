from __future__ import annotations

import base64
import hashlib
import json
import os
import queue
import socket
import ssl
import struct
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable, Mapping
from urllib.parse import urlsplit, urlunsplit

from .json_safety import JSONSafetyError, loads_bounded


class BiDiError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True, slots=True)
class BiDiState:
    connected: bool
    url: str
    subscriptions: tuple[str, ...]
    last_error: str | None
    messages_received: int
    messages_sent: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "connected": self.connected,
            "url": self.url,
            "subscriptions": list(self.subscriptions),
            "last_error": self.last_error,
            "messages_received": self.messages_received,
            "messages_sent": self.messages_sent,
        }


class BiDiClient:
    GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    def __init__(
        self,
        url: str,
        *,
        timeout_seconds: float = 30,
        maximum_message_bytes: int = 8 * 1024 * 1024,
        event_handler: Callable[[dict[str, Any]], None] | None = None,
    ) -> None:
        self.url = normalize_bidi_url(url)
        split = urlsplit(self.url)
        if split.scheme not in {"ws", "wss"}:
            raise ValueError("BiDi URL must use ws or wss")
        if split.hostname not in {"127.0.0.1", "::1", "localhost"}:
            raise ValueError("BiDi URL must use a loopback host")
        self._split = split
        self.timeout_seconds = timeout_seconds
        self.maximum_message_bytes = maximum_message_bytes
        self.event_handler = event_handler
        self._socket: socket.socket | ssl.SSLSocket | None = None
        self._reader: threading.Thread | None = None
        self._write_lock = threading.Lock()
        self._state_lock = threading.RLock()
        self._pending: dict[int, queue.Queue[dict[str, Any]]] = {}
        self._next_id = 1
        self._stop = threading.Event()
        self._connected = False
        self._last_error: str | None = None
        self._subscriptions: set[str] = set()
        self._messages_received = 0
        self._messages_sent = 0

    def connect(self) -> None:
        with self._state_lock:
            if self._connected:
                return
            raw = socket.create_connection(
                (self._split.hostname or "127.0.0.1", self._split.port or (443 if self._split.scheme == "wss" else 80)),
                timeout=self.timeout_seconds,
            )
            if self._split.scheme == "wss":
                context = ssl.create_default_context()
                raw = context.wrap_socket(raw, server_hostname=self._split.hostname)
            raw.settimeout(self.timeout_seconds)
            try:
                self._handshake(raw)
            except Exception:
                raw.close()
                raise
            raw.settimeout(1.0)
            self._socket = raw
            self._stop.clear()
            self._connected = True
            self._last_error = None
            self._reader = threading.Thread(
                target=self._reader_loop, name="faceswap-bidi-reader", daemon=True
            )
            self._reader.start()

    def close(self) -> None:
        self._stop.set()
        with self._state_lock:
            stream = self._socket
        if stream is not None:
            try:
                self._send_frame(0x8, b"")
            except Exception:
                pass
            try:
                stream.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            stream.close()
        reader = self._reader
        if reader is not None and reader is not threading.current_thread():
            reader.join(timeout=5)
        self._fail_pending("bidi_closed", "BiDi connection closed")
        with self._state_lock:
            self._socket = None
            self._reader = None
            self._connected = False
            self._subscriptions.clear()

    def command(
        self, method: str, params: Mapping[str, Any] | None = None, *, timeout: float | None = None
    ) -> Any:
        if not isinstance(method, str) or not method or len(method) > 256:
            raise ValueError("BiDi method is invalid")
        with self._state_lock:
            if not self._connected:
                raise BiDiError("bidi_disconnected", "BiDi connection is not active")
            identifier = self._next_id
            self._next_id += 1
            response_queue: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=1)
            self._pending[identifier] = response_queue
        try:
            self.send({"id": identifier, "method": method, "params": dict(params or {})})
            try:
                response = response_queue.get(timeout=timeout or self.timeout_seconds)
            except queue.Empty as error:
                raise BiDiError("bidi_timeout", f"BiDi command timed out: {method}") from error
            if "error" in response:
                detail = response.get("message") or response.get("error") or "BiDi command failed"
                raise BiDiError("bidi_command_failed", str(detail))
            return response.get("result")
        finally:
            with self._state_lock:
                self._pending.pop(identifier, None)

    def subscribe(self, events: list[str] | tuple[str, ...]) -> None:
        normalized = _events(events)
        self.command("session.subscribe", {"events": normalized})
        with self._state_lock:
            self._subscriptions.update(normalized)

    def unsubscribe(self, events: list[str] | tuple[str, ...]) -> None:
        normalized = _events(events)
        self.command("session.unsubscribe", {"events": normalized})
        with self._state_lock:
            self._subscriptions.difference_update(normalized)

    def send(self, payload: Mapping[str, Any]) -> None:
        data = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        if len(data) > self.maximum_message_bytes:
            raise BiDiError("bidi_message_too_large", "BiDi message exceeds configured limit")
        self._send_frame(0x1, data)
        with self._state_lock:
            self._messages_sent += 1

    def state(self) -> BiDiState:
        with self._state_lock:
            return BiDiState(
                connected=self._connected,
                url=self.url,
                subscriptions=tuple(sorted(self._subscriptions)),
                last_error=self._last_error,
                messages_received=self._messages_received,
                messages_sent=self._messages_sent,
            )

    def _handshake(self, stream: socket.socket | ssl.SSLSocket) -> None:
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        port = self._split.port or (443 if self._split.scheme == "wss" else 80)
        host = self._split.hostname or "localhost"
        authority = f"[{host}]:{port}" if ":" in host else f"{host}:{port}"
        target = self._split.path or "/"
        if self._split.query:
            target += "?" + self._split.query
        request = (
            f"GET {target} HTTP/1.1\r\n"
            f"Host: {authority}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        ).encode("ascii")
        stream.sendall(request)
        response = bytearray()
        while b"\r\n\r\n" not in response:
            chunk = stream.recv(4096)
            if not chunk:
                raise BiDiError("bidi_handshake_failed", "BiDi server closed during handshake")
            response.extend(chunk)
            if len(response) > 65536:
                raise BiDiError("bidi_handshake_failed", "BiDi response headers are too large")
        header_block = bytes(response).split(b"\r\n\r\n", 1)[0].decode("iso-8859-1")
        lines = header_block.split("\r\n")
        if len(lines) < 1 or " 101 " not in f" {lines[0]} ":
            raise BiDiError("bidi_handshake_failed", f"unexpected BiDi response: {lines[0] if lines else ''}")
        headers: dict[str, str] = {}
        for line in lines[1:]:
            if ":" in line:
                name, value = line.split(":", 1)
                headers[name.strip().lower()] = value.strip()
        expected = base64.b64encode(hashlib.sha1((key + self.GUID).encode("ascii")).digest()).decode("ascii")
        if headers.get("sec-websocket-accept") != expected:
            raise BiDiError("bidi_handshake_failed", "BiDi accept key did not match")

    def _reader_loop(self) -> None:
        fragments = bytearray()
        fragment_opcode: int | None = None
        try:
            while not self._stop.is_set():
                try:
                    fin, opcode, payload = self._read_frame()
                except socket.timeout:
                    continue
                if opcode == 0x8:
                    break
                if opcode == 0x9:
                    self._send_frame(0xA, payload)
                    continue
                if opcode == 0xA:
                    continue
                if opcode in {0x1, 0x2}:
                    fragments = bytearray(payload)
                    fragment_opcode = opcode
                elif opcode == 0x0 and fragment_opcode is not None:
                    fragments.extend(payload)
                else:
                    raise BiDiError("bidi_protocol_error", f"unexpected WebSocket opcode {opcode}")
                if len(fragments) > self.maximum_message_bytes:
                    raise BiDiError("bidi_message_too_large", "BiDi event exceeds configured limit")
                if not fin:
                    continue
                if fragment_opcode != 0x1:
                    fragments.clear()
                    fragment_opcode = None
                    continue
                try:
                    message = loads_bounded(
                        fragments,
                        maximum_bytes=self.maximum_message_bytes,
                    )
                except JSONSafetyError as error:
                    raise BiDiError(
                        f"bidi_{error.code}",
                        f"BiDi server JSON was rejected: {error}",
                    ) from error
                fragments.clear()
                fragment_opcode = None
                if not isinstance(message, dict):
                    continue
                with self._state_lock:
                    self._messages_received += 1
                    identifier = message.get("id")
                    pending = self._pending.get(identifier) if isinstance(identifier, int) else None
                if pending is not None:
                    try:
                        pending.put_nowait(message)
                    except queue.Full:
                        pass
                elif "method" in message and self.event_handler is not None:
                    try:
                        self.event_handler(message)
                    except Exception:
                        pass
        except Exception as error:
            with self._state_lock:
                self._last_error = str(error)
            self._fail_pending(getattr(error, "code", "bidi_reader_failed"), str(error))
        finally:
            with self._state_lock:
                self._connected = False

    def _read_frame(self) -> tuple[bool, int, bytes]:
        stream = self._socket
        if stream is None:
            raise BiDiError("bidi_disconnected", "BiDi socket is unavailable")
        header = _recv_exact(stream, 2)
        first, second = header
        fin = bool(first & 0x80)
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", _recv_exact(stream, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", _recv_exact(stream, 8))[0]
        if length > self.maximum_message_bytes:
            raise BiDiError("bidi_message_too_large", "BiDi frame exceeds configured limit")
        mask = _recv_exact(stream, 4) if masked else b""
        payload = _recv_exact(stream, length)
        if masked:
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        return fin, opcode, payload

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        stream = self._socket
        if stream is None:
            raise BiDiError("bidi_disconnected", "BiDi socket is unavailable")
        mask = os.urandom(4)
        length = len(payload)
        header = bytearray([0x80 | opcode])
        if length < 126:
            header.append(0x80 | length)
        elif length <= 65535:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", length))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", length))
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        with self._write_lock:
            stream.sendall(bytes(header) + mask + masked)

    def _fail_pending(self, code: str, message: str) -> None:
        with self._state_lock:
            pending = list(self._pending.values())
        error = {"error": code, "message": message}
        for target in pending:
            try:
                target.put_nowait(error)
            except queue.Full:
                pass


def normalize_bidi_url(url: str) -> str:
    if not isinstance(url, str) or len(url) > 4096:
        raise ValueError("BiDi URL is invalid")
    split = urlsplit(url)
    path = "/" + "/".join(part for part in split.path.split("/") if part)
    return urlunsplit((split.scheme, split.netloc, path, split.query, ""))


def _events(values: list[str] | tuple[str, ...]) -> list[str]:
    if not values or len(values) > 100:
        raise ValueError("BiDi events must contain between 1 and 100 names")
    result: list[str] = []
    for value in values:
        if not isinstance(value, str) or not value or len(value) > 256 or "\0" in value:
            raise ValueError("BiDi event name is invalid")
        result.append(value)
    return sorted(set(result))


def _recv_exact(stream: socket.socket | ssl.SSLSocket, length: int) -> bytes:
    result = bytearray()
    while len(result) < length:
        chunk = stream.recv(length - len(result))
        if not chunk:
            raise BiDiError("bidi_disconnected", "BiDi socket closed")
        result.extend(chunk)
    return bytes(result)
