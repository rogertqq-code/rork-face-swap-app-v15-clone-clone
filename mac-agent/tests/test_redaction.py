from __future__ import annotations

import json
import unittest

from faceswap_qa_agent.redaction import (
    RedactionPolicy,
    digest_metadata,
    redact_lines,
    redact_structured,
    redact_text,
)


class RedactionTests(unittest.TestCase):
    def test_sensitive_values_are_hashed_and_correlation_ids_pass(self) -> None:
        value = {
            "session_trace_id": "12345678-1234-4234-9234-1234567890ab",
            "trace_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "Authorization": "Bearer top-secret-token",
            "nested": {"password": "hunter2", "cookie_value": "abc=123"},
        }
        redacted = redact_structured(value)
        self.assertEqual(redacted["session_trace_id"], value["session_trace_id"])
        self.assertEqual(redacted["trace_id"], value["trace_id"])
        self.assertTrue(redacted["Authorization"]["redacted"])
        self.assertNotIn("hunter2", json.dumps(redacted))
        self.assertNotIn("abc=123", json.dumps(redacted))
        self.assertEqual(len(redacted["nested"]["password"]["sha256"]), 64)

    def test_stringified_json_is_redacted_deterministically(self) -> None:
        source = '{"z":1,"token":"secret-value","a":{"trace_id":"ok"}}'
        first = redact_structured({"payload": source})
        second = redact_structured({"payload": source})
        self.assertEqual(first, second)
        decoded = json.loads(first["payload"])
        self.assertTrue(decoded["token"]["redacted"])
        self.assertEqual(decoded["a"]["trace_id"], "ok")
        self.assertEqual(list(decoded), ["a", "token", "z"])

    def test_text_redaction_masks_bearer_headers_and_assignments(self) -> None:
        text = (
            "Authorization: Bearer ABCDEFGHIJKLMNOP\n"
            "Cookie: session=abc123\n"
            "password=supersecret token: anothersecret"
        )
        redacted = redact_text(text)
        for secret in ("ABCDEFGHIJKLMNOP", "session=abc123", "supersecret", "anothersecret"):
            self.assertNotIn(secret, redacted)
        self.assertIn("Authorization: [REDACTED]", redacted)
        self.assertIn("Cookie: [REDACTED]", redacted)

    def test_depth_node_and_string_limits_fail_closed(self) -> None:
        policy = RedactionPolicy(
            maximum_depth=2,
            maximum_nodes=4,
            maximum_string_bytes=8,
            maximum_text_bytes=32,
        )
        redacted = redact_structured(
            {"a": {"b": {"c": "value"}}, "large": "0123456789"},
            policy=policy,
        )
        encoded = json.dumps(redacted)
        self.assertIn("depth_limit", encoded)
        self.assertIn("string_limit", encoded)
        self.assertNotIn("0123456789", encoded)

    def test_line_budget_is_bounded(self) -> None:
        policy = RedactionPolicy(maximum_text_bytes=12)
        lines = redact_lines(["first\n", "second\n", "third\n"], policy=policy)
        self.assertEqual(lines[-1], "[TRUNCATED]")

    def test_digest_metadata_is_stable(self) -> None:
        first = digest_metadata({"b": 2, "a": 1})
        second = digest_metadata({"a": 1, "b": 2})
        self.assertEqual(first, second)
        self.assertTrue(first["redacted"])


if __name__ == "__main__":
    unittest.main()
