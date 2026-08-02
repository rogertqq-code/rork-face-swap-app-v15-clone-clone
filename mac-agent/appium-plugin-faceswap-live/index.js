'use strict';

const {BasePlugin} = require('appium/plugin');
const {
  normalizeAction,
  normalizeObservation,
  operationTrace,
  resultEnvelope,
  safeActionSummary,
  schemaCatalog,
  sessionTrace,
} = require('./core');

const W3C_ELEMENT_KEY = 'element-6066-11e4-a52e-4f735466cecf';
const DEFAULT_BUNDLE_ID = 'app.rork.face-swap-live-app-v17.qa';

class FaceSwapLivePlugin extends BasePlugin {
  static newMethodMap = {
    '/session/:sessionId/faceswap/live/schema': {
      GET: {command: 'getFaceSwapLiveSchema', neverProxy: true},
    },
    '/session/:sessionId/faceswap/live/observe': {
      POST: {
        command: 'faceSwapLiveObserve',
        payloadParams: {required: ['observation']},
        neverProxy: true,
      },
    },
    '/session/:sessionId/faceswap/live/action': {
      POST: {
        command: 'faceSwapLiveAction',
        payloadParams: {required: ['action']},
        neverProxy: true,
      },
    },
  };

  static newBidiCommands = {
    'faceswap:live': {
      schema: {command: 'getFaceSwapLiveSchema'},
      observe: {
        command: 'faceSwapLiveObserve',
        params: {required: ['observation']},
      },
      action: {
        command: 'faceSwapLiveAction',
        params: {required: ['action']},
      },
    },
  };

  async getFaceSwapLiveSchema(next, driver) {
    this._assertSession(driver);
    const context = sessionTrace(driver);
    return {...schemaCatalog(this._bundleId()), session_trace_id: context.session_trace_id, traceparent: context.traceparent};
  }

  async faceSwapLiveObserve(next, driver, observation) {
    this._assertSession(driver);
    const request = normalizeObservation(observation);
    const context = operationTrace(request, sessionTrace(driver));
    Object.assign(request, context);
    const startedAt = Date.now();
    try {
      const value = await this._observe(driver, request.kind);
      const result = resultEnvelope(context, request.kind, startedAt, value, null);
      this._emit(driver, 'faceswap:live.observationCaptured', result);
      return result;
    } catch (error) {
      const result = resultEnvelope(context, request.kind, startedAt, null, error);
      this._emit(driver, 'faceswap:live.observationCaptured', result);
      throw error;
    }
  }

  async faceSwapLiveAction(next, driver, action) {
    this._assertSession(driver);
    const request = normalizeAction(action, {
      bundleId: this._bundleId(),
      maximumTextLength: 16384,
    });
    const context = operationTrace(request, sessionTrace(driver));
    Object.assign(request, context);
    const startedAt = Date.now();
    this.log.info(`faceswap live action ${JSON.stringify(safeActionSummary(request))}`);
    try {
      const value = await this._act(driver, request, context);
      const result = resultEnvelope(context, request.kind, startedAt, value, null);
      this._emit(driver, 'faceswap:live.actionCompleted', result);
      return result;
    } catch (error) {
      const result = resultEnvelope(context, request.kind, startedAt, null, error);
      this._emit(driver, 'faceswap:live.actionCompleted', result);
      throw error;
    }
  }

  _assertSession(driver) {
    if (process.env.FACESWAP_LIVE_ENABLED !== '1') {
      throw new Error('FaceSwap live plugin is disabled');
    }
    const caps = driver.caps || {};
    const opts = driver.opts || {};
    const bundleId = opts.bundleId || caps.bundleId || caps['appium:bundleId'];
    const liveFlag = caps['faceswap:liveControl'] ?? opts.faceswapLiveControl;
    if (bundleId !== this._bundleId() || liveFlag !== true) {
      throw new Error('FaceSwap live plugin requires the authorized QA bundle and live capability');
    }
    sessionTrace(driver);
  }

  _bundleId() {
    return process.env.FACESWAP_QA_BUNDLE_ID || DEFAULT_BUNDLE_ID;
  }

  _emit(driver, method, params) {
    const emitter = driver.eventEmitter || this.eventEmitter;
    if (emitter && typeof emitter.emit === 'function') {
      emitter.emit('bidiEvent', {method, params});
    }
  }

  async _observe(driver, kind) {
    if (kind === 'screenshot') return {base64: await this._command(driver, 'getScreenshot')};
    if (kind === 'source_xml') return {text: await this._command(driver, 'getPageSource')};
    if (kind === 'source_json') return await this._mobile(driver, 'source', {format: 'json'});
    if (kind === 'contexts') return await this._command(driver, 'getContexts');
    if (kind === 'orientation') return await this._command(driver, 'getOrientation');
    if (kind === 'window_rect') return await this._command(driver, 'getWindowRect');
    if (kind === 'device_info') return await this._mobile(driver, 'deviceInfo', {});
    if (kind === 'battery_info') return await this._mobile(driver, 'batteryInfo', {});
    if (kind === 'combined') {
      const [screenshot, source, contexts, orientation, rect] = await Promise.all([
        this._command(driver, 'getScreenshot'),
        this._command(driver, 'getPageSource'),
        this._command(driver, 'getContexts'),
        this._command(driver, 'getOrientation'),
        this._command(driver, 'getWindowRect'),
      ]);
      return {screenshot_base64: screenshot, source_xml: source, contexts, orientation, window_rect: rect};
    }
    throw new TypeError(`unsupported observation kind: ${kind}`);
  }

  async _act(driver, request, context) {
    const p = request.parameters;
    switch (request.kind) {
      case 'find':
        return await this._command(driver, p.multiple ? 'findElements' : 'findElement', p.using, p.value);
      case 'tap':
        if (p.element_id) return await this._command(driver, 'click', p.element_id);
        return await this._mobile(driver, 'tap', {x: p.x, y: p.y});
      case 'double_tap':
        return await this._mobile(driver, 'doubleTap', this._elementOrPoint(p));
      case 'touch_and_hold':
        return await this._mobile(driver, 'touchAndHold', {...this._elementOrPoint(p), duration: p.duration});
      case 'swipe':
        return await this._mobile(driver, 'swipe', {
          direction: p.direction,
          ...(p.element_id ? {elementId: p.element_id} : {}),
          ...(p.velocity ? {velocity: p.velocity} : {}),
        });
      case 'drag':
        return await this._mobile(driver, 'dragFromToForDuration', {
          fromX: p.from_x, fromY: p.from_y, toX: p.to_x, toY: p.to_y, duration: p.duration,
        });
      case 'type_text':
        return p.element_id
          ? await this._command(driver, 'setValue', p.text, p.element_id)
          : await this._command(driver, 'keys', p.text);
      case 'clear_text':
        return await this._command(driver, 'clear', p.element_id);
      case 'press_key':
        return await this._mobile(driver, 'pressButton', {name: p.key});
      case 'get_attribute':
        return await this._command(driver, 'getAttribute', p.name, p.element_id);
      case 'set_context':
        return await this._command(driver, 'setContext', p.name);
      case 'alert':
        return await this._alert(driver, p);
      case 'launch_app':
        return await this._mobile(driver, 'launchApp', {bundleId: p.bundle_id});
      case 'activate_app':
        return await this._mobile(driver, 'activateApp', {bundleId: p.bundle_id});
      case 'terminate_app':
        return await this._mobile(driver, 'terminateApp', {bundleId: p.bundle_id});
      case 'query_app_state':
        return await this._mobile(driver, 'queryAppState', {bundleId: p.bundle_id});
      case 'background_app':
        return await this._mobile(driver, 'backgroundApp', {seconds: p.seconds});
      case 'settings':
        return await this._command(driver, 'updateSettings', p);
      case 'start_network_monitor':
        this._assertNetworkMonitorSupport(driver);
        return await this._mobile(driver, 'startNetworkMonitor', {});
      case 'stop_network_monitor':
        this._assertNetworkMonitorSupport(driver);
        return await this._mobile(driver, 'stopNetworkMonitor', {});
      case 'qa_command':
        return await this._qaCommand(driver, p.command, context);
      default:
        throw new TypeError(`unsupported action kind: ${request.kind}`);
    }
  }

  _assertNetworkMonitorSupport(driver) {
    const opts = driver.opts || {};
    const caps = driver.caps || {};
    const platformVersion = String(
      opts.platformVersion || caps.platformVersion || caps['appium:platformVersion'] || '',
    );
    const major = Number.parseInt(platformVersion.split('.')[0], 10);
    if (
      typeof driver.isRealDevice !== 'function' ||
      driver.isRealDevice() !== true ||
      !Number.isInteger(major) ||
      major < 18
    ) {
      throw new Error('network monitoring requires a real iOS 18+ device with RemoteXPC');
    }
  }

  _elementOrPoint(parameters) {
    return parameters.element_id
      ? {elementId: parameters.element_id}
      : {x: parameters.x, y: parameters.y};
  }

  async _alert(driver, parameters) {
    if (parameters.action === 'get_text') return await this._command(driver, 'getAlertText');
    if (parameters.action === 'get_buttons') return await this._mobile(driver, 'alert', {action: 'getButtons'});
    if (parameters.button_label) {
      return await this._mobile(driver, 'alert', {
        action: parameters.action,
        buttonLabel: parameters.button_label,
      });
    }
    return await this._command(driver, parameters.action === 'accept' ? 'postAcceptAlert' : 'postDismissAlert');
  }

  async _qaCommand(driver, command, context) {
    const banner = this._elementId(await this._command(driver, 'findElement', 'accessibility id', 'qa.banner'));
    await this._command(driver, 'click', banner);
    const input = this._elementId(await this._command(driver, 'findElement', 'accessibility id', 'qa.command.jsonInput'));
    await this._command(driver, 'clear', input);
    const tracedCommand = {...command};
    const requiredTrace = {
      traceID: context.operation_trace_id,
      rootTraceID: context.session_trace_id,
      spanID: context.span_id,
      traceparent: context.traceparent,
    };
    for (const [key, value] of Object.entries(requiredTrace)) {
      if (tracedCommand[key] !== undefined && tracedCommand[key] !== value) throw new TypeError(`QA command ${key} does not match the live operation trace`);
      tracedCommand[key] = value;
    }
    await this._command(driver, 'setValue', JSON.stringify(tracedCommand), input);
    const execute = this._elementId(await this._command(driver, 'findElement', 'accessibility id', 'qa.command.executeJSON'));
    await this._command(driver, 'click', execute);
    const deadline = Date.now() + 120000;
    while (Date.now() < deadline) {
      let resultElement;
      try {
        resultElement = this._elementId(await this._command(driver, 'findElement', 'accessibility id', 'qa.command.resultJSON'));
      } catch (error) {
        if (!this._isNoSuchElement(error)) throw error;
        await new Promise((resolve) => setTimeout(resolve, 100));
        continue;
      }
      for (const attribute of ['value', 'label', 'name']) {
        const value = await this._command(driver, 'getAttribute', attribute, resultElement);
        if (typeof value === 'string' && value.trim()) {
          try { return JSON.parse(value); } catch { return value; }
        }
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error('QA command result timed out');
  }

  _isNoSuchElement(error) {
    const value = `${error && error.name || ''} ${error && error.message || ''}`.toLowerCase();
    return value.includes('no such element') || value.includes('nosuchelement');
  }

  _elementId(value) {
    const id = value && (value[W3C_ELEMENT_KEY] || value.ELEMENT);
    if (typeof id !== 'string' || !id) throw new Error('element response did not contain an identifier');
    return id;
  }

  async _mobile(driver, name, args) {
    return await this._command(driver, 'execute', `mobile: ${name}`, [args]);
  }

  async _command(driver, name, ...args) {
    if (typeof driver.executeCommand === 'function') return await driver.executeCommand(name, ...args);
    if (typeof driver[name] === 'function') return await driver[name](...args);
    throw new Error(`driver command is unavailable: ${name}`);
  }
}

module.exports = {FaceSwapLivePlugin};
