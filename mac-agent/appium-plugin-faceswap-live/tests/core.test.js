'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  normalizeAction,
  normalizeObservation,
  operationTrace,
  parseTraceparent,
  resultEnvelope,
  safeActionSummary,
  schemaCatalog,
  sessionTrace,
} = require('../core');

const bundleId = 'app.rork.face-swap-live-app-v17.qa';

function action(kind, parameters) {
  return normalizeAction({kind, parameters}, {bundleId, maximumTextLength: 128});
}

test('catalog exposes mandatory BiDi commands, events, actions, and observations', () => {
  const catalog = schemaCatalog(bundleId);
  assert.equal(catalog.module, 'faceswap:live');
  assert.deepEqual(catalog.bidi.commands, ['schema', 'observe', 'action']);
  assert.ok(catalog.bidi.events.includes('faceswap:live.actionCompleted'));
  assert.ok(catalog.actions.includes('qa_command'));
  assert.ok(catalog.actions.includes('start_network_monitor'));
  assert.ok(catalog.actions.includes('stop_network_monitor'));
  assert.ok(catalog.observations.includes('combined'));
});

test('tap accepts exactly an element or coordinate pair', () => {
  assert.equal(action('tap', {element_id: 'element-1'}).parameters.element_id, 'element-1');
  assert.equal(action('tap', {x: 10, y: 20}).parameters.y, 20);
  assert.throws(() => action('tap', {}), /requires element_id or x and y/);
  assert.throws(() => action('tap', {element_id: 'e', x: 1, y: 2}), /either element_id or coordinates/);
  assert.throws(() => action('tap', {x: 1}), /requires element_id or x and y/);
});

test('closed schemas reject unknown actions, fields, locators, keys, and directions', () => {
  assert.throws(() => action('shell', {}), /unsupported action kind/);
  assert.throws(() => action('swipe', {direction: 'diagonal'}), /invalid swipe direction/);
  assert.throws(() => action('press_key', {key: 'power'}), /invalid key/);
  assert.throws(() => action('find', {using: 'css selector', value: 'x'}), /unsupported locator/);
  assert.throws(() => action('tap', {element_id: 'e', command: 'whoami'}), /unsupported tap field/);
});

test('app lifecycle is confined to the configured QA bundle', () => {
  assert.equal(action('launch_app', {}).parameters.bundle_id, bundleId);
  assert.throws(
    () => action('launch_app', {bundle_id: 'com.example.other'}),
    /only the configured bundle is allowed/,
  );
});

test('text and QA commands are bounded and redacted from summaries', () => {
  const typed = action('type_text', {text: 'secret value'});
  const typedSummary = safeActionSummary(typed);
  assert.equal(typedSummary.parameters.text_length, 12);
  assert.equal(typedSummary.parameters.text, undefined);
  assert.match(typedSummary.parameters.text_sha256, /^[0-9a-f]{64}$/);

  const qa = action('qa_command', {command: {version: 1, name: 'snapshot'}});
  const qaSummary = safeActionSummary(qa);
  assert.equal(qaSummary.parameters.command, undefined);
  assert.match(qaSummary.parameters.command_sha256, /^[0-9a-f]{64}$/);
  assert.throws(
    () => action('qa_command', {command: {data: 'x'.repeat(512)}}),
    /too large/,
  );
});

test('network monitor actions are parameterless and closed', () => {
  assert.deepEqual(action('start_network_monitor', {}).parameters, {});
  assert.deepEqual(action('stop_network_monitor', {}).parameters, {});
  assert.throws(
    () => action('start_network_monitor', {command: 'tcpdump'}),
    /unsupported start_network_monitor field/,
  );
});

test('observation schemas are closed and trace identifiers are generated', () => {
  const observation = normalizeObservation({kind: 'source_json'});
  assert.equal(observation.kind, 'source_json');
  assert.match(observation.trace_id, /^[0-9a-f-]{36}$/);
  assert.throws(() => normalizeObservation({kind: 'video'}), /unsupported observation/);
  assert.throws(() => normalizeObservation({kind: 'screenshot', extra: true}), /unsupported observation field/);
});

test('session capabilities and operation spans propagate a strict W3C trace', () => {
  const root = '12345678-1234-4234-9234-1234567890ab';
  const parent = '00-123456781234423492341234567890ab-abcdef1234567890-01';
  const driver = {
    caps: {
      'appium:faceswapTraceId': root,
      'appium:faceswapTraceparent': parent,
    },
  };
  const session = sessionTrace(driver);
  assert.equal(session.session_trace_id, root);
  assert.equal(parseTraceparent(parent).span_id, 'abcdef1234567890');

  const operation = operationTrace(
    {trace_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'},
    session,
  );
  assert.equal(operation.session_trace_id, root);
  assert.equal(operation.operation_trace_id, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  assert.match(operation.span_id, /^[0-9a-f]{16}$/);
  assert.match(operation.traceparent, /^00-123456781234423492341234567890ab-/);

  assert.throws(
    () => operationTrace(
      {
        trace_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        session_trace_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      },
      session,
    ),
    /root mismatch/,
  );
});

test('result envelopes preserve root, operation, span, timing, and failures', () => {
  const context = {
    session_trace_id: '12345678-1234-4234-9234-1234567890ab',
    operation_trace_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    span_id: 'abcdef1234567890',
    traceparent: '00-123456781234423492341234567890ab-abcdef1234567890-01',
  };
  const success = resultEnvelope(context, 'tap', 100, {ok: true}, null);
  assert.equal(success.success, true);
  assert.equal(success.session_trace_id, context.session_trace_id);
  assert.equal(success.trace_id, context.operation_trace_id);
  assert.equal(success.span_id, context.span_id);
  assert.deepEqual(success.value, {ok: true});
  const failure = resultEnvelope(context, 'tap', 100, null, new Error('boom'));
  assert.equal(failure.success, false);
  assert.equal(failure.error.message, 'boom');
});
