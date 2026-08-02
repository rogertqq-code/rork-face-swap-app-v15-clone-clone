from __future__ import annotations

import json
import unittest

from faceswap_qa_agent.json_safety import (
    JSONSafetyError,
    loads_bounded,
    validate_json_complexity,
)


class JSONSafetyTests(unittest.TestCase):
    def test_accepts_bounded_document(self) -> None:
        value = loads_bounded(
            b'{"items":[1,2,{"ready":true}]}',
            maximum_bytes=1024,
            maximum_depth=8,
            maximum_nodes=32,
        )
        self.assertEqual(value["items"][2]["ready"], True)

    def test_rejects_oversized_and_invalid_json(self) -> None:
        with self.assertRaises(JSONSafetyError) as oversized:
            loads_bounded(b'{"value":"123456"}', maximum_bytes=8)
        self.assertEqual(oversized.exception.code, "json_too_large")

        with self.assertRaises(JSONSafetyError) as invalid:
            loads_bounded(b'{"value":', maximum_bytes=1024)
        self.assertEqual(invalid.exception.code, "invalid_json")

    def test_rejects_excessive_depth(self) -> None:
        value: object = "leaf"
        for _ in range(40):
            value = {"nested": value}
        encoded = json.dumps(value).encode()
        with self.assertRaises(JSONSafetyError) as context:
            loads_bounded(encoded, maximum_bytes=65536, maximum_depth=32)
        self.assertEqual(context.exception.code, "json_too_deep")

    def test_rejects_excessive_node_count(self) -> None:
        with self.assertRaises(JSONSafetyError) as context:
            validate_json_complexity(list(range(101)), maximum_nodes=100)
        self.assertEqual(context.exception.code, "json_too_complex")

    def test_requires_positive_limits_and_supported_source(self) -> None:
        with self.assertRaises(ValueError):
            loads_bounded(b"{}", maximum_bytes=0)
        with self.assertRaises(ValueError):
            validate_json_complexity({}, maximum_depth=0)
        with self.assertRaises(TypeError):
            loads_bounded(123, maximum_bytes=1024)  # type: ignore[arg-type]


if __name__ == "__main__":
    unittest.main()
