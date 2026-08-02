'use strict';

const crypto = require('node:crypto');

const ACTIONS = Object.freeze({
  tap: {allowed: ['element_id', 'x', 'y']},
  double_tap: {allowed: ['element_id', 'x', 'y']},
  touch_and_hold: {allowed: ['element_id', 'x', 'y', 'duration']},
  swipe: {allowed: ['element_id', 'direction', 'velocity'], required: ['direction']},
  drag: {allowed: ['from_x', 'from_y', 'to_x', 'to_y', 'duration'], required: ['from_x', 'from_y', 'to_x', 'to_y']},
  type_text: {allowed: ['element_id', 'text'], required: ['text']},
  clear_text: {allowed: ['element_id'], required: ['element_id']},
  press_key: {allowed: ['key'], required: ['key']},
  find: {allowed: ['using', 'value', 'multiple'], required: ['using', 'value']},
  get_attribute: {allowed: ['element_id', 'name'], required: ['element_id', 'name']},
  set_context: {allowed: ['name'], required: ['name']},
  alert: {allowed: ['action', 'button_label'], required: ['action']},
  launch_app: {allowed: ['bundle_id']},
  activate_app: {allowed: ['bundle_id']},
  terminate_app: {allowed: ['bundle_id']},
  query_app_state: {allowed: ['bundle_id']},
  background_app: {allowed: ['seconds'], required: ['seconds']},
  qa_command: {allowed: ['command'], required: ['command']},
  settings: {allowed: ['mjpegServerFramerate', 'mjpegScalingFactor', 'mjpegServerScreenshotQuality', 'screenshotQuality', 'waitForIdleTimeout', 'animationCoolOffTimeout']},
  start_network_monitor: {allowed: []},
  stop_network_monitor: {allowed: []},
});

const OBSERVATIONS = new Set([
  'screenshot',
  'source_xml',
  'source_json',
  'contexts',
  'orientation',
  'window_rect',
  'device_info',
  'battery_info',
  'combined',
]);

const LOCATORS = new Set([
  'accessibility id',
  'id',
  'class name',
  'xpath',
  '-ios predicate string',
  '-ios class chain',
]);

const KEYS = new Set(['home', 'volumeUp', 'volumeDown']);
const DIRECTIONS = new Set(['up', 'down', 'left', 'right']);
const ALERT_ACTIONS = new Set(['accept', 'dismiss', 'get_buttons', 'get_text']);

function plainObject(value, name) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError(`${name} must be an object`);
  }
  return value;
}

function boundedString(value, name, maximum, allowEmpty = false) {
  if (typeof value !== 'string' || value.length > maximum || (!allowEmpty && value.length === 0) || value.includes('\0')) {
    throw new TypeError(`${name} is invalid`);
  }
  return value;
}

function boundedNumber(value, name, minimum, maximum) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < minimum || value > maximum) {
    throw new TypeError(`${name} must be between ${minimum} and ${maximum}`);
  }
  return value;
}

function closedObject(value, allowed, context) {
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) {
      throw new TypeError(`unsupported ${context} field: ${key}`);
    }
  }
}

function uuidValue(value, name = 'trace_id') {
  boundedString(value, name, 36);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new TypeError(`${name} must be a UUID`);
  }
  const normalized = value.toLowerCase();
  if (normalized === '00000000-0000-0000-0000-000000000000') throw new TypeError(`${name} cannot be all zero`);
  return normalized;
}

function traceId(value) {
  if (value === undefined || value === null || value === '') {
    return crypto.randomUUID();
  }
  return uuidValue(value, 'trace_id');
}

function uuidFromHex(value) {
  return `${value.slice(0, 8)}-${value.slice(8, 12)}-${value.slice(12, 16)}-${value.slice(16, 20)}-${value.slice(20)}`;
}

function uuidHex(value, name = 'session_trace_id') {
  return uuidValue(value, name).replaceAll('-', '');
}

function spanId(value) {
  if (value !== undefined && value !== null && value !== '') {
    boundedString(value, 'span_id', 16);
    const normalized = value.toLowerCase();
    if (!/^[0-9a-f]{16}$/.test(normalized) || normalized === '0000000000000000') throw new TypeError('span_id must be 16 non-zero hexadecimal characters');
    return normalized;
  }
  while (true) {
    const generated = crypto.randomBytes(8).toString('hex');
    if (generated !== '0000000000000000') return generated;
  }
}

function parseTraceparent(value) {
  boundedString(value, 'traceparent', 55);
  const match = value.match(/^00-([0-9a-f]{32})-([0-9a-f]{16})-(00|01)$/i);
  if (!match || match[1] === '00000000000000000000000000000000' || match[2] === '0000000000000000') {
    throw new TypeError('traceparent is invalid');
  }
  const sessionTraceId = uuidFromHex(match[1].toLowerCase());
  const normalizedSpan = match[2].toLowerCase();
  const flags = match[3].toLowerCase();
  return {
    session_trace_id: sessionTraceId,
    span_id: normalizedSpan,
    sampled: flags === '01',
    traceparent: `00-${match[1].toLowerCase()}-${normalizedSpan}-${flags}`,
  };
}

function formatTraceparent(sessionTraceId, operationSpanId, sampled = true) {
  return `00-${uuidHex(sessionTraceId)}-${spanId(operationSpanId)}-${sampled ? '01' : '00'}`;
}

function sessionTrace(driver) {
  const caps = driver.caps || {};
  const opts = driver.opts || {};
  const explicit = caps['appium:faceswapTraceId'] || opts.faceswapTraceId;
  const parentValue = caps['appium:faceswapTraceparent'] || opts.faceswapTraceparent;
  if (!explicit || !parentValue) throw new TypeError('agent-owned live session requires trace capabilities');
  const root = uuidValue(explicit, 'session_trace_id');
  const parent = parseTraceparent(parentValue);
  if (parent.session_trace_id !== root) throw new TypeError('session trace capability mismatch');
  return {...parent, session_trace_id: root};
}

function operationTrace(request, session) {
  if (request.session_trace_id && request.session_trace_id !== session.session_trace_id) throw new TypeError('operation trace root mismatch');
  let operationSpan;
  let sampled = session.sampled;
  if (request.traceparent) {
    const parsed = parseTraceparent(request.traceparent);
    if (parsed.session_trace_id !== session.session_trace_id) throw new TypeError('operation traceparent root mismatch');
    if (request.span_id && request.span_id !== parsed.span_id) throw new TypeError('operation span mismatch');
    operationSpan = parsed.span_id;
    sampled = parsed.sampled;
  } else {
    operationSpan = spanId(request.span_id);
  }
  return {
    session_trace_id: session.session_trace_id,
    operation_trace_id: request.trace_id,
    trace_id: request.trace_id,
    span_id: operationSpan,
    sampled,
    traceparent: formatTraceparent(session.session_trace_id, operationSpan, sampled),
  };
}

function elementOrPoint(parameters, context) {
  const hasElement = parameters.element_id !== undefined;
  const hasX = parameters.x !== undefined;
  const hasY = parameters.y !== undefined;
  if (hasElement && (hasX || hasY)) {
    throw new TypeError(`${context} accepts either element_id or coordinates`);
  }
  if (!hasElement && !(hasX && hasY)) {
    throw new TypeError(`${context} requires element_id or x and y`);
  }
  if (hasElement) {
    boundedString(parameters.element_id, 'element_id', 512);
  } else {
    boundedNumber(parameters.x, 'x', 0, 100000);
    boundedNumber(parameters.y, 'y', 0, 100000);
  }
}

function normalizeAction(value, options = {}) {
  const request = plainObject(value, 'action');
  closedObject(request, ['kind', 'parameters', 'trace_id', 'session_trace_id', 'span_id', 'traceparent'], 'action');
  if (!Object.prototype.hasOwnProperty.call(ACTIONS, request.kind)) {
    throw new TypeError('unsupported action kind');
  }
  const definition = ACTIONS[request.kind];
  const parameters = {...plainObject(request.parameters || {}, 'parameters')};
  closedObject(parameters, definition.allowed, request.kind);
  for (const required of definition.required || []) {
    if (parameters[required] === undefined) {
      throw new TypeError(`${request.kind}.${required} is required`);
    }
  }
  if (['tap', 'double_tap', 'touch_and_hold'].includes(request.kind)) {
    elementOrPoint(parameters, request.kind);
  }
  if (request.kind === 'touch_and_hold') {
    parameters.duration = boundedNumber(parameters.duration ?? 1, 'duration', 0.5, 60);
  }
  if (request.kind === 'swipe') {
    if (!DIRECTIONS.has(parameters.direction)) throw new TypeError('invalid swipe direction');
    if (parameters.element_id !== undefined) boundedString(parameters.element_id, 'element_id', 512);
    if (parameters.velocity !== undefined) boundedNumber(parameters.velocity, 'velocity', 1, 100000);
  }
  if (request.kind === 'drag') {
    for (const key of ['from_x', 'from_y', 'to_x', 'to_y']) boundedNumber(parameters[key], key, 0, 100000);
    parameters.duration = boundedNumber(parameters.duration ?? 0.5, 'duration', 0, 60);
  }
  if (request.kind === 'type_text') {
    boundedString(parameters.text, 'text', options.maximumTextLength || 16384, true);
    if (parameters.element_id !== undefined) boundedString(parameters.element_id, 'element_id', 512);
  }
  if (request.kind === 'clear_text') boundedString(parameters.element_id, 'element_id', 512);
  if (request.kind === 'press_key' && !KEYS.has(parameters.key)) throw new TypeError('invalid key');
  if (request.kind === 'find') {
    if (!LOCATORS.has(parameters.using)) throw new TypeError('unsupported locator strategy');
    boundedString(parameters.value, 'value', 4096);
    parameters.multiple = parameters.multiple === true;
  }
  if (request.kind === 'get_attribute') {
    boundedString(parameters.element_id, 'element_id', 512);
    boundedString(parameters.name, 'name', 128);
  }
  if (request.kind === 'set_context') boundedString(parameters.name, 'name', 256);
  if (request.kind === 'alert') {
    if (!ALERT_ACTIONS.has(parameters.action)) throw new TypeError('invalid alert action');
    if (parameters.button_label !== undefined) boundedString(parameters.button_label, 'button_label', 256);
  }
  if (['launch_app', 'activate_app', 'terminate_app', 'query_app_state'].includes(request.kind)) {
    const bundleId = parameters.bundle_id || options.bundleId;
    if (!bundleId || bundleId !== options.bundleId) throw new TypeError('only the configured bundle is allowed');
    parameters.bundle_id = bundleId;
  }
  if (request.kind === 'background_app') boundedNumber(parameters.seconds, 'seconds', 0, 3600);
  if (request.kind === 'qa_command') {
    plainObject(parameters.command, 'command');
    const encoded = JSON.stringify(parameters.command);
    if (Buffer.byteLength(encoded, 'utf8') > (options.maximumTextLength || 16384)) throw new TypeError('qa command is too large');
  }
  if (request.kind === 'settings' && Object.keys(parameters).length === 0) throw new TypeError('at least one setting is required');
  const normalized = {kind: request.kind, parameters, trace_id: traceId(request.trace_id)};
  if (request.session_trace_id !== undefined) normalized.session_trace_id = uuidValue(request.session_trace_id, 'session_trace_id');
  if (request.span_id !== undefined) normalized.span_id = spanId(request.span_id);
  if (request.traceparent !== undefined) {
    const parent = parseTraceparent(request.traceparent);
    normalized.traceparent = parent.traceparent;
    if (normalized.session_trace_id && normalized.session_trace_id !== parent.session_trace_id) throw new TypeError('action trace root mismatch');
    if (normalized.span_id && normalized.span_id !== parent.span_id) throw new TypeError('action trace span mismatch');
    normalized.session_trace_id = parent.session_trace_id;
    normalized.span_id = parent.span_id;
  }
  return normalized;
}

function normalizeObservation(value) {
  const request = plainObject(value || {}, 'observation');
  closedObject(request, ['kind', 'trace_id', 'session_trace_id', 'span_id', 'traceparent'], 'observation');
  const kind = request.kind || 'combined';
  if (!OBSERVATIONS.has(kind)) throw new TypeError('unsupported observation kind');
  const normalized = {kind, trace_id: traceId(request.trace_id)};
  if (request.session_trace_id !== undefined) normalized.session_trace_id = uuidValue(request.session_trace_id, 'session_trace_id');
  if (request.span_id !== undefined) normalized.span_id = spanId(request.span_id);
  if (request.traceparent !== undefined) {
    const parent = parseTraceparent(request.traceparent);
    normalized.traceparent = parent.traceparent;
    if (normalized.session_trace_id && normalized.session_trace_id !== parent.session_trace_id) throw new TypeError('observation trace root mismatch');
    if (normalized.span_id && normalized.span_id !== parent.span_id) throw new TypeError('observation trace span mismatch');
    normalized.session_trace_id = parent.session_trace_id;
    normalized.span_id = parent.span_id;
  }
  return normalized;
}

function safeActionSummary(action) {
  const parameters = {...action.parameters};
  if (parameters.command) {
    const encoded = JSON.stringify(parameters.command);
    parameters.command_sha256 = crypto.createHash('sha256').update(encoded).digest('hex');
    delete parameters.command;
  }
  if (typeof parameters.text === 'string') {
    parameters.text_length = parameters.text.length;
    parameters.text_sha256 = crypto.createHash('sha256').update(parameters.text).digest('hex');
    delete parameters.text;
  }
  return {
    kind: action.kind,
    parameters,
    session_trace_id: action.session_trace_id,
    trace_id: action.trace_id,
    operation_trace_id: action.trace_id,
    span_id: action.span_id,
    traceparent: action.traceparent,
  };
}

function resultEnvelope(context, kind, startedAt, value, error) {
  const finishedAt = Date.now();
  return {
    session_trace_id: context.session_trace_id,
    trace_id: context.operation_trace_id,
    operation_trace_id: context.operation_trace_id,
    span_id: context.span_id,
    traceparent: context.traceparent,
    kind,
    success: !error,
    started_at: startedAt,
    finished_at: finishedAt,
    elapsed_ms: finishedAt - startedAt,
    value: error ? null : value,
    error: error ? {name: error.name, message: error.message} : null,
  };
}

function schemaCatalog(bundleId) {
  return {
    version: '1.0.0',
    module: 'faceswap:live',
    bundle_id: bundleId,
    bidi: {
      commands: ['schema', 'observe', 'action'],
      events: ['faceswap:live.actionCompleted', 'faceswap:live.observationCaptured'],
    },
    actions: Object.keys(ACTIONS),
    observations: [...OBSERVATIONS],
  };
}

module.exports = {
  ACTIONS,
  OBSERVATIONS,
  normalizeAction,
  normalizeObservation,
  resultEnvelope,
  safeActionSummary,
  schemaCatalog,
  formatTraceparent,
  operationTrace,
  parseTraceparent,
  sessionTrace,
  spanId,
  uuidValue,
};
