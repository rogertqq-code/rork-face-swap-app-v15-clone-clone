'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'index.js'), 'utf8');
const coreSource = fs.readFileSync(path.join(root, 'core.js'), 'utf8');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));

test('package declares the mandatory Appium 3 plugin contract', () => {
  assert.equal(manifest.appium.pluginName, 'faceswap-live');
  assert.equal(manifest.appium.mainClass, 'FaceSwapLivePlugin');
  assert.equal(manifest.peerDependencies.appium, '^3.6.0');
  assert.equal(manifest.private, true);
});

test('plugin exposes HTTP and WebDriver BiDi schema, observation, and action commands', () => {
  assert.match(source, /class FaceSwapLivePlugin extends BasePlugin/);
  assert.match(source, /static newMethodMap/);
  assert.match(source, /static newBidiCommands/);
  assert.match(source, /'faceswap:live'/);
  assert.match(source, /faceswap\/live\/observe/);
  assert.match(source, /faceswap\/live\/action/);
  assert.match(source, /neverProxy: true/);
});

test('plugin emits documented bidiEvent notifications with trace-correlated results', () => {
  assert.match(source, /emit\('bidiEvent', \{method, params\}\)/);
  assert.match(source, /faceswap:live\.actionCompleted/);
  assert.match(source, /faceswap:live\.observationCaptured/);
  assert.match(source, /operationTrace\(request, sessionTrace\(driver\)\)/);
  assert.match(source, /resultEnvelope\(context/);
  assert.match(source, /session_trace_id/);
  assert.match(source, /operation_trace_id/);
  assert.match(source, /span_id/);
  assert.match(source, /traceparent/);
});

test('plugin is gated to the explicit QA bundle and live vendor capability', () => {
  assert.match(source, /FACESWAP_LIVE_ENABLED/);
  assert.match(source, /FACESWAP_QA_BUNDLE_ID/);
  assert.match(source, /faceswap:liveControl/);
  assert.match(source, /authorized QA bundle/);
  assert.match(source, /sessionTrace\(driver\)/);
  assert.match(coreSource, /appium:faceswapTraceId/);
  assert.match(coreSource, /appium:faceswapTraceparent/);
});

test('network monitor is gated to a real iOS 18+ XCUITest device', () => {
  assert.match(source, /driver\.isRealDevice\(\) !== true/);
  assert.match(source, /major < 18/);
  assert.match(source, /network monitoring requires a real iOS 18\+ device with RemoteXPC/);
  assert.match(source, /_assertNetworkMonitorSupport\(driver\)/);
});

test('QA command bridge fails closed on clear and tolerates only transient missing results', () => {
  assert.match(source, /await this\._command\(driver, 'clear', input\);/);
  assert.doesNotMatch(source, /QA JSON input clear was not supported/);
  assert.match(source, /if \(!this\._isNoSuchElement\(error\)\) throw error;/);
  assert.match(source, /Date\.now\(\) \+ 120000/);
  assert.match(source, /QA command result timed out/);
  assert.match(source, /rootTraceID: context\.session_trace_id/);
  assert.match(source, /traceID: context\.operation_trace_id/);
  assert.match(source, /spanID: context\.span_id/);
});

test('plugin contains no shell or general process execution primitive', () => {
  for (const forbidden of [
    "require('node:child_process')",
    'child_process',
    'execSync(',
    'spawn(',
    'shell: true',
    'eval(',
    'Function(',
  ]) {
    assert.equal(source.includes(forbidden), false, `forbidden primitive found: ${forbidden}`);
  }
});
