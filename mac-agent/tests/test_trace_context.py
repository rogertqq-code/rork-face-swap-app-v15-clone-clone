from __future__ import annotations

import unittest
import uuid

from faceswap_qa_agent.trace_context import (
    TraceContext,
    TraceContextError,
    format_traceparent,
    normalize_span_id,
    normalize_uuid,
    parse_traceparent,
)


class TraceContextTests(unittest.TestCase):
    def test_generated_context_is_canonical_and_sampled(self) -> None:
        context = TraceContext.create()
        self.assertEqual(str(uuid.UUID(context.session_trace_id)), context.session_trace_id)
        self.assertEqual(str(uuid.UUID(context.operation_trace_id)), context.operation_trace_id)
        self.assertEqual(len(context.span_id), 16)
        self.assertTrue(context.traceparent.endswith("-01"))
        parsed = parse_traceparent(context.traceparent)
        self.assertEqual(parsed.session_trace_id, context.session_trace_id)
        self.assertEqual(parsed.span_id, context.span_id)

    def test_traceparent_normalizes_uppercase_and_uuid_root(self) -> None:
        root = "12345678-1234-4234-9234-1234567890ab"
        parent = "00-123456781234423492341234567890AB-ABCDEF1234567890-01"
        context = TraceContext.create(
            session_trace_id=root,
            operation_trace_id="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            traceparent=parent,
        )
        self.assertEqual(context.session_trace_id, root)
        self.assertEqual(context.span_id, "abcdef1234567890")
        self.assertEqual(
            context.traceparent,
            "00-123456781234423492341234567890ab-abcdef1234567890-01",
        )

    def test_explicit_root_and_span_mismatch_fail_closed(self) -> None:
        parent = "00-123456781234423492341234567890ab-abcdef1234567890-01"
        with self.assertRaises(TraceContextError) as root_error:
            TraceContext.create(
                session_trace_id="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                traceparent=parent,
            )
        self.assertEqual(root_error.exception.code, "trace_root_mismatch")

        with self.assertRaises(TraceContextError) as span_error:
            TraceContext.create(traceparent=parent, span_id="1111111111111111")
        self.assertEqual(span_error.exception.code, "trace_span_mismatch")

    def test_invalid_and_zero_values_are_rejected(self) -> None:
        for parent in (
            "00-00000000000000000000000000000000-abcdef1234567890-01",
            "00-123456781234423492341234567890ab-0000000000000000-01",
            "00-123456781234423492341234567890ab-abcdef1234567890-03",
            "ff-123456781234423492341234567890ab-abcdef1234567890-01",
            "not-a-traceparent",
        ):
            with self.subTest(parent=parent):
                with self.assertRaises(TraceContextError):
                    parse_traceparent(parent)
        with self.assertRaises(TraceContextError):
            normalize_uuid("00000000-0000-0000-0000-000000000000")
        with self.assertRaises(TraceContextError):
            normalize_span_id("0000000000000000")

    def test_child_keeps_root_and_gets_new_operation_and_span(self) -> None:
        parent = TraceContext.create()
        child = parent.child()
        self.assertEqual(child.session_trace_id, parent.session_trace_id)
        self.assertNotEqual(child.operation_trace_id, parent.operation_trace_id)
        self.assertNotEqual(child.span_id, parent.span_id)
        self.assertEqual(
            parse_traceparent(child.traceparent).session_trace_id,
            parent.session_trace_id,
        )

    def test_document_validation_and_expected_root(self) -> None:
        context = TraceContext.create()
        restored = TraceContext.from_document(
            context.to_dict(), expected_session_trace_id=context.session_trace_id
        )
        self.assertEqual(restored, context)
        with self.assertRaises(TraceContextError):
            TraceContext.from_document({**context.to_dict(), "unknown": True})
        with self.assertRaises(TraceContextError):
            TraceContext.from_document(
                context.to_dict(),
                expected_session_trace_id="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            )

    def test_format_traceparent_unsampled(self) -> None:
        root = "12345678-1234-4234-9234-1234567890ab"
        value = format_traceparent(root, "abcdef1234567890", sampled=False)
        self.assertEqual(
            value,
            "00-123456781234423492341234567890ab-abcdef1234567890-00",
        )
        self.assertFalse(parse_traceparent(value).sampled)


if __name__ == "__main__":
    unittest.main()
