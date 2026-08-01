import fs from 'node:fs';
import vm from 'node:vm';
import { randomUUID } from 'node:crypto';
import path from 'node:path';

const generatedDirectory = process.argv[2] || 'build/generated-js';
const patch = fs.readFileSync(path.join(generatedDirectory, 'patchScript.js'), 'utf8');
const nativeClient = fs.readFileSync(path.join(generatedDirectory, 'nativeWebRTCClientScript.js'), 'utf8');
const results = {};

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function delay(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

async function testNativeClientSignaling() {
  const bridgeMessages = [];
  const windowEvents = new Map();

  class FakeTrack {
    constructor(kind, id) {
      this.kind = kind;
      this.id = id;
      this.readyState = 'live';
    }
    stop() { this.readyState = 'ended'; }
  }

  class FakeMediaStream {
    constructor() {
      this.tracks = [];
      this.listeners = new Map();
    }
    addTrack(track) { this.tracks.push(track); }
    getTracks() { return [...this.tracks]; }
    getVideoTracks() { return this.tracks.filter(track => track.kind === 'video'); }
    getAudioTracks() { return this.tracks.filter(track => track.kind === 'audio'); }
    addEventListener(name, handler) { this.listeners.set(name, handler); }
  }

  class FakeAudioContext {
    createOscillator() { return { connect() {}, start() {}, stop() {} }; }
    createGain() { return { gain: { value: 1 }, connect() {} }; }
    createMediaStreamDestination() {
      const stream = new FakeMediaStream();
      stream.addTrack(new FakeTrack('audio', 'silent-audio'));
      return { stream };
    }
    close() { return Promise.resolve(); }
  }

  class FakePeerConnection {
    constructor() {
      this.connectionState = 'new';
      this.ontrack = null;
      this.onicecandidate = null;
      this.onconnectionstatechange = null;
    }
    setRemoteDescription(description) {
      this.remoteDescription = description;
      return Promise.resolve();
    }
    createAnswer() {
      return Promise.resolve({ type: 'answer', sdp: 'v=0\r\nanswer' });
    }
    setLocalDescription(description) {
      this.localDescription = description;
      this.onicecandidate?.({ candidate: { candidate: 'candidate:page-1', sdpMLineIndex: 0, sdpMid: '0' } });
      queueMicrotask(() => {
        const video = new FakeTrack('video', 'native-video');
        const stream = new FakeMediaStream();
        stream.addTrack(video);
        this.ontrack?.({ streams: [stream], track: video });
        this.connectionState = 'connected';
        this.onconnectionstatechange?.();
      });
      return Promise.resolve();
    }
    addIceCandidate(candidate) {
      this.remoteCandidate = candidate;
      return Promise.resolve();
    }
    close() {
      this.connectionState = 'closed';
      this.onconnectionstatechange?.();
    }
  }

  const context = {
    console,
    Promise,
    Object,
    String,
    Number,
    Array,
    Map,
    Date,
    Error,
    DOMException,
    MediaStream: FakeMediaStream,
    RTCPeerConnection: FakePeerConnection,
    AudioContext: FakeAudioContext,
    setTimeout,
    clearTimeout,
    queueMicrotask,
    crypto: { randomUUID },
    window: null,
    document: {},
  };
  context.window = {
    ...context,
    webkit: {
      messageHandlers: {
        fslNativeRTC: {
          async postMessage(body) {
            bridgeMessages.push(body);
            if (body.action === 'start') {
              return {
                ok: true,
                requestId: body.requestId,
                offer: { type: 'offer', sdp: 'v=0\r\noffer' },
                audioOutcome: { kind: 'silentFallback', reason: 'microphone unavailable' },
              };
            }
            if (body.action === 'answer') await delay(10);
            return { ok: true };
          },
        },
      },
    },
    addEventListener(name, handler) { windowEvents.set(name, handler); },
    AudioContext: FakeAudioContext,
  };
  context.window.window = context.window;

  vm.createContext(context);
  vm.runInContext(nativeClient, context, { filename: 'nativeWebRTCClientScript.js' });

  const stream = await context.window.__fslNativeRTCStep1.start({
    video: { facingMode: 'environment', width: 640, height: 480, frameRate: 30 },
    audio: true,
    audioPolicy: 'compatibilitySilentFallback',
    rawSampleMode: 'firstFrame',
    timeoutMs: 2000,
  });

  const actions = bridgeMessages.map(message => message.action);
  const answerIndex = actions.indexOf('answer');
  const candidateIndex = actions.indexOf('candidate');
  assert(answerIndex >= 0, 'page SDP answer was not returned');
  assert(candidateIndex > answerIndex, `ICE candidate overtook SDP answer: ${actions.join(' -> ')}`);
  assert(stream.getVideoTracks().length === 1, 'native client did not publish a video track');
  assert(stream.getAudioTracks().length === 1, 'silent audio fallback was not attached');
  assert(stream.__fslAudioOutcome?.kind === 'silentFallback', 'audio outcome was not explicit');

  stream.getVideoTracks()[0].stop();
  await Promise.resolve();
  assert(bridgeMessages.some(message => message.action === 'stop'), 'track.stop did not stop the native request');

  results.nativeClient = { passed: true, actions };
}

async function testSerializedAdapterBroker() {
  const start = patch.indexOf('function fslSdkFileURL(');
  const end = patch.indexOf('function fslSdkLooksLikeCamera(', start);
  assert(start >= 0 && end > start, 'adapter broker block was not found');
  const brokerSource = patch.slice(start, end);
  const state = {
    a: true,
    seq: [
      { id: 'asset-1', kind: 'photo', img: 'fslimage://asset-1', name: 'one.jpg' },
      { id: 'asset-2', kind: 'photo', img: 'fslimage://asset-2', name: 'two.jpg' },
    ],
    _pkPtr: 0,
    _sdkQueue: Promise.resolve(),
    _sdkObjectURLs: [],
  };
  const commits = [];
  const revoked = [];
  let objectURLSerial = 0;

  class HarnessFile extends Blob {
    constructor(parts, name, options = {}) {
      super(parts, options);
      this.name = name;
      this.lastModified = options.lastModified || Date.now();
    }
  }

  const context = {
    Promise,
    Object,
    String,
    Number,
    Date,
    Error,
    Array,
    Blob,
    File: HarnessFile,
    URL: {
      createObjectURL() { objectURLSerial += 1; return `blob:fixture-${objectURLSerial}`; },
      revokeObjectURL(url) { revoked.push(url); },
    },
    CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init?.detail; } },
    window: { dispatchEvent() {}, addEventListener() {} },
    s: state,
    gs() { return state; },
    pickerResolve() {
      const index = state._pkPtr || 0;
      const step = state.seq[index];
      return step ? { a: 'serve', step, nextPtr: index + 1 } : { a: 'nativePicker' };
    },
    payloadFor(step) { return step; },
    fslRollbackPickerResult() {},
    fslCommitPickerResult(result) {
      commits.push(result.step.id);
      state._pkPtr = result.nextPtr;
    },
    fslTrace() {},
    fetch: async url => {
      if (String(url).includes('asset-1')) await delay(20);
      return { ok: true, status: 200, blob: async () => new Blob([String(url)], { type: 'image/jpeg' }) };
    },
  };
  context.window.window = context.window;
  vm.createContext(context);
  vm.runInContext(brokerSource, context, { filename: 'adapterBroker.js' });

  const [first, second] = await Promise.all([
    context.fslSdkServeFile('image', file => ({ name: file.name, url: context.fslSdkFileURL(file) })),
    context.fslSdkServeFile('image', file => ({ name: file.name, url: context.fslSdkFileURL(file) })),
  ]);

  assert(first.name === 'one.jpg', `first adapter received ${first.name}`);
  assert(second.name === 'two.jpg', `second adapter received ${second.name}`);
  assert(commits.join(',') === 'asset-1,asset-2', `duplicate or out-of-order consumption: ${commits.join(',')}`);
  const revokedCount = context.fslSdkRevokeObjectURLs();
  assert(revokedCount === 2 && revoked.length === 2, 'adapter Blob URLs were not revoked');

  results.adapterBroker = { passed: true, commits, revoked };
}

function testSiteRule() {
  const start = patch.indexOf('function fslAsksFor(');
  const end = patch.indexOf('function fslAskDecision(', start);
  assert(start >= 0 && end > start, 'site-rule helper block was not found');
  const state = { _askOn: false, _askKinds: 'liveCamera', _askRule: 'block' };
  const context = { String, gs() { return state; } };
  vm.createContext(context);
  vm.runInContext(patch.slice(start, end), context, { filename: 'siteRule.js' });
  assert(context.fslSiteRule() === '', 'site rule applied while ask mode was disabled');
  state._askOn = true;
  assert(context.fslSiteRule() === 'block', 'valid site rule was not returned');
  state._askRule = 'unexpected';
  assert(context.fslSiteRule() === '', 'invalid site rule was not rejected');
  results.siteRule = { passed: true };
}

try {
  await testNativeClientSignaling();
  await testSerializedAdapterBroker();
  testSiteRule();
  console.log(JSON.stringify({ passed: true, results }, null, 2));
} catch (error) {
  console.error(JSON.stringify({ passed: false, error: String(error?.stack || error), results }, null, 2));
  process.exit(1);
}
