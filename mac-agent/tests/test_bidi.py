from __future__ import annotations

import base64
import hashlib
import json
import socket
import struct
import threading
import unittest

from faceswap_qa_agent.bidi import BiDiClient, BiDiError, normalize_bidi_url


class FakeBiDiServer:
    GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    def __init__(self) -> None:
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.error: Exception | None = None
        self.masked_frames = 0

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        self.listener.close()
        self.thread.join(timeout=5)
        if self.error:
            raise self.error

    def _run(self) -> None:
        try:
            connection, _ = self.listener.accept()
            with connection:
                request = bytearray()
                while b"\r\n\r\n" not in request:
                    request.extend(connection.recv(4096))
                headers = {}
                for line in request.decode("iso-8859-1").split("\r\n")[1:]:
                    if ":" in line:
                        name, value = line.split(":", 1)
                        headers[name.lower()] = value.strip()
                key = headers["sec-websocket-key"]
                accept = base64.b64encode(
                    hashlib.sha1((key + self.GUID).encode()).digest()
                ).decode()
                connection.sendall(
                    (
                        "HTTP/1.1 101 Switching Protocols\r\n"
                        "Upgrade: websocket\r\n"
                        "Connection: Upgrade\r\n"
                        f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
                    ).encode()
                )
                while True:
                    opcode, payload, masked = self._read_frame(connection)
                    if masked:
                        self.masked_frames += 1
                    if opcode == 0x8:
                        return
                    if opcode != 0x1:
                        continue
                    message = json.loads(payload)
                    identifier = message["id"]
                    method = message["method"]
                    if method == "session.subscribe":
                        self._send_json(connection, {"id": identifier, "result": None})
                        self._send_json(
                            connection,
                            {
                                "method": "log.entryAdded",
                                "params": {"type": "syslog", "text": "ready"},
                            },
                        )
                    elif method == "faceswap:live.schema":
                        self._send_json(
                            connection,
                            {"id": identifier, "result": {"module": "faceswap:live"}},
                        )
                    elif method == "echo":
                        self._send_json(
                            connection,
                            {"id": identifier, "result": message.get("params")},
                        )
                    elif method == "fail":
                        self._send_json(
                            connection,
                            {"id": identifier, "error": "invalid argument", "message": "failed"},
                        )
        except (OSError, json.JSONDecodeError) as error:
            if not isinstance(error, OSError) or error.errno not in {9, 22}:
                self.error = error

    @staticmethod
    def _read_frame(connection: socket.socket) -> tuple[int, bytes, bool]:
        first, second = _recv_exact(connection, 2)
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", _recv_exact(connection, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", _recv_exact(connection, 8))[0]
        mask = _recv_exact(connection, 4) if masked else b""
        payload = _recv_exact(connection, length)
        if masked:
            payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        return opcode, payload, masked

    @staticmethod
    def _send_json(connection: socket.socket, value: object) -> None:
        payload = json.dumps(value, separators=(",", ":")).encode()
        if len(payload) < 126:
            frame = bytes([0x81, len(payload)]) + payload
        else:
            frame = bytes([0x81, 126]) + struct.pack("!H", len(payload)) + payload
        connection.sendall(frame)


def _recv_exact(connection: socket.socket, length: int) -> bytes:
    result = bytearray()
    while len(result) < length:
        chunk = connection.recv(length - len(result))
        if not chunk:
            raise OSError("socket closed")
        result.extend(chunk)
    return bytes(result)


class BiDiTests(unittest.TestCase):
    def test_normalizes_appium_root_base_path_duplicate_slash(self) -> None:
        self.assertEqual(
            normalize_bidi_url("ws://127.0.0.1:4723//bidi//session"),
            "ws://127.0.0.1:4723/bidi/session",
        )
        with self.assertRaisesRegex(ValueError, "loopback"):
            BiDiClient("ws://example.com/bidi/session")

    def test_real_handshake_commands_events_and_masking(self) -> None:
        server = FakeBiDiServer()
        server.start()
        received: list[dict] = []
        event = threading.Event()

        def handler(value: dict) -> None:
            received.append(value)
            event.set()

        client = BiDiClient(
            f"ws://127.0.0.1:{server.port}//bidi/session",
            timeout_seconds=2,
            event_handler=handler,
        )
        try:
            client.connect()
            client.subscribe(["log.entryAdded"])
            self.assertTrue(event.wait(2))
            self.assertEqual(received[0]["method"], "log.entryAdded")
            result = client.command("faceswap:live.schema")
            self.assertEqual(result["module"], "faceswap:live")
            state = client.state()
            self.assertTrue(state.connected)
            self.assertIn("log.entryAdded", state.subscriptions)
            self.assertGreaterEqual(state.messages_received, 3)
            self.assertGreaterEqual(state.messages_sent, 2)
            with self.assertRaises(BiDiError) as context:
                client.command("fail")
            self.assertEqual(context.exception.code, "bidi_command_failed")
        finally:
            client.close()
            server.stop()
        self.assertGreaterEqual(server.masked_frames, 3)

    def test_concurrent_commands_preserve_frame_and_result_correlation(self) -> None:
        server = FakeBiDiServer()
        server.start()
        client = BiDiClient(
            f"ws://127.0.0.1:{server.port}/bidi/session",
            timeout_seconds=5,
        )
        count = 64
        barrier = threading.Barrier(count)
        results: dict[int, object] = {}
        errors: list[Exception] = []
        result_lock = threading.Lock()

        def worker(index: int) -> None:
            try:
                barrier.wait(timeout=5)
                value = client.command("echo", {"index": index, "text": f"value-{index}"})
                with result_lock:
                    results[index] = value
            except Exception as error:
                with result_lock:
                    errors.append(error)

        try:
            client.connect()
            threads = [
                threading.Thread(target=worker, args=(index,), daemon=True)
                for index in range(count)
            ]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=10)
            self.assertEqual(errors, [])
            self.assertEqual(len(results), count)
            for index in range(count):
                self.assertEqual(
                    results[index], {"index": index, "text": f"value-{index}"}
                )
        finally:
            client.close()
            server.stop()
        self.assertGreaterEqual(server.masked_frames, count)

    def test_outbound_message_limit_is_enforced(self) -> None:
        client = BiDiClient(
            "ws://127.0.0.1:12345/bidi/session", maximum_message_bytes=32
        )
        client._connected = True
        client._socket = mock_socket = _RecordingSocket()
        try:
            with self.assertRaises(BiDiError) as context:
                client.send({"data": "x" * 100})
            self.assertEqual(context.exception.code, "bidi_message_too_large")
            self.assertEqual(mock_socket.data, b"")
        finally:
            client._connected = False
            client._socket = None


class _RecordingSocket:
    def __init__(self) -> None:
        self.data = b""

    def sendall(self, data: bytes) -> None:
        self.data += data


if __name__ == "__main__":
    unittest.main()
