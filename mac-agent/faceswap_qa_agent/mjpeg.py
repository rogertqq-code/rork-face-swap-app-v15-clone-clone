from __future__ import annotations

import hashlib
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Callable


@dataclass(frozen=True, slots=True)
class MJPEGFrame:
    sequence: int
    captured_at: float
    data: bytes
    sha256: str
    width: int | None
    height: int | None

    def metadata(self) -> dict[str, object]:
        return {
            "sequence": self.sequence,
            "captured_at": self.captured_at,
            "sha256": self.sha256,
            "byte_size": len(self.data),
            "width": self.width,
            "height": self.height,
            "content_type": "image/jpeg",
        }


class JPEGStreamParser:
    def __init__(self, maximum_frame_bytes: int = 16 * 1024 * 1024) -> None:
        self.maximum_frame_bytes = maximum_frame_bytes
        self._buffer = bytearray()

    def feed(self, chunk: bytes) -> list[bytes]:
        if not chunk:
            return []
        self._buffer.extend(chunk)
        frames: list[bytes] = []
        while True:
            start = self._buffer.find(b"\xff\xd8")
            if start < 0:
                if len(self._buffer) > 2:
                    del self._buffer[:-2]
                break
            if start > 0:
                del self._buffer[:start]
            end = self._buffer.find(b"\xff\xd9", 2)
            if end < 0:
                if len(self._buffer) > self.maximum_frame_bytes:
                    del self._buffer[:-2]
                break
            frame = bytes(self._buffer[: end + 2])
            del self._buffer[: end + 2]
            if len(frame) <= self.maximum_frame_bytes:
                frames.append(frame)
        return frames


class LatestFrameBuffer:
    def __init__(self) -> None:
        self._condition = threading.Condition()
        self._frame: MJPEGFrame | None = None
        self._sequence = 0

    def publish(self, data: bytes, *, captured_at: float | None = None) -> MJPEGFrame:
        with self._condition:
            self._sequence += 1
            width, height = jpeg_dimensions(data)
            frame = MJPEGFrame(
                sequence=self._sequence,
                captured_at=time.time() if captured_at is None else captured_at,
                data=data,
                sha256=hashlib.sha256(data).hexdigest(),
                width=width,
                height=height,
            )
            self._frame = frame
            self._condition.notify_all()
            return frame

    def latest(self) -> MJPEGFrame | None:
        with self._condition:
            return self._frame

    def wait_for_frame(
        self, *, after_sequence: int = 0, timeout: float = 2.0
    ) -> MJPEGFrame | None:
        deadline = time.monotonic() + max(0, timeout)
        with self._condition:
            while self._frame is None or self._frame.sequence <= after_sequence:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                self._condition.wait(remaining)
            return self._frame


class MJPEGClient:
    def __init__(
        self,
        url: str,
        *,
        buffer: LatestFrameBuffer | None = None,
        maximum_frame_bytes: int = 16 * 1024 * 1024,
        opener: Callable[..., object] = urllib.request.urlopen,
    ) -> None:
        if not url.startswith(("http://127.0.0.1:", "http://localhost:", "http://[::1]:")):
            raise ValueError("MJPEG URL must use loopback HTTP")
        self.url = url
        self.buffer = buffer or LatestFrameBuffer()
        self.maximum_frame_bytes = maximum_frame_bytes
        self.opener = opener
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._lock = threading.RLock()
        self._last_error: str | None = None
        self._connected = False

    def start(self) -> None:
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return
            self._stop.clear()
            self._thread = threading.Thread(
                target=self._run, name="faceswap-mjpeg", daemon=True
            )
            self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        thread = self._thread
        if thread is not None:
            thread.join(timeout=5)
        with self._lock:
            self._thread = None
            self._connected = False

    def state(self) -> dict[str, object]:
        latest = self.buffer.latest()
        with self._lock:
            return {
                "url": self.url,
                "connected": self._connected,
                "thread_alive": bool(self._thread and self._thread.is_alive()),
                "last_error": self._last_error,
                "latest": latest.metadata() if latest else None,
            }

    def _run(self) -> None:
        delay = 0.25
        while not self._stop.is_set():
            parser = JPEGStreamParser(self.maximum_frame_bytes)
            request = urllib.request.Request(
                self.url, headers={"Accept": "multipart/x-mixed-replace,image/jpeg"}
            )
            try:
                with self.opener(request, timeout=10) as response:  # type: ignore[attr-defined]
                    with self._lock:
                        self._connected = True
                        self._last_error = None
                    delay = 0.25
                    while not self._stop.is_set():
                        chunk = response.read(65536)
                        if not chunk:
                            raise EOFError("MJPEG stream ended")
                        for frame in parser.feed(chunk):
                            self.buffer.publish(frame)
            except (OSError, EOFError, urllib.error.URLError) as error:
                with self._lock:
                    self._connected = False
                    self._last_error = str(error)
                if self._stop.wait(delay):
                    break
                delay = min(delay * 2, 5.0)
        with self._lock:
            self._connected = False


def jpeg_dimensions(data: bytes) -> tuple[int | None, int | None]:
    if len(data) < 4 or data[:2] != b"\xff\xd8":
        return None, None
    offset = 2
    while offset + 4 <= len(data):
        if data[offset] != 0xFF:
            offset += 1
            continue
        marker = data[offset + 1]
        offset += 2
        if marker in {0xD8, 0xD9} or 0xD0 <= marker <= 0xD7:
            continue
        if offset + 2 > len(data):
            break
        length = int.from_bytes(data[offset : offset + 2], "big")
        if length < 2 or offset + length > len(data):
            break
        if marker in {
            0xC0,
            0xC1,
            0xC2,
            0xC3,
            0xC5,
            0xC6,
            0xC7,
            0xC9,
            0xCA,
            0xCB,
            0xCD,
            0xCE,
            0xCF,
        } and length >= 7:
            height = int.from_bytes(data[offset + 3 : offset + 5], "big")
            width = int.from_bytes(data[offset + 5 : offset + 7], "big")
            return width, height
        offset += length
    return None, None
