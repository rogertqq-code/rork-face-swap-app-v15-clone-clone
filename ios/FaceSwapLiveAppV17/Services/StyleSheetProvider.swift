import Foundation
import UIKit

nonisolated enum StyleSheetProvider {
    // MARK: - Core injection engine (patch script)

    /// The main JavaScript patch injected at document start. This intercepts
    /// getUserMedia, enumerateDevices, file pickers, and camera-adjacent APIs
    /// to serve the configured media sequence through the chosen injection
    /// method — or block all real-camera access when media is active.
    static let patchScript: String = """
    (function(){
    'use strict';
    try{
    var _allowed=["kyctest.work.app","localhost","127.0.0.1","fsl.diagnostics.local"];
    if(window.location.protocol!=='https:'||_allowed.indexOf(window.location.hostname)===-1)return;
    if(window[Symbol.for('fsl')])return;

    // ---- atob polyfill for CSP / sandboxed environments ----
    if(typeof atob==='undefined'){
      (function(){
        var _chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
        window.atob=function(input){
          var str=String(input).replace(/[\\t\\n\\r ]/g,'');
          if(str.length%4!==0)throw new Error('Invalid base64 length');
          var i=0,out='';
          while(i<str.length){
            var e1=_chars.indexOf(str.charAt(i++));
            var e2=_chars.indexOf(str.charAt(i++));
            var e3=_chars.indexOf(str.charAt(i++));
            var e4=_chars.indexOf(str.charAt(i++));
            var c1=(e1<<2)|(e2>>4);
            var c2=((e2&15)<<4)|(e3>>2);
            var c3=((e3&3)<<6)|e4;
            out+=String.fromCharCode(c1);
            if(e3!==64)out+=String.fromCharCode(c2);
            if(e4!==64)out+=String.fromCharCode(c3);
          }
          return out;
        };
      })();
    }

    // ---- navigator.standalone (Safari PWA hint) ----
    try{
        if(typeof navigator.standalone==='undefined'){
            Object.defineProperty(navigator,'standalone',{get:function(){return false;},configurable:true,enumerable:true});
        }
    }catch(e){}

    var md=navigator.mediaDevices;
    if(!md||typeof MediaDevices==='undefined')return;

    var origEnum=MediaDevices.prototype.enumerateDevices;
    var origGUM=MediaDevices.prototype.getUserMedia;

    // ---- Shared state ----
    var _s=Object.create(null);
    _s.a=false;           // is media injection active
    _s.ra=true;           // replace all devices in enumerateDevices
    _s.is=null;           // image injection source (ImageInjectionSource)
    _s.vs=null;           // video injection source

    _s.seq=null;          // sequence array
    _s.mode='head';       // advance mode
    _s.end='hold';        // end behavior
    _s.clearBetween=true;
    _s.pHead=0;
    _s._pkPtr=0;          // picker's OWN cycle position — never shared with the live camera pointer(s)
    _s._held=null;        // last served step (any surface) — legacy/diagnostics anchor
    _s._heldLive=null;    // last step served to the live/WebRTC surface
    _s._heldNative=null;  // last step served to the native picker surface
    _s._seqV=-1;          // sequence version
    _s._c=null;           // canvas (front or back)
    _s._x=null;           // canvas context
    _s._cf=null;          // front canvas
    _s._xf=null;          // front context
    _s._cb=null;          // back canvas
    _s._xb=null;          // back context
    _s._st=null;          // published MediaStream
    _s._ve=null;          // active video element
    _s._ri=null;          // render loop requestAnimationFrame ID
    _s._active=null;      // active draw source ({type,el,draw})
    _s._ft=null;          // injected-frame delivery timestamps (ms) for drift monitor
    _s._stFacing=null;    // facing of current published stream
    _s._lastFacing=null;
    _s.fp=null;           // front device profile
    _s.bp=null;           // back device profile
    _s.mp=null;           // mic profile
    _s._maskMap=(typeof WeakMap!=='undefined')?new WeakMap():null;
    _s._silentAC=null;    // shared AudioContext for silent audio
    _s._silentGain=null;
    _s._method='canvasPipeline';  // active injection method
    _s._methodFallback=null;      // fallback method if primary unsupported
    _s._tinfo=(typeof WeakMap!=='undefined')?new WeakMap():null; // virtual track records
    _s._protoPatched=false;       // MediaStreamTrack.prototype spoof installed once
    _s._diPatched=false;          // MediaDeviceInfo.prototype getter spoof installed once
    _s._pubVideoTrack=null;       // currently published virtual video track
    _s._pubFps=30;                // published cadence (drives paced delivery)
    _s._paceT=null;               // paced delivery timer id
    _s._pacing=false;             // paced loop running flag
    _s._reqFrame=null;            // manual canvas frame requester (exact cadence)
    _s._cms=undefined;            // canvas manual-capture support cache
    _s._vtgWorker=null;           // VideoTrackGenerator worker (videoDirect/rawFramePipe)
    _s._vtgT=null;                // VTG frame-pump timer id
    _s._vtgDrawCanvas=null;       // rawFramePipe frame-assembly canvas
    _s._wc=null;                  // active WebCodecs decoder controller (new frame engine)
    _s._feedEngine='';            // clean-feed frame source: 'webcodecs' | 'element' | ''
    _s._activeFeed=null;          // which feed engaged: 'vtg' (clean track) | 'canvas'
    _s._feedLane=null;            // delivery lane of the clean feed: 'private' | null
    _s._feedIntended=null;        // method that requested the feed (downgrade detection)
    _s._feedDowngraded=false;     // true when a vtg-capable method fell back to canvas
    _s._feedReason='';            // reason code for the active feed / downgrade
    _s._laneBad=false;            // page-local memory: private lane failed decisively
    _s._laneBadReason='';         // last decisive private-lane failure reason
    _s._sensorRealism=true;       // Round 2 sensor-realism layer (capture-clock timing + grain), default on
    _s._srCanvasFeed=false;       // active clean feed has a drawing surface (grain-capable)
    _s._sr=null;                  // cached sensor-realism instance (per seed + size)
    _s._armed=false;              // camera-takeover interception installed (gate live)
    _s._armParts=Object.create(null); // per-piece install flags (idempotent re-arm)
    _s._armError='';              // reason(s) any interception piece failed to arm
    _s._pkBusy=false;             // a native camera/file hand-off is mid-flight
    _s._pkLast=0;                 // last hand-off start (ms) — one-tap dedupe
    _s._askOn=false;              // ask-me-every-request mode (opt-in, default off)
    _s._askKinds='';              // which kinds pause: csv of liveCamera|nativeCamera|filePick
    _s._askTimeout=20000;         // ms before the configured default action applies
    _s._askDefault='serve';       // default action when no answer arrives in time
    _s._asks=null;                // token -> pending decision resolver
    _s._probeMode=false;          // diagnostics hand-off probe (no freeze/overlay)
    _s._probeUntil=0;             // hard deadline; probe mode can never outlive it
    _s._isHarness=false;          // true ONLY inside the app's own test page
    _s._traceOn=false;            // failure recorder (opt-in, default off)
    _s._holdCapT=null;            // hard cap: a held feed ALWAYS resumes
    _s._autoOn=false;             // Auto is driving the method choice
    _s._photoMotion=false;        // still photos are served as moving footage
    _s._liveFellOpen=false;       // a live request was answered by a reserved item
    _s._askPick=null;             // {id,at} one-shot "serve this exact item" choice
    _s._askRule='';               // remembered per-site action: ''|serve|block|real
    _s._permReset='never';        // camera-permission release policy: never|feed|request
    _s._permReleased=false;       // permission currently released (query reports 'prompt')
    _s._feedHold=false;           // live feed interrupted while a capture has the camera
    _s._frozen=false;             // page reported hidden during a capture window
    _s._frozenAt=0;               // ms timestamp the freeze began (for the resume time jump)
    _s._frzInstalled=false;       // native timer refs captured
    _s._frzBypass=false;          // engine-internal scheduling passes through a freeze
    _s._frzId=0;                  // id counter for deferred rAF/timeout handles
    _s._rafQ=null;                // page animation frames deferred by the freeze
    _s._toQ=null;                 // page one-shot timers deferred by the freeze
    _s._frzCapT=null;             // hard safety cap that always releases the page
    _s._holdWatch=null;           // watchdog: never leave the feed/page held forever
    _s._origInputClick=null;      // genuine HTMLInputElement click, for the real-camera fallback
    _s._session='';               // immutable native navigation session for this document
    _s._runtimeV=0;               // monotonic native runtime-state version
    _s._runtimeReady=false;       // no page request may pass before native state is acknowledged
    setTimeout(function(){
        if(!_s._runtimeReady){
            // Bounded bootstrap: drain _gumQueue with timeout and diagnostics
            _s._runtimeReady=true;
            if(_s._gumQueue && _s._gumQueue.length > 0){
                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.fslLog) {
                        window.webkit.messageHandlers.fslLog.postMessage("Bootstrap timeout drained " + _s._gumQueue.length + " queued requests.");
                    }
                } catch(e) {}
                var q = _s._gumQueue;
                _s._gumQueue = null;
                q.forEach(function(fn){ fn(); });
            }
        }
    }, 3000);
    _s._requestSerial=0;          // monotonic page request counter
    _s._activeLiveRequest=null;   // active live request, scoped to session + sequence version
    _s._activeNativeRequest=null; // active file/camera request, independent from the live feed
    _s._streamReq=null;           // C-04: request bound to the active stream (per-stream, not global)
    _s._sdkWrap=false;            // optional SDK/bridge interception defaults off
    _s._sdkWrapped=(typeof WeakSet!=='undefined')?new WeakSet():null;
    _s._sdkQueue=Promise.resolve(); // serializes SDK queue reservation, fetch, and commit
    _s._sdkObjectURLs=[];          // lifecycle-owned adapter Blob URLs
    _s._sdkWrapRefreshing=false;  // prevents re-entrant late-binding scans
    _s._sdkWrapMonitor=false;     // one per-document late-SDK watcher

    var _sk=Symbol.for('fsl');
    Object.defineProperty(window,_sk,{value:_s,writable:false,configurable:false,enumerable:false});

    function gs(){return window[Symbol.for('fsl')];}

    // Engine-internal one-shot timer. Always fires on real time, even while the
    // page itself is frozen for a capture window — the freeze defers only the
    // PAGE's own timers, never our own delivery/pacing machinery.
    function _nT(cb,ms){
        var s=gs();
        var st=(s&&s._natST)?s._natST:window.setTimeout;
        if(!s)return st.call(window,cb,ms);
        s._frzBypass=true;
        try{return st.call(window,cb,ms);}finally{s._frzBypass=false;}
    }
    function _nCT(id){
        var s=gs();
        var ct=(s&&s._natCT)?s._natCT:window.clearTimeout;
        try{ct.call(window,id);}catch(e){}
    }
    try{
        _s._natST=window.setTimeout;
        _s._natCT=window.clearTimeout;
        _s._natRAF=window.requestAnimationFrame;
        _s._frzInstalled=false;
    }catch(e){}

    // ---- Injected-frame cadence recorder (drift monitor) ----
    // Records the timestamp of every frame actually delivered into the page's
    // virtual stream so diagnostics can measure the real cadence the site sees.
    function fslTick(){
        var s=gs();
        if(!s)return;
        var ft=s._ft||(s._ft=[]);
        ft.push(performance.now());
        if(ft.length>240)ft.splice(0,ft.length-240);
        try{fslNoteFrame();}catch(e){}
    }

    // Applies one versioned native runtime snapshot. A stale asynchronous state
    // push is ignored, and a new navigation/session explicitly cancels work from
    // the document being replaced before its queues can affect the new page.
    function fslApplyRuntimeState(state){
        var s=gs();
        if(!s||!state||typeof state!=='object')return false;
        var incoming=Number(state.runtimeVersion||0);
        if(incoming&&incoming<(s._runtimeV||0))return false;
        var nextSession=String(state.navigationSessionID||'');
        if(s._session&&nextSession&&s._session!==nextSession){
            try{fslCancelRequests('navigation-replaced');}catch(e){}
        }
        s._runtimeV=incoming||((s._runtimeV||0)+1);
        s._runtimeReady=true;
        try{window.__fslRuntimeStateReady=true;}catch(e){}
        if(s._gumQueue){
            var q = s._gumQueue;
            s._gumQueue = null;
            q.forEach(function(fn){ fn(); });
        }
        s._session=nextSession;
        s.seq=Array.isArray(state.sequence)?state.sequence:[];
        s.payloads=(state.payloads&&typeof state.payloads==='object')?state.payloads:{};
        s._payloadV=Number(state.payloadVersion||0);
        s.mode=String(state.mode||'advance');
        s.end=String(state.end||'hold');
        s._method=String(state.method||'canvasPipeline');
        s.a=!!state.isActive;
        s._autoOn=!!state.isAuto;
        s._photoMotion=!!state.photoMotion;
        s._edk=!!state.eyedeekitMode;
        s._docHoldMin=(typeof state.documentHoldMinimumMs==='number')?state.documentHoldMinimumMs:null;
        s._docHoldMax=(typeof state.documentHoldMaximumMs==='number')?state.documentHoldMaximumMs:null;
        s._askOn=!!state.askEnabled;
        s._askKinds=String(state.askKinds||'');
        s._askTimeout=Number(state.askTimeoutMs||20000);
        s._askDefault=String(state.askDefault||'serve');
        s._askRule=String(state.askRule||'');
        s._permReset=String(state.permissionReset||'never');
        s._traceOn=!!state.traceEnabled;
        var nextSeq=Number(state.sequenceVersion||0);
        if(s._seqV!==nextSeq){
            // A sequence replacement invalidates every in-flight request built
            // against the old cursor. End those slots before changing _seqV so a
            // stale completion cannot leave the next request permanently marked
            // as re-entrant. Retire the old feed as well: it may reference media
            // the user has just replaced or removed.
            try{fslCancelRequests('sequence-replaced');}catch(e){}
            try{if(s._stop)s._stop();}catch(e){}
            s._streamReq=null; // C-04: clear per-stream binding on sequence replacement
            s._seqV=nextSeq;s.pHead=0;s._pkPtr=0;s._held=null;s._heldLive=null;s._heldNative=null;s._ft=[];s._servedAsStill=false;
        }
        try{if(s._resumeFeed)s._resumeFeed();}catch(e){}
        if(!s.a&&s._stop){try{s._stop();}catch(e){}}
        try{navigator.mediaDevices.dispatchEvent(new Event('devicechange'));}catch(e){}
        // SDK globals are commonly installed after document-start. Refresh the
        // optional wrapper set only while the opt-in layer is enabled.
        try{if(s._sdkWrap){if(s._watchSdkWraps)s._watchSdkWraps();if(s._refreshSdkWraps)s._refreshSdkWraps();}}catch(e){}
        try{if(s._lifecycle)s._lifecycle('pageReady',null,'runtime-state-applied','The native state snapshot was acknowledged by this document.','live');}catch(e){}
        return true;
    }
    _s._applyRuntimeState=fslApplyRuntimeState;

    // ---- Native-code disguise helpers ----
    var _fslFPT=Function.prototype.toString;
    var _fslTail=(function(){try{var t=_fslFPT.call(Object.getPrototypeOf);return t.slice(t.indexOf('('));}catch(e){return '() {'+String.fromCharCode(10)+'    [native code]'+String.fromCharCode(10)+'}';}})();
    function _nativeStr(name,isGetter){return 'function '+(isGetter?'get ':'')+(name||'')+_fslTail;}
    function _maskStore(){try{var t=window.top;if(t){var ts=t[Symbol.for('fsl')];if(ts&&ts._maskMap)return ts._maskMap;}}catch(e){}var s=gs();return s?s._maskMap:null;}
    function maskFn(fn,name,isGetter){try{var m=_maskStore();if(m&&typeof fn==='function')m.set(fn,_nativeStr(name,isGetter));}catch(e){}return fn;}
    _s._maskFn=maskFn;
    _s._nativeStr=_nativeStr;
    try{
        var _fslToString=function toString(){
            try{var m=_maskStore();if(m){var hit=m.get(this);if(hit!==undefined)return hit;}}catch(e){}
            return _fslFPT.call(this);
        };
        Function.prototype.toString=_fslToString;
        maskFn(_fslToString,'toString',false);
    }catch(e){}

    // Refreshes only the optional SDK/bridge layer. The standard media gates
    // remain independently armed, while late-loaded globals are discovered
    // without stacking wrappers around a function already handled by this page.
    function fslRefreshSdkWraps(){
        var s=gs();
        if(!s||s._sdkWrapRefreshing)return;
        s._sdkWrapRefreshing=true;
        try{s._armParts.sdkWrap=false;arm();}catch(e){s._armError='sdk-refresh:'+((e&&e.message)||e);}finally{s._sdkWrapRefreshing=false;}
    }
    function fslWatchSdkWraps(){
        var s=gs();
        if(!s||s._sdkWrapMonitor)return;
        s._sdkWrapMonitor=true;
        var tick=function(){
            var state=gs();
            if(!state)return;
            if(!state._sdkWrap){state._sdkWrapMonitor=false;return;}
            if(state._refreshSdkWraps)state._refreshSdkWraps();
            _nT(tick,1000);
        };
        _nT(tick,1000);
    }
    _s._refreshSdkWraps=fslRefreshSdkWraps;
    _s._watchSdkWraps=fslWatchSdkWraps;

    // Arm the camera takeover IMMEDIATELY — before any of the clean-feed,
    // private-lane, or fingerprint helpers below — so a hiccup in a later layer
    // can never leave the interception uninstalled while the app still looks
    // "active". arm() is hoisted (defined far below); it installs each piece in
    // isolation and is safe to re-run for self-healing.
    _s._arm=arm;
    try{arm();}catch(e){_s._armError='arm-threw:'+((e&&e.message)||e);}

    // ---- Canvas management ----
    function initCanvas(facing){
        var s=gs();
        var isBack=(facing==='environment');
        var p=isBack?(s.bp||s.fp||{}):(s.fp||{});
        var w=(p&&p.width)?p.width:1280;
        var h=(p&&p.height)?p.height:720;
        var ck=isBack?'_cb':'_cf';
        var xk=isBack?'_xb':'_xf';
        if(!s[ck]){
            s[ck]=document.createElement('canvas');
            s[ck].width=w;
            s[ck].height=h;
            s[xk]=s[ck].getContext('2d');
            s[xk].fillStyle='#000';
            s[xk].fillRect(0,0,w,h);
        } else if(s[ck].width!==w||s[ck].height!==h){
            s[ck].width=w;
            s[ck].height=h;
            s[xk].fillStyle='#000';
            s[xk].fillRect(0,0,w,h);
        }
        s._c=s[ck];
        s._x=s[xk];
    }

    // Safely retires a prior s._ve video element: pauses it, clears src, and
    // revokes any blob URL created for it. Calling this before assigning a new
    // s._ve prevents both element leaks and blob URL accumulation across feeds.
    function disposePrevVideoEl(){
        var s=gs();
        if(s._ve){
            try{s._ve.pause();}catch(e){}
            try{if(s._ve._fslObjURL){URL.revokeObjectURL(s._ve._fslObjURL);s._ve._fslObjURL=null;}}catch(e){}
            try{s._ve.removeAttribute('src');s._ve.load();}catch(e){}
            s._ve=null;
        }
    }

    function disposeActive(){
        var s=gs();
        var a=s._active;
        if(a&&a.type==='video'&&a.el){
            try{a.el.pause();}catch(e){}
            try{if(a.el._fslObjURL){URL.revokeObjectURL(a.el._fslObjURL);a.el._fslObjURL=null;}}catch(e){}
            try{a.el.removeAttribute('src');a.el.load();}catch(e){}
        }
        s._active=null;
    }

    // Retires the worker-backed VideoTrackGenerator feed (pump timer + worker +
    // assembly canvas) without touching the canvas feed. Safe to call when no
    // VTG feed is running, so any feed handoff can call it to guarantee no
    // leftover background lane.
    function stopVTG(){
        var s=gs();
        if(s._vtgT){clearTimeout(s._vtgT);s._vtgT=null;}
        if(s._vtgWorker){try{s._vtgWorker.postMessage({type:'stop'});}catch(e){}try{s._vtgWorker.terminate();}catch(e){}s._vtgWorker=null;}
        if(s._vtgWorkerURL){try{URL.revokeObjectURL(s._vtgWorkerURL);}catch(e){}s._vtgWorkerURL=null;}
        if(s._wc){try{s._wc.teardown();}catch(e){}s._wc=null;}
        s._vtgDrawCanvas=null;
    }

    function stopAll(){
        var s=gs();
        // A feed ending is the trigger for the 'when a feed ends' release policy.
        try{if(s._releasePermission)s._releasePermission('feed');}catch(e){}
        // Never carry a hold across a teardown: the next feed would start muted.
        if(s._holdCapT){_nCT(s._holdCapT);s._holdCapT=null;}
        s._feedHold=false;
        s._pacing=false;
        if(s._paceT){clearTimeout(s._paceT);s._paceT=null;}
        stopVTG();
        s._activeFeed=null;
        if(s._ri){cancelAnimationFrame(s._ri);s._ri=null;}
        if(s._riFrame){try{clearTimeout(s._riFrame);}catch(e){}try{cancelAnimationFrame(s._riFrame);}catch(e){}s._riFrame=null;}
        s._reqFrame=null;
        s._pubVideoTrack=null;
        disposeActive();
        if(s._ve){
            try{s._ve.pause();}catch(e){}
            try{if(s._ve._fslObjURL){URL.revokeObjectURL(s._ve._fslObjURL);s._ve._fslObjURL=null;}}catch(e){}
            try{s._ve.removeAttribute('src');s._ve.load();}catch(e){}
            s._ve=null;
        }
        if(s._st){try{s._st.getTracks().forEach(function(t){t.stop();});}catch(e){}s._st=null;}
        if(s._trackClones){
            s._trackClones.forEach(function(r){
                var c=r.deref?r.deref():r;
                if(c&&typeof c.stop==='function')c.stop();
            });
            s._trackClones=[];
        }
        s._stFacing=null;
    }
    _s._stop=stopAll;

    // Detects whether the canvas supports manual frame requests. When true we
    // capture at 0 fps and call requestFrame() on a paced timer, giving the page
    // an exact, camera-like cadence instead of the screen's refresh rate.
    function canvasManual(){
        var s=gs();
        if(s._cms!==undefined)return s._cms;
        s._cms=false;
        try{
            var c=document.createElement('canvas');c.width=2;c.height=2;
            var st=c.captureStream(0);var t=st.getVideoTracks()[0];
            s._cms=!!(t&&typeof t.requestFrame==='function');
            try{st.getTracks().forEach(function(x){x.stop();});}catch(e){}
        }catch(e){s._cms=false;}
        return s._cms;
    }

    // Paced delivery loop: draws the active source and delivers one frame per
    // claimed-fps interval with a small natural jitter (±3%), instead of running
    // at the display refresh rate. This removes the biggest timing tell.
    function startLoop(){
        var s=gs();
        if(s._pacing)return;
        s._pacing=true;
        var tick=function(){
            var s=gs();
            if(!s.a||!s._pacing){s._pacing=false;s._paceT=null;return;}
            var a=s._active;
            // Frames are NEVER gated. A pause switch here could strand the feed
            // black for the whole session with no error, so the loop always draws.
            if(a&&a.draw){try{a.draw();}catch(e){}}
            if(s._reqFrame){try{s._reqFrame();}catch(e){}}
            fslTick();
            var fps=s._pubFps||30;if(fps<1)fps=1;
            var base=1000/fps;
            var next=base*(0.97+Math.random()*0.06);
            s._paceT=_nT(tick,Math.max(4,next));
        };
        s._paceT=_nT(tick,0);
    }

    // Drift-corrected paced delivery for Classic Canvas. Identical per-frame work
    // to startLoop (draw the active source + requestFrame), but the next deadline
    // is anchored to an absolute timeline advanced by EXACTLY one frame interval
    // each tick, so the long-run average cadence equals the claimed fps with no
    // accumulating drift. The small +/-3% jitter is applied only to the schedule
    // delay (never folded back into the anchor), so frames arrive the way a real
    // camera paces them rather than at the display refresh rate. If we fall more
    // than two frames behind (tab throttling / GC), the anchor resets so the loop
    // never spirals into a backlog. Scoped to Classic Canvas; other modes keep
    // their existing pacing untouched.
    function startLoopAnchored(){
        var s=gs();
        if(s._pacing)return;
        s._pacing=true;
        var fps0=s._pubFps||30;if(fps0<1)fps0=1;
        var next=performance.now()+1000/fps0;
        var tick=function(){
            var s=gs();
            if(!s.a||!s._pacing){s._pacing=false;s._paceT=null;return;}
            var a=s._active;
            // Never gated — see startLoop.
            if(a&&a.draw){try{a.draw();}catch(e){}}
            if(s._reqFrame){try{s._reqFrame();}catch(e){}}
            fslTick();
            var fps=s._pubFps||30;if(fps<1)fps=1;
            var base=1000/fps;
            next+=base;
            var now=performance.now();
            if(next<now-2*base)next=now+base;
            var jitter=base*0.03*(Math.random()*2-1);
            var delay=next+jitter-now;
            s._paceT=_nT(tick,Math.max(1,delay));
        };
        s._paceT=_nT(tick,Math.max(1,1000/fps0));
    }

    // Picks the pacing loop for the active method: Classic Canvas gets the
    // drift-corrected, camera-paced loop; every other canvas-based serve keeps
    // the original loop exactly as before.
    function startPace(){
        var s=gs();
        if(s._method==='classicCanvas')startLoopAnchored();else startLoop();
    }

    // Re-kicks a freshly-created canvas stream a few times to defeat the known
    // WebKit glitch where the first captured frame can arrive blank/empty —
    // redraw the active source and request a frame at 0/30/90/180ms.
    function primeStream(){
        var s=gs();
        var kick=function(){
            try{var a=s._active;if(a&&a.draw)a.draw();}catch(e){}
            try{if(s._reqFrame)s._reqFrame();}catch(e){}
        };
        kick();
        _nT(kick,30);
        _nT(kick,90);
        _nT(kick,180);
    }

    // ---- Virtual track patching (prototype-level for native handoff) ----
    // Real camera tracks expose getSettings/getCapabilities/getConstraints/label
    // through MediaStreamTrack.prototype, carrying NO own-property overrides.
    // We mirror that: install the spoof ONCE on the prototype, keyed by a WeakMap
    // of our virtual tracks, so a site inspecting a track for own-property tells
    // finds none. Non-virtual tracks fall through to the genuine native methods.
    function tinfo(t){try{var s=gs();return(s&&s._tinfo)?s._tinfo.get(t):null;}catch(e){return null;}}

    function _numFrom(c,fallback){
        if(c==null)return fallback;
        if(typeof c==='number')return c;
        if(typeof c==='object'){
            if(typeof c.exact==='number')return c.exact;
            if(typeof c.ideal==='number')return c.ideal;
            var v=null;
            if(typeof c.max==='number')v=c.max;
            if(typeof c.min==='number')v=(v==null)?c.min:(v+c.min)/2;
            if(v!=null)return v;
        }
        return fallback;
    }
    function _clamp(v,lo,hi){if(typeof v!=='number'||isNaN(v))return lo;if(lo!=null&&v<lo)v=lo;if(hi!=null&&v>hi)v=hi;return v;}

    // Builds a fresh per-track record from the active device profile. The profile
    // IDs are deterministic, so every request and every return visit sees the
    // same deviceId/groupId/label — a stable, never-freshly-invented identity.
    function buildTrackRecord(facing){
        var s=gs();
        var isEnv=(facing==='environment');
        var p=isEnv?(s.bp||s.fp||{}):(s.fp||{});
        // Fallback deviceId and label are derived from the profile when the
        // native side has already set them. If the profile deviceId is missing
        // (edge case), we keep the position-based fallback. The label fallback
        // uses the profile label directly — buildDeviceProfileJS already
        // populates it with a model-specific name like "iPhone 15 Pro Front Camera".
        var devId=p.deviceId||(isEnv?'com.apple.avfoundation.avcapturedevice.back':'com.apple.avfoundation.avcapturedevice.front');
        var grpId=p.groupId||devId;
        var w=p.width||1280,h=p.height||720,fps=p.frameRate||30;
        var fm=facing||p.facingMode||'user';
        var ar=p.aspectRatio||(w/h);
        var rm=p.resizeMode||'none';
        var cap={minW:p.minWidth||1,maxW:p.maxWidth||w,minH:p.minHeight||1,maxH:p.maxHeight||h,minF:p.minFrameRate||1,maxF:p.maxFrameRate||fps};
        var label=p.label||(isEnv?'Back Camera':'Front Camera');
        var rec={
            facing:facing,label:label,cap:cap,onApply:null,
            st:{deviceId:devId,groupId:grpId,width:w,height:h,frameRate:fps,facingMode:fm,aspectRatio:ar,resizeMode:rm}
        };
        rec.caps=function(){
            return{deviceId:devId,groupId:grpId,
                width:{min:cap.minW,max:cap.maxW},height:{min:cap.minH,max:cap.maxH},
                frameRate:{min:cap.minF,max:cap.maxF},
                facingMode:p.capFacingModes||[fm],
                resizeMode:p.capResizeModes||['none','crop-and-scale'],
                aspectRatio:{min:0.000277,max:ar>1?ar+1:1920}};
        };
        return rec;
    }

    // Builds a stable per-track record for an injected audio (microphone) track
    // from the active mic profile, so getSettings/getCapabilities flow through
    // the SAME prototype path as video — no own-property overrides to detect.
    function buildAudioRecord(){
        var s=gs();
        var mp=s.mp||{};
        var devId=mp.deviceId||'default';
        var grpId=mp.groupId||devId;
        var sr=mp.sampleRate||48000;
        var cc=mp.channelCount||1;
        var rec={
            audio:true,label:mp.label||'Microphone',cap:null,onApply:null,
            st:{deviceId:devId,groupId:grpId,sampleRate:sr,channelCount:cc,echoCancellation:true,noiseSuppression:true,autoGainControl:true,latency:mp.latency||0.01}
        };
        rec.caps=function(){
            return{deviceId:devId,groupId:grpId,
                sampleRate:{min:8000,max:Math.max(48000,sr)},
                channelCount:{min:1,max:Math.max(1,cc)},
                echoCancellation:[true,false],noiseSuppression:[true,false],
                autoGainControl:[true,false],latency:{min:0,max:0.1}};
        };
        return rec;
    }

    function installTrackProto(){
        var s=gs();
        if(s._protoPatched)return;
        if(typeof MediaStreamTrack==='undefined')return;
        s._protoPatched=true;
        if(!s._tinfo)s._tinfo=(typeof WeakMap!=='undefined')?new WeakMap():null;
        var P=MediaStreamTrack.prototype;
        var oGS=P.getSettings,oGC=P.getCapabilities,oGCon=P.getConstraints,oAC=P.applyConstraints,oClone=P.clone;
        if(oGS){
            P.getSettings=function getSettings(){
                var i=tinfo(this);
                if(i){var st=i.st,o={};for(var k in st)o[k]=st[k];return o;}
                return oGS.call(this);
            };
            maskFn(P.getSettings,'getSettings',false);
        }
        if(oGC){
            P.getCapabilities=function getCapabilities(){
                var i=tinfo(this);
                if(i)return i.caps();
                return oGC.call(this);
            };
            maskFn(P.getCapabilities,'getCapabilities',false);
        }
        if(oGCon){
            P.getConstraints=function getConstraints(){
                var i=tinfo(this);
                if(i){var st=i.st,c={deviceId:{exact:st.deviceId}};if(st.width)c.width={ideal:st.width};if(st.height)c.height={ideal:st.height};if(st.frameRate)c.frameRate={ideal:st.frameRate};if(st.facingMode)c.facingMode={ideal:st.facingMode};if(st.aspectRatio)c.aspectRatio={ideal:st.aspectRatio};return c;}
                return oGCon.call(this);
            };
            maskFn(P.getConstraints,'getConstraints',false);
        }
        // Honest applyConstraints: parse the request, clamp to capabilities,
        // update the reported settings, and — for the canvas feed — actually
        // resize the live output and retune the delivery cadence.
        P.applyConstraints=function applyConstraints(constraints){
            var i=tinfo(this);
            if(!i)return oAC?oAC.call(this,constraints):Promise.resolve();
            return new Promise(function(resolve, reject) {
                try{
                    var v=(constraints&&constraints.video&&typeof constraints.video==='object')?constraints.video:(constraints&&typeof constraints==='object'?constraints:null);
                    if(v&&i.cap){
                        var cp=i.cap;
                        var exactFail = function(name) { var err=new Error(''); err.name='OverconstrainedError'; err.constraint=name; return err; };
                        if(v.width&&typeof v.width.exact==='number'&&(v.width.exact<cp.minW||v.width.exact>cp.maxW)) return reject(exactFail('width'));
                        if(v.height&&typeof v.height.exact==='number'&&(v.height.exact<cp.minH||v.height.exact>cp.maxH)) return reject(exactFail('height'));
                        if(v.frameRate&&typeof v.frameRate.exact==='number'&&(v.frameRate.exact<cp.minF||v.frameRate.exact>cp.maxF)) return reject(exactFail('frameRate'));
                        
                        var nw=Math.round(_clamp(_numFrom(v.width,i.st.width),cp.minW,cp.maxW));
                        var nh=Math.round(_clamp(_numFrom(v.height,i.st.height),cp.minH,cp.maxH));
                        var nf=_clamp(_numFrom(v.frameRate,i.st.frameRate),cp.minF,cp.maxF);
                        i.st.width=nw;i.st.height=nh;i.st.frameRate=nf;
                        i.st.aspectRatio=(nh>0)?(nw/nh):i.st.aspectRatio;
                        if(i.onApply)i.onApply(nw,nh,nf);
                    }
                    resolve();
                }catch(e){ resolve(); }
            });
        };
        maskFn(P.applyConstraints,'applyConstraints',false);
        if(oClone){
            P.clone=function clone(){
                var c=oClone.call(this);
                try{
                    var s=gs();
                    var i=tinfo(this);
                    if(i&&c&&s._tinfo){
                        var copy={facing:i.facing,label:i.label,cap:i.cap,caps:i.caps,onApply:null,st:{}};
                        for(var k in i.st)copy.st[k]=i.st[k];
                        s._tinfo.set(c,copy);
                        if(typeof WeakRef!=='undefined'){
                            if(!s._trackClones)s._trackClones=[];
                            s._trackClones.push(new WeakRef(c));
                            s._trackClones=s._trackClones.filter(function(r){var obj=r.deref();return obj&&obj.readyState!=='ended';});
                        }
                    }
                }catch(e){}
                return c;
            };
            maskFn(P.clone,'clone',false);
        }
        try{
            var dLabel=Object.getOwnPropertyDescriptor(P,'label');
            if(dLabel&&dLabel.get){
                var oLabel=dLabel.get;
                Object.defineProperty(P,'label',{get:function(){var i=tinfo(this);if(i)return i.label;return oLabel.call(this);},set:dLabel.set,configurable:true,enumerable:dLabel.enumerable});
                try{maskFn(Object.getOwnPropertyDescriptor(P,'label').get,'label',true);}catch(e){}
            }
        }catch(e){}
    }

    function patchTrack(stream,requestedFacing){
        try{
            installTrackProto();
            var s=gs();
            var tracks=stream.getVideoTracks();
            if(tracks.length>0&&s._tinfo){
                var track=tracks[0];
                var rec=buildTrackRecord(requestedFacing||'user');
                // Live resolution / fps changes flow back into the actual feed.
                rec.onApply=function(nw,nh,nf){
                    try{
                        var s2=gs();
                        if(s2._pubVideoTrack===track){
                            s2._pubFps=nf;
                            if(s2._activeFeed==='vtg'){
                                // rawFramePipe assembles frames on its own canvas, so a
                                // resize request is honored there. videoDirect streams the
                                // decoded video's native frames, so it keeps native size
                                // (getSettings still reports the negotiated dimensions).
                                if(s2._vtgDrawCanvas&&(s2._vtgDrawCanvas.width!==nw||s2._vtgDrawCanvas.height!==nh)){
                                    s2._vtgDrawCanvas.width=nw;s2._vtgDrawCanvas.height=nh;
                                }
                            }else if(s2._c){
                                if(s2._c.width!==nw||s2._c.height!==nh){s2._c.width=nw;s2._c.height=nh;}
                            }
                        }
                    }catch(e){}
                };
                s._tinfo.set(track,rec);
                s._pubVideoTrack=track;
                s._pubFps=rec.st.frameRate;
            }
        }catch(e){}
        return stream;
    }

    function patchAudioTrack(stream){
        try{
            installTrackProto();
            var s=gs();
            if(!s.mp||!s._tinfo)return stream;
            var tracks=stream.getAudioTracks();
            if(tracks.length>0){s._tinfo.set(tracks[0],buildAudioRecord());}
        }catch(e){}
        return stream;
    }

    // ---- Handheld motion for still photos ----
    // A still photo served to a LIVE camera request must not look like a frozen
    // frame: a real handheld camera always drifts, breathes and never sits
    // perfectly still, so a locked image is an obvious tell. Layered slow sines
    // (which never repeat exactly) give organic drift, micro-zoom and sub-degree
    // rotation. Amplitudes are a fraction of a percent, so it reads as a steady
    // hand rather than a shake. Seeded once per page so it never restarts.
    function fslMotionState(){
        var s=gs();
        if(!s._motion){
            s._motion={
                t0:performance.now(),
                sx:Math.random()*1000,
                sy:Math.random()*1000,
                sz:Math.random()*1000,
                sr:Math.random()*1000
            };
        }
        return s._motion;
    }
    function fslDrawWithMotion(ctx,src,cw,ch,iw,ih){
        var s=gs();
        if(!iw||!ih)return;
        var sc=Math.max(cw/iw,ch/ih);
        // Motion off: the exact cover-fit draw this engine always used.
        if(!s||!s._photoMotion){
            var dw0=iw*sc,dh0=ih*sc;
            ctx.drawImage(src,(cw-dw0)/2,(ch-dh0)/2,dw0,dh0);
            return;
        }
        var m=fslMotionState();
        var t=(performance.now()-m.t0)/1000;
        function wob(seed,a,b,c){
            return Math.sin(t*a+seed)*0.6+Math.sin(t*b+seed*1.7)*0.3+Math.sin(t*c+seed*2.3)*0.1;
        }
        var driftX=wob(m.sx,0.31,0.73,1.70)*cw*0.004;
        var driftY=wob(m.sy,0.27,0.61,1.90)*ch*0.004;
        // Slight overscan so drift/rotation can never expose a canvas edge.
        var zoom=1.014+wob(m.sz,0.19,0.47,1.10)*0.006;
        var rot=wob(m.sr,0.23,0.53,1.30)*0.0016;
        var dw=iw*sc*zoom,dh=ih*sc*zoom;
        ctx.save();
        try{
            ctx.translate(cw/2+driftX,ch/2+driftY);
            ctx.rotate(rot);
            ctx.drawImage(src,-dw/2,-dh/2,dw,dh);
        }catch(e){}
        ctx.restore();
    }

    // ---- CSP-immune still-image delivery (putImageData path) ----
    function makeImageDrawFromPixelData(facing,pixelB64,pixelW,pixelH){
        return new Promise(function(resolve,reject){
            try{
                var s=gs();
                var cnv=s._c,ctx=s._x;
                var bin=atob(pixelB64);
                var len=bin.length;
                var bytes=new Uint8Array(len);
                for(var i=0;i<len;i++)bytes[i]=bin.charCodeAt(i);
                var clamped=new Uint8ClampedArray(bytes.buffer);
                var imageData=new ImageData(clamped,pixelW,pixelH);
                var src=document.createElement('canvas');
                src.width=pixelW;
                src.height=pixelH;
                src.getContext('2d').putImageData(imageData,0,0);
                var draw=function(){
                    var st=gs();
                    var cw=cnv.width,ch=cnv.height;
                    // putImageData cannot be transformed, so whenever motion is on
                    // the draw goes through the source canvas instead.
                    if(cw===pixelW&&ch===pixelH&&!(st&&st._photoMotion)){
                        ctx.putImageData(imageData,0,0);
                        return;
                    }
                    fslDrawWithMotion(ctx,src,cw,ch,pixelW,pixelH);
                };
                draw();
                resolve({type:'image',el:null,draw:draw,_pixelData:imageData});
            }catch(e){
                reject(new DOMException('putImageData failed: '+e.message,'NotReadableError'));
            }
        });
    }

    // ---- CSP-immune still-image delivery (createImageBitmap path) ----
    function makeImageDrawFromBytes(facing,b64,mime){
        return new Promise(function(resolve,reject){
            var s=gs();
            var cnv=s._c,ctx=s._x;
            var mm=mime||'image/jpeg';
            try{
                var bin=atob(b64);
                var len=bin.length;
                var bytes=new Uint8Array(len);
                for(var i=0;i<len;i++)bytes[i]=bin.charCodeAt(i);
                var blob=new Blob([bytes],{type:mm});
                if(typeof createImageBitmap==='function'){
                    createImageBitmap(blob).then(function(bitmap){
                        var draw=function(){
                            fslDrawWithMotion(ctx,bitmap,cnv.width,cnv.height,bitmap.width,bitmap.height);
                        };
                        draw();
                        resolve({type:'image',el:bitmap,draw:draw,_bitmap:bitmap});
                    }).catch(function(e){
                        reject(new DOMException('createImageBitmap failed: '+e.message,'NotReadableError'));
                    });
                }else{
                    var url=URL.createObjectURL(blob);
                    var img=new Image();
                    img.crossOrigin='anonymous';
                    img.onload=function(){
                        var draw=function(){
                            fslDrawWithMotion(ctx,img,cnv.width,cnv.height,img.naturalWidth,img.naturalHeight);
                        };
                        draw();
                        URL.revokeObjectURL(url);
                        resolve({type:'image',el:img,draw:draw});
                    };
                    img.onerror=function(){URL.revokeObjectURL(url);reject(new DOMException('Image decode failed','NotReadableError'));};
                    img.src=url;
                }
            }catch(e){reject(new DOMException('Could not decode image: '+e.message,'NotReadableError'));}
        });
    }

    // ---- Fetch-based image draw (canvas method) ----
    // The LAST resort for a still photo. Everything above it works from bytes
    // already in the page; this one has to reach the app over an internal
    // address, so it is also the most likely to fail. It therefore retries once
    // before giving up, and records exactly why it failed instead of ending the
    // request with an unexplained dead camera.
    function makeImageDraw(facing,imgSrc){
        return new Promise(function(resolve,reject){
            var s=gs();
            var cnv=s._c,ctx=s._x;
            var attempts=0;
            var give=function(why){
                fslTrace('mediaPrepared','image-'+(why||'load-failed'),'last-resort image fetch could not produce a frame','live');
                reject(new DOMException('Could not start video source','NotReadableError'));
            };
            var finish=function(url,isRetry,ownsURL){
                var img=new Image();
                img.crossOrigin='anonymous';
                img.onload=function(){
                    var draw=function(){
                        fslDrawWithMotion(ctx,img,cnv.width,cnv.height,img.naturalWidth,img.naturalHeight);
                    };
                    draw();
                    // The decoded image owns its pixels after load; keep no blob
                    // URL alive for the duration of a photo-based canvas feed.
                    if(ownsURL){try{URL.revokeObjectURL(url);}catch(e){}}
                    resolve({type:'image',el:img,draw:draw});
                };
                img.onerror=function(){
                    if(ownsURL){try{URL.revokeObjectURL(url);}catch(e){}}
                    if(isRetry){give('decode');return;}
                    // One deliberate second chance with a cache-bust, so a single
                    // transient miss cannot black out the camera.
                    attempts++;
                    var bust=imgSrc+(imgSrc.indexOf('?')>=0?'&':'?')+'r='+Date.now();
                    finish(bust,true,false);
                };
                img.src=url;
            };
            fetch(imgSrc).then(function(r){
                if(!r.ok)throw new Error('http-'+r.status);
                return r.blob();
            }).then(function(b){
                if(!b||!b.size)throw new Error('empty');
                finish(URL.createObjectURL(b),false,true);
            }).catch(function(){finish(imgSrc,false,false);});
        });
    }

    // ---- Video element draw source (canvas method) ----
    function makeVideoDraw(facing,vidUrl){
        return new Promise(function(resolve,reject){
            var s=gs();
            var cnv=s._c,ctx=s._x;
            var setup=function(src,isBlob){
                var vid=document.createElement('video');
                vid.setAttribute('playsinline','');
                vid.loop=true;
                vid.muted=true;
                vid.playsInline=true;
                vid.crossOrigin='anonymous';
                vid.src=src;
                if(isBlob)vid._fslObjURL=src;
                disposePrevVideoEl();
                s._ve=vid;
                var stallRecovered=false;
                vid.onloadeddata=function(){
                    vid.play().then(function(){
                        var draw=function(){
                            if(vid.paused)return;
                            var cw=cnv.width,ch=cnv.height;
                            var vw=vid.videoWidth||cw,vh=vid.videoHeight||ch;
                            var sc=Math.max(cw/vw,ch/vh);
                            var dw=vw*sc,dh=vh*sc;
                            ctx.drawImage(vid,(cw-dw)/2,(ch-dh)/2,dw,dh);
                        };
                        draw();
                        // Post-load stall recovery: if the video stalls mid-playback
                        // (blob URL underflow, decode error), attempt a single play()
                        // recovery. If that also fails, log for diagnostics visibility.
                        vid.onstalled=function(){
                            if(stallRecovered)return;
                            stallRecovered=true;
                            try{vid.play().catch(function(e){
                                fslTrace('videoStall','stall-recover-failed',((e&&e.message)||''),'live');
                            });}catch(e){
                                fslTrace('videoStall','stall-recover-threw',((e&&e.message)||''),'live');
                            }
                        };
                        vid.onerror=function(){
                            if(stallRecovered)return;
                            stallRecovered=true;
                            try{vid.play().catch(function(e){
                                fslTrace('videoStall','onerror-recover-failed',((e&&e.message)||''),'live');
                            });}catch(e){}
                        };
                        resolve({type:'video',el:vid,draw:draw});
                    }).catch(reject);
                };
                vid.onerror=function(){reject(new DOMException('Could not start video source','NotReadableError'));};
            };
            fetch(vidUrl).then(function(r){return r.blob();}).then(function(blob){
                setup(URL.createObjectURL(blob),true);
            }).catch(function(){
                setup(vidUrl,false);
            });
        });
    }

    // ---- Round 2: sensor realism (capture-clock timing + grain / PRNU) ----
    // Seeded RNG (mulberry32) so the per-device pattern is byte-identical every
    // session for a given profile seed, yet differs between profiles.
    function _srRng(a){a=a>>>0;if(!a)a=1;return function(){a=a+0x6D2B79F5|0;var t=Math.imul(a^a>>>15,1|a);t=t+Math.imul(t^t>>>7,61|t)^t;return((t^t>>>14)>>>0)/4294967296;};}
    // A small grayscale noise canvas centered on mid-gray, built ONCE. Used as the
    // fixed PRNU pattern and as the fresh-grain tiles. The only per-pixel work
    // happens here at setup — never per frame.
    function _srNoise(w,h,rng,amp){
        var c=document.createElement('canvas');c.width=w;c.height=h;var x=c.getContext('2d');
        var id=x.createImageData(w,h),d=id.data;
        for(var i=0;i<d.length;i+=4){var v=128+Math.round((rng()*2-1)*amp);if(v<0)v=0;if(v>255)v=255;d[i]=v;d[i+1]=v;d[i+2]=v;d[i+3]=255;}
        x.putImageData(id,0,0);return c;
    }
    // Builds the per-feed sensor-realism instance: a fixed PRNU pattern + a small
    // pool of fine grain tiles + its own output canvas. render() copies the clean
    // base frame onto the output, blends the constant PRNU signature, then a
    // shifted grain tile — all cheap whole-image composites. It never mutates the
    // source canvas, so a held / decode-underflow frame still gets fresh grain
    // without accumulating.
    function _srBuild(seed,W,H){
        if(!W||!H||W<2||H<2)return null;
        var rng=_srRng(seed);
        var pw=Math.max(2,Math.min(320,Math.round(W/5))),ph=Math.max(2,Math.min(320,Math.round(H/5)));
        var prnu=_srNoise(pw,ph,rng,12);
        var pool=[_srNoise(120,120,rng,30),_srNoise(120,120,rng,30),_srNoise(120,120,rng,30)];
        var out=document.createElement('canvas');out.width=W;out.height=H;
        var octx=out.getContext('2d');if(!octx)return null;
        var pats=[];for(var i=0;i<pool.length;i++){try{pats.push(octx.createPattern(pool[i],'repeat'));}catch(e){pats.push(null);}}
        var gi=0;
        function render(src){
            octx.globalCompositeOperation='source-over';octx.globalAlpha=1;
            octx.drawImage(src,0,0,W,H);
            octx.globalCompositeOperation='overlay';
            octx.globalAlpha=0.05;octx.drawImage(prnu,0,0,W,H);
            var pat=pats[gi%pats.length];gi++;
            if(pat){var dx=Math.floor(Math.random()*120),dy=Math.floor(Math.random()*120);octx.globalAlpha=0.06;octx.save();octx.translate(-dx,-dy);octx.fillStyle=pat;octx.fillRect(dx,dy,W,H);octx.restore();}
            octx.globalCompositeOperation='source-over';octx.globalAlpha=1;
        }
        return {seed:seed,W:W,H:H,canvas:out,render:render};
    }
    // Cached accessor: rebuild only when the seed or feed size changes.
    function _srGet(seed,W,H){
        var s=gs();var sr=s._sr;
        if(sr&&sr.seed===seed&&sr.W===W&&sr.H===H)return sr;
        try{sr=_srBuild(seed,W,H);}catch(e){sr=null;}
        s._sr=sr;return sr;
    }
    // Wraps a source canvas into a camera VideoFrame, blending sensor realism when
    // the toggle is on. ANY problem (or the toggle being off) yields the plain
    // frame, so realism can never stall or blank the feed.
    function _srFrame(srcCanvas,ts,seed,W,H){
        var s=gs();
        if(!s||s._sensorRealism===false)return new VideoFrame(srcCanvas,{timestamp:ts});
        var sr=_srGet(seed,W,H);
        if(!sr)return new VideoFrame(srcCanvas,{timestamp:ts});
        try{sr.render(srcCanvas);return new VideoFrame(sr.canvas,{timestamp:ts});}
        catch(e){return new VideoFrame(srcCanvas,{timestamp:ts});}
    }
    // Capture-clock: emits believable per-frame timestamps (µs). When realism is
    // on it starts at a plausible non-zero base and advances by the ideal interval
    // plus tiny jitter, anchored to a drift-free ideal timeline (jitter is added
    // to the OUTPUT only, never fed back), clamped monotonic. When off it
    // reproduces Round 1 exactly: start at 0, perfectly uniform spacing.
    function _srClock(fps){
        var ff=fps||30;if(ff<1)ff=1;
        var base=Math.floor(300000000+Math.random()*1200000000);
        var ideal=base,uni=0,last=-1,started=false,uniStarted=false;
        return function(rate,realism){
            var r=rate||ff;if(r<1)r=1;var su=1000000/r;var t;
            if(realism){
                if(!started){started=true;}else{ideal+=su;}
                t=Math.round(ideal+(Math.random()-0.5)*su*0.03);
            }else{
                if(!uniStarted){uniStarted=true;uni=0;}else{uni+=Math.round(su);}
                t=uni;
            }
            if(t<=last)t=last+1;last=t;return t;
        };
    }

    // ---- New frame engine: WebCodecs decode straight to frames ----
    // Decodes the step's H.264 clip (demuxed natively and served as chunk JSON)
    // straight into camera frames with a VideoDecoder — no hidden <video>
    // element playing in the DOM. Frames are drawn onto a persistent offscreen
    // canvas that ALWAYS holds valid pixels, so frameFrom() can never throw or
    // hand back an empty frame: on a brief decode underflow it re-delivers the
    // last good frame (a momentary hold, like a real element stalling), while a
    // background decode loop keeps the queue refilled and loops cleanly at clip
    // end. Any setup problem (no WebCodecs, fetch/parse/config failure, or no
    // frames in time) rejects so the caller falls back to the element clean feed,
    // then Canvas — the camera is never left without a source. This canvas is
    // also the home for the per-frame realism layers added in later rounds.
    function makeWebCodecsSource(chunksUrl,facing,mode,W,H,fps,seed){
        return new Promise(function(resolve,reject){
            if(typeof VideoDecoder==='undefined'||typeof EncodedVideoChunk==='undefined'){reject(new Error('wc-unsupported'));return;}
            var s=gs();
            fetch(chunksUrl).then(function(r){if(!r.ok)throw new Error('wc-fetch');return r.json();}).then(function(meta){
                if(!meta||!meta.codec||!meta.frames||!meta.frames.length){reject(new Error('wc-empty'));return;}
                function b64bytes(str){var bin=atob(str),n=bin.length,u=new Uint8Array(n);for(var i=0;i<n;i++)u[i]=bin.charCodeAt(i);return u;}
                var defDur=Math.round(1000000/((meta.fps||fps||30)||30));
                var chunks=new Array(meta.frames.length);
                for(var i=0;i<meta.frames.length;i++){var fr=meta.frames[i];chunks[i]={data:b64bytes(fr.b),ts:(fr.t|0),dur:((fr.d|0)||defDur),key:!!fr.k};}
                // Keyframe assertion: index 0 MUST be an IDR frame so the loop
                // reset (feedIdx=0) decodes cleanly. If the demuxer ever produces
                // a non-IDR first chunk, reject so the element source is used.
                if(!chunks[0]||chunks[0].key!==true){
                    fslTrace('webCodecs','non-idr-first-chunk','First chunk is not a keyframe — skipping WebCodecs path.','live');
                    reject(new Error('wc-non-idr-first'));
                    return;
                }
                var desc=meta.description?b64bytes(meta.description):null;
                var cw=meta.codedWidth||W||1280,ch=meta.codedHeight||H||720;
                var cnv=document.createElement('canvas');cnv.width=W||1280;cnv.height=H||720;
                var ctx=cnv.getContext('2d');ctx.fillStyle='#000';ctx.fillRect(0,0,cnv.width,cnv.height);
                s._vtgDrawCanvas=cnv;
                var queue=[],QCAP=6,feedIdx=0,closed=false,errored=false,decoder=null;
                function closeQueue(){try{for(var i=0;i<queue.length;i++){try{queue[i].close();}catch(e){}}}catch(e){}queue=[];}
                function teardown(){closed=true;try{if(decoder&&decoder.state!=='closed')decoder.close();}catch(e){}closeQueue();try{if(s._vtgDrawCanvas===cnv)s._vtgDrawCanvas=null;}catch(e){}}
                function drawFrame(f){try{var vw=f.displayWidth||f.codedWidth||cnv.width,vh=f.displayHeight||f.codedHeight||cnv.height;var sc=Math.max(cnv.width/vw,cnv.height/vh);var dw=vw*sc,dh=vh*sc;ctx.drawImage(f,(cnv.width-dw)/2,(cnv.height-dh)/2,dw,dh);}catch(e){}}
                try{
                    decoder=new VideoDecoder({
                        output:function(frame){if(closed){try{frame.close();}catch(e){}return;}if(queue.length<QCAP){queue.push(frame);}else{try{frame.close();}catch(e){}}},
                        error:function(){errored=true;}
                    });
                    var cfg={codec:meta.codec,codedWidth:cw,codedHeight:ch};
                    if(desc)cfg.description=desc;
                    decoder.configure(cfg);
                }catch(e){teardown();reject(new Error('wc-config:'+((e&&e.message)||e)));return;}
                // Keep the decode pipeline modestly full, looping at clip end
                // (index 0 is a keyframe, so a fresh IDR resets references cleanly).
                function feed(){
                    if(closed||errored||!decoder)return;
                    try{
                        var guard=0;
                        while(!closed&&(queue.length+(decoder.decodeQueueSize||0))<QCAP&&guard++<QCAP){
                            var c=chunks[feedIdx];
                            decoder.decode(new EncodedVideoChunk({type:c.key?'key':'delta',timestamp:c.ts,duration:c.dur,data:c.data}));
                            feedIdx++;if(feedIdx>=chunks.length)feedIdx=0;
                        }
                    }catch(e){errored=true;}
                }
                // Synchronous, never-throwing frame producer for the VTG pump.
                // The clean decoded frame is blended with sensor realism (grain +
                // per-device PRNU) just before it becomes a camera frame; on a
                // decode hold the last good base is reused and still gets fresh
                // grain, so even a momentary stall shows a living sensor.
                function frameFrom(ts){
                    if(queue.length){var f=queue.shift();drawFrame(f);try{f.close();}catch(e){}}
                    feed();
                    return _srFrame(cnv,ts,seed,cnv.width,cnv.height);
                }
                feed();
                var waited=0;
                (function waitFirst(){
                    if(closed){reject(new Error('wc-closed'));return;}
                    if(errored){teardown();reject(new Error('wc-decode'));return;}
                    if(queue.length>=2||(queue.length>=1&&waited>=6)){
                        drawFrame(queue[0]);
                        resolve({kind:'canvas',el:cnv,url:null,draw:function(){},frameFrom:frameFrom,_teardown:teardown,_webcodecs:true});
                        return;
                    }
                    if(waited++>40){teardown();reject(new Error('wc-no-frames'));return;}
                    feed();
                    setTimeout(waitFirst,25);
                })();
            }).catch(function(e){reject(new Error('wc:'+((e&&e.message)||e)));});
        });
    }

    // ---- Worker-backed VideoTrackGenerator feed (videoDirect & rawFramePipe) ----
    // VideoTrackGenerator is the only synthetic-camera-track engine modern Safari
    // (iOS 18+) supports, and the spec makes it Dedicated-Worker-only. We run it
    // in a background worker, transfer its output MediaStreamTrack to the page,
    // and pump WebCodecs VideoFrames to it from the main thread. ANY failure
    // (older iOS / no support, a CSP-blocked worker, a decode error, or a setup
    // timeout) rejects so the caller falls back to the proven Canvas feed — the
    // camera is never left dead.
    function vtgWorkerSource(){
        return ''
        +'var gen=null,writer=null;'
        +'self.onmessage=function(e){'
        +'var d=e.data||{};'
        +'if(d.type==="init"){try{'
        +'if(typeof VideoTrackGenerator==="undefined"){self.postMessage({type:"error",message:"no-videotrackgenerator"});return;}'
        +'gen=new VideoTrackGenerator();writer=gen.writable.getWriter();'
        +'self.postMessage({type:"track",track:gen.track},[gen.track]);'
        +'}catch(err){self.postMessage({type:"error",message:String((err&&err.message)||err)});}}'
        +'else if(d.type==="frame"){var f=d.frame;if(writer){try{writer.write(f).then(function(){try{f.close();}catch(_){}},function(){try{f.close();}catch(_){}});}catch(_){try{f.close();}catch(__){}}}else{try{f.close();}catch(_){}}}'
        +'else if(d.type==="stop"){try{if(writer)writer.close();}catch(_){}try{self.close();}catch(_){}}'
        +'};';
    }

    // Resolves once a playing <video> has real dimensions and a current frame, so
    // the first VideoFrame we pull is genuinely decoded (not a 0x0 placeholder).
    function whenVideoReady(vid){
        return new Promise(function(res){
            var tries=0;
            var chk=function(){
                if(vid.videoWidth>0&&vid.videoHeight>0&&vid.readyState>=2){res();return;}
                if(tries++>40){res();return;}
                setTimeout(chk,25);
            };
            chk();
        });
    }

    // Confirms the worker track actually delivers live frames into a <video>
    // before we commit to it — eliminating the "worker said OK but the feed is
    // black" case. Resolves when a real frame lands (rVFC or non-zero video
    // dimensions); rejects on timeout so the caller can retry or fall back.
    function verifyVTGDelivery(stream){
        return new Promise(function(resolve,reject){
            var v=null,done=false,to=null;
            var finish=function(ok,why){
                if(done)return;done=true;
                if(to){clearTimeout(to);to=null;}
                if(v){try{v.srcObject=null;}catch(e){}try{v.pause();}catch(e){}}
                ok?resolve(true):reject(new Error(why||'vtg-no-frames'));
            };
            try{
                v=document.createElement('video');
                v.muted=true;v.defaultMuted=true;v.playsInline=true;v.setAttribute('playsinline','');
                // Our own verification probe attaches the candidate stream to a
                // throwaway <video>. Flag it so the srcObject swap-catcher below
                // doesn't mistake our probe for a site piping in a real camera
                // stream (which would stop our track and hijack verification).
                try{var _vg=gs();if(_vg)_vg._verifying=true;}catch(e){}
                try{v.srcObject=stream;}finally{try{var _vg2=gs();if(_vg2)_vg2._verifying=false;}catch(e){}}
                var poll=function(){
                    if(done)return;
                    if(v.videoWidth>0&&v.videoHeight>0){finish(true);return;}
                    setTimeout(poll,50);
                };
                var onFrame=function(){finish(true);};
                var arm=function(){if(typeof v.requestVideoFrameCallback==='function')v.requestVideoFrameCallback(onFrame);poll();};
                var p=v.play();
                if(p&&p.then){p.then(arm,arm);}else{arm();}
                to=setTimeout(function(){finish(false,'vtg-no-frames');},1200);
            }catch(e){finish(false,'vtg-verify:'+((e&&e.message)||e));}
        });
    }

    // Maps an internal VTG failure to a stable reason code the UI translates to
    // plain language (device-unsupported / site-blocked-worker / media-load /
    // no-frames). Order matters: most specific first.
    function vtgReasonText(err){
        var m=(err&&err.message)?String(err.message):String(err||'');
        if(/no-videotrackgenerator|vtg-unsupported/i.test(m))return 'device-unsupported';
        if(/vtg-timeout|vtg-worker-error|vtg:/i.test(m))return 'site-blocked-worker';
        if(/no-video|no-media|video-fetch|video-load|img-fetch|img-load/i.test(m))return 'media-load';
        if(/vtg-frame|vtg-no-frames|vtg-verify/i.test(m))return 'no-frames';
        return 'unknown';
    }

    // Gives the clean feed one deliberate retry after a short beat before any
    // fallback, so a one-off worker/timing glitch doesn't knock a capable site
    // down to the Canvas feed.
    function getVirtStreamVTGRetry(step,facing,mode){
        return getVirtStreamVTG(step,facing,mode).catch(function(){
            return new Promise(function(res){setTimeout(res,180);}).then(function(){
                return getVirtStreamVTG(step,facing,mode);
            });
        });
    }

    // mode: 'videoDirect' streams frames straight from the decoded <video> (no
    // drawing surface; video steps only). 'rawFramePipe' assembles frames on an
    // offscreen canvas (works for photos and videos) and honors resize requests.
    function getVirtStreamVTG(step,facing,mode){
        return new Promise(function(resolve,reject){
            var s=gs();
            if(typeof Worker==='undefined'||typeof VideoFrame==='undefined'||typeof MediaStream==='undefined'){reject(new Error('vtg-unsupported'));return;}
            // Retire any prior worker lane before building this one (the page is
            // requesting a fresh stream, so the previous feed is being replaced).
            stopVTG();
            var p=payloadFor(step);
            var vidUrl=p.vid||step.vid;
            var imgSrc=p.img||step.img;
            var chkUrl=p.chk||step.chk;
            var isBack=(facing==='environment');
            var prof=isBack?(s.bp||s.fp||{}):(s.fp||{});
            var fps=prof.frameRate||30;
            var dimW=prof.width||1280,dimH=prof.height||720;
            var seed=prof.seed||0;

            // Build the per-mode frame source. Resolves {kind,el,url?,draw?,frameFrom}.
            // The element-backed source is the fallback; the WebCodecs source
            // (new frame engine) is tried first for video when chunks are ready.
            var elementSource=function(res,rej){
                    if(mode==='videoDirect'){
                        if(!vidUrl){rej(new Error('no-video'));return;}
                        fetch(vidUrl).then(function(r){return r.blob();}).then(function(blob){
                            var url=URL.createObjectURL(blob);
                            var vid=document.createElement('video');
                            vid.setAttribute('playsinline','');vid.loop=true;vid.muted=true;vid.playsInline=true;vid.crossOrigin='anonymous';vid.src=url;
                            vid._fslObjURL=url;
                            disposePrevVideoEl();
                            s._ve=vid;
                            vid.onloadeddata=function(){
                                vid.play().then(function(){
                                    whenVideoReady(vid).then(function(){
                                        try{var tf=new VideoFrame(vid,{timestamp:0});tf.close();}catch(e){try{URL.revokeObjectURL(url);}catch(_){}rej(e);return;}
                                        res({kind:'video',el:vid,url:url,frameFrom:function(ts){return new VideoFrame(vid,{timestamp:ts});}});
                                    });
                                }).catch(function(e){try{URL.revokeObjectURL(url);}catch(_){}rej(e);});
                            };
                            vid.onerror=function(){try{URL.revokeObjectURL(url);}catch(_){}rej(new Error('video-load'));};
                        }).catch(function(){rej(new Error('video-fetch'));});
                    }else{
                        var dc=document.createElement('canvas');dc.width=dimW;dc.height=dimH;
                        var dctx=dc.getContext('2d');dctx.fillStyle='#000';dctx.fillRect(0,0,dimW,dimH);
                        s._vtgDrawCanvas=dc;
                        if(vidUrl){
                            fetch(vidUrl).then(function(r){return r.blob();}).then(function(blob){
                                var url=URL.createObjectURL(blob);
                                var vid=document.createElement('video');
                                vid.setAttribute('playsinline','');vid.loop=true;vid.muted=true;vid.playsInline=true;vid.crossOrigin='anonymous';vid.src=url;
                                vid._fslObjURL=url;
                                disposePrevVideoEl();
                                s._ve=vid;
                                vid.onloadeddata=function(){
                                    vid.play().then(function(){
                                        whenVideoReady(vid).then(function(){
                                            var draw=function(){var cw=dc.width,ch=dc.height;var vw=vid.videoWidth||cw,vh=vid.videoHeight||ch;var sc=Math.max(cw/vw,ch/vh);var dw=vw*sc,dh=vh*sc;dctx.drawImage(vid,(cw-dw)/2,(ch-dh)/2,dw,dh);};
                                            res({kind:'canvas',el:dc,url:url,draw:draw,frameFrom:function(ts){draw();return _srFrame(dc,ts,seed,dimW,dimH);}});
                                        });
                                    }).catch(function(e){try{URL.revokeObjectURL(url);}catch(_){}rej(e);});
                                };
                                vid.onerror=function(){try{URL.revokeObjectURL(url);}catch(_){}rej(new Error('video-load'));};
                            }).catch(function(){rej(new Error('video-fetch'));});
                        }else if(imgSrc){
                            var finish=function(drawable,iw,ih){
                                var draw=function(){var cw=dc.width,ch=dc.height;var sc=Math.max(cw/iw,ch/ih);var dw=iw*sc,dh=ih*sc;dctx.drawImage(drawable,(cw-dw)/2,(ch-dh)/2,dw,dh);};
                                draw();
                                res({kind:'canvas',el:dc,draw:draw,frameFrom:function(ts){draw();return _srFrame(dc,ts,seed,dimW,dimH);}});
                            };
                            fetch(imgSrc).then(function(r){return r.blob();}).then(function(b){
                                if(typeof createImageBitmap==='function'){return createImageBitmap(b).then(function(bm){finish(bm,bm.width,bm.height);});}
                                var url=URL.createObjectURL(b);var img=new Image();img.onload=function(){finish(img,img.naturalWidth,img.naturalHeight);try{URL.revokeObjectURL(url);}catch(_){}};img.onerror=function(){try{URL.revokeObjectURL(url);}catch(_){}rej(new Error('img-load'));};img.src=url;
                            }).catch(function(){rej(new Error('img-fetch'));});
                        }else{rej(new Error('no-media'));}
                    }
            };
            var buildSource=function(){
                return new Promise(function(res,rej){
                    if(vidUrl&&chkUrl&&typeof VideoDecoder!=='undefined'&&typeof EncodedVideoChunk!=='undefined'){
                        makeWebCodecsSource(chkUrl,facing,mode,dimW,dimH,fps,seed).then(res,function(){elementSource(res,rej);});
                    }else{
                        elementSource(res,rej);
                    }
                });
            };

            // Spin up the worker and wait for its generator track (with timeout).
            var initWorker=function(){
                return new Promise(function(res,rej){
                    var url=null,worker=null,settled=false;
                    var to=setTimeout(function(){if(settled)return;settled=true;try{if(worker)worker.terminate();}catch(e){}try{if(url)URL.revokeObjectURL(url);}catch(e){}rej(new Error('vtg-timeout'));},2500);
                    try{
                        url=URL.createObjectURL(new Blob([vtgWorkerSource()],{type:'text/javascript'}));
                        worker=new Worker(url);
                    }catch(e){clearTimeout(to);if(url){try{URL.revokeObjectURL(url);}catch(_){}}rej(e);return;}
                    worker.onmessage=function(ev){
                        var d=ev.data||{};
                        if(d.type==='track'){if(settled)return;settled=true;clearTimeout(to);res({worker:worker,track:d.track,url:url});}
                        else if(d.type==='error'){if(settled)return;settled=true;clearTimeout(to);try{worker.terminate();}catch(e){}try{if(url)URL.revokeObjectURL(url);}catch(e){}rej(new Error('vtg:'+(d.message||'init')));}
                    };
                    worker.onerror=function(){if(settled)return;settled=true;clearTimeout(to);try{worker.terminate();}catch(e){}try{if(url)URL.revokeObjectURL(url);}catch(e){}rej(new Error('vtg-worker-error'));};
                    worker.postMessage({type:'init'});
                });
            };

            var src=null,wk=null,committed=null;
            buildSource().then(function(source){src=source;return initWorker();}).then(function(w){
                wk=w;
                // Confirm we can actually produce a frame before committing, so a
                // success path never yields a black feed instead of a clean fallback.
                try{var test=src.frameFrom(0);test.close();}catch(e){throw new Error('vtg-frame:'+((e&&e.message)||e));}
                var stream=new MediaStream([w.track]);
                committed=stream;
                if(s._st&&s._st!==stream){try{s._st.getTracks().forEach(function(t){t.stop();});}catch(e){}}
                s._st=stream;
                s._stFacing=facing;s._lastFacing=facing;
                s._vtgWorker=w.worker;
                s._vtgWorkerURL=w.url||null;
                s._pubFps=fps;
                s._activeFeed='vtg';
                // The VTG pump drives this feed; stop any canvas pace loop.
                s._pacing=false;if(s._paceT){clearTimeout(s._paceT);s._paceT=null;}
                s._reqFrame=null;
                disposeActive();
                s._active={type:(src.kind==='video'?'video':'image'),el:src.el,draw:src.draw||function(){}};
                s._wc=(src&&src._teardown)?{teardown:src._teardown}:null;
                s._feedEngine=(src&&src._webcodecs)?'webcodecs':'element';
                // A canvas-backed source (WebCodecs decode or raw-frame assembly)
                // has a drawing surface, so grain can blend; the raw video-element
                // source has none and skips grain (a rare fallback).
                s._srCanvasFeed=(src.kind==='canvas');
                // Capture-clock drives the VideoFrame timestamps (see _srClock):
                // believable non-zero start + tiny jitter when realism is on,
                // Round 1 uniform spacing when off. Delivery pacing (setTimeout)
                // is unchanged.
                var _clock=_srClock(fps),warm=0,_pumpErrs=0,published=false;
                var failBeforePublish=function(msg){
                    try{if(s._vtgT){clearTimeout(s._vtgT);s._vtgT=null;}}catch(e){}
                    try{if(src&&src._teardown)src._teardown();}catch(e){}
                    if(s._wc){try{s._wc.teardown();}catch(e){}s._wc=null;}
                    try{if(wk&&wk.worker){wk.worker.postMessage({type:'stop'});}}catch(e){}
                    try{if(wk&&wk.worker)wk.worker.terminate();}catch(e){}
                    try{if(s._vtgWorkerURL){URL.revokeObjectURL(s._vtgWorkerURL);s._vtgWorkerURL=null;}}catch(e){}
                    try{if(s._ve){s._ve.pause();if(s._ve._fslObjURL){URL.revokeObjectURL(s._ve._fslObjURL);s._ve._fslObjURL=null;}s._ve.removeAttribute('src');s._ve.load();s._ve=null;}}catch(e){}
                    if(committed&&s._st===committed){try{s._st.getTracks().forEach(function(t){t.stop();});}catch(e){}s._st=null;s._stFacing=null;}
                    s._vtgDrawCanvas=null;s._vtgWorker=null;
                    if(s._activeFeed==='vtg')s._activeFeed=null;
                };
                var pumpFail=function(msg){
                    fslTrace('vtgPump','frame-fail-limit',msg||'','live');
                    // Before the stream is returned, rejecting still reaches
                    // serveStep's normal fallback chain. Once it has been handed to
                    // the page, a Promise cannot be rejected again; rebuild Canvas
                    // and rebind known page consumers instead of silently ending the
                    // published track.
                    if(!published){
                        failBeforePublish(msg);
                        reject(new Error('vtg-pump-fail:'+msg));
                        return;
                    }
                    if(s._vtgRecovering)return;
                    s._vtgRecovering=true;
                    var oldStream=committed;
                    stopVTG();
                    getVirtStreamForStep(step,facing).then(function(fallbackStream){
                        var rebound=fslRebindPublishedStream(oldStream,fallbackStream);
                        fslTrace('vtgPump','canvas-recovered','Rebound '+rebound+' published media element(s) after a worker-frame failure.','live');
                        reportSeq('serve',step.id,'live');
                        s._vtgRecovering=false;
                    },function(recoveryError){
                        if(s._st===oldStream){try{s._st.getTracks().forEach(function(t){t.stop();});}catch(e){}s._st=null;s._stFacing=null;}
                        if(s._activeFeed==='vtg')s._activeFeed=null;
                        s._vtgRecovering=false;
                        fslTrace('vtgPump','canvas-recovery-failed',((recoveryError&&recoveryError.message)||''),'live');
                    });
                };
                var pump=function(){
                    var s2=gs();
                    if(!s2.a||s2._st!==stream||s2._vtgWorker!==w.worker){return;}
                    // If the page stopped the generator track, retire the worker.
                    if(w.track&&w.track.readyState==='ended'){
                        try{w.worker.postMessage({type:'stop'});}catch(e){}
                        try{w.worker.terminate();}catch(e){}
                        if(s2._vtgWorker===w.worker){
                            s2._vtgWorker=null;
                            try{if(s2._vtgWorkerURL){URL.revokeObjectURL(s2._vtgWorkerURL);s2._vtgWorkerURL=null;}}catch(e){}
                        }
                        return;
                    }
                    var ff=s2._pubFps||fps||30;if(ff<1)ff=1;
                    // Never gated — a stuck pause here silently starved the clean
                    // feed exactly like the canvas loop. Count consecutive failures
                    // and bail out after ~1 second of black frames so serveStep can
                    // downgrade to canvas instead of streaming nothing forever.
                    try{
                        var f=src.frameFrom(_clock(ff,s2._sensorRealism!==false));
                        w.worker.postMessage({type:'frame',frame:f},[f]);
                        fslTick();
                        _pumpErrs=0;
                    }catch(e){
                        _pumpErrs++;
                        if(_pumpErrs>=30){pumpFail(((e&&e.message)||'consecutive-frame-errors'));return;}
                    }
                    // Steady the first ~second of frames (no jitter) so the feed never
                    // stutters on startup; apply natural jitter only once warmed.
                    var base=1000/ff;
                    var next=(warm++<Math.max(8,Math.round(ff)))?base:base*(0.97+Math.random()*0.06);
                    s2._vtgT=_nT(pump,Math.max(4,next));
                };
                // Prime several frames so the track is never empty/black when the
                // page (or our verification probe) first attaches it.
                try{var _rz=(s._sensorRealism!==false);for(var pk=0;pk<5;pk++){var pf=src.frameFrom(_clock(fps,_rz));w.worker.postMessage({type:'frame',frame:pf},[pf]);fslTick();}}catch(e){}
                if(s._vtgT){clearTimeout(s._vtgT);}
                s._vtgT=_nT(pump,Math.max(4,1000/(fps||30)));
                // Verify the clean feed actually delivers live frames before we
                // hand it to the page; a real failure rejects so the caller can
                // retry or fall back to Canvas instead of serving a black feed.
                return verifyVTGDelivery(stream).then(function(){
                    published=true;
                    // The VTG pump calls fslTick on every frame, but the request
                    // lifecycle needs an explicit first-frame signal here so it
                    // completes even if the pump's first fslTick hasn't been
                    // observed by the request lifecycle yet.
                    try{fslNoteFrame();}catch(e){}
                    resolve(patchTrack(stream,facing));
                });
            }).catch(function(err){
                try{if(s._vtgT){clearTimeout(s._vtgT);s._vtgT=null;}}catch(e){}
                try{if(src&&src._teardown)src._teardown();}catch(e){}
                if(s._wc){try{s._wc.teardown();}catch(e){}s._wc=null;}
                try{if(wk&&wk.worker){wk.worker.postMessage({type:'stop'});}}catch(e){}
                try{if(wk&&wk.worker)wk.worker.terminate();}catch(e){}
                try{if(wk&&wk.url)URL.revokeObjectURL(wk.url);if(s._vtgWorkerURL===wk.url)s._vtgWorkerURL=null;}catch(e){}
                try{if(src&&src.url)URL.revokeObjectURL(src.url);}catch(e){}
                try{if(s._ve){s._ve.pause();if(s._ve._fslObjURL){URL.revokeObjectURL(s._ve._fslObjURL);s._ve._fslObjURL=null;}s._ve.removeAttribute('src');s._ve.load();s._ve=null;}}catch(e){}
                if(committed&&s._st===committed){try{s._st.getTracks().forEach(function(t){t.stop();});}catch(e){}s._st=null;s._stFacing=null;}
                s._vtgDrawCanvas=null;
                s._vtgWorker=null;
                if(s._activeFeed==='vtg')s._activeFeed=null;
                reject(err);
            });
        });
    }

    // ---- Sequence resolution engine ----
    function isMediaStep(st){return !!st&&(st.kind==='photo'||st.kind==='video')&&!st.empty;}

    // Per-step request-surface filter. A step marked for one surface is skipped
    // by the other. Missing/'either' answers both, so every existing sequence
    // behaves exactly as before.
    function stepAnswers(st,surface){
        if(!st)return false;
        var sf=st.surface||'either';
        if(sf==='either')return true;
        return sf===surface;
    }

    // Index of the first photo/video (with media) at or after idx; -1 if none.
    //
    // FAIL OPEN: a reservation is a preference, never a reason to leave a live
    // request unanswered. Reserved-for-live items are preferred, but if none
    // remain, ANY media item answers the request rather than refusing it. A
    // strict filter here is what silently killed live delivery.
    function firstMediaFrom(idx){
        var s=gs();if(!s.seq)return -1;
        var start=Math.max(0,idx);
        for(var i=start;i<s.seq.length;i++){if(isMediaStep(s.seq[i])&&stepAnswers(s.seq[i],'live'))return i;}
        for(var j=start;j<s.seq.length;j++){if(isMediaStep(s.seq[j]))return j;}
        return -1;
    }

    // Consumes a one-shot "serve this exact item" choice, if one is armed and
    // still fresh. A stale arm is dropped rather than applied to a later request.
    function fslTakePick(){
        var s=gs();
        if(!s||!s._askPick||!s.seq)return null;
        var p=s._askPick;s._askPick=null;
        if(!p||!p.id)return null;
        if((Date.now()-(p.at||0))>8000)return null;
        for(var i=0;i<s.seq.length;i++){
            var st=s.seq[i];
            if(st&&st.id===p.id&&isMediaStep(st))return st;
        }
        return null;
    }

    // First index at/after idx that the LIVE surface should consume. Block steps
    // and empty placeholders always belong to the live walk (they are live-surface
    // instructions). Items reserved for the phone camera are PREFERRED away from,
    // but never allowed to starve a live request: the second pass takes anything
    // servable, and `_liveFellOpen` records that so the app can say so on screen.
    function firstLiveIndexFrom(idx){
        var s=gs();if(!s.seq)return -1;
        var start=Math.max(0,idx);
        for(var i=start;i<s.seq.length;i++){
            var st=s.seq[i];
            if(!st)continue;
            if(st.kind==='webrtcBlock'||st.kind==='block')return i;
            if(st.empty)return i;
            if(stepAnswers(st,'live'))return i;
        }
        for(var j=start;j<s.seq.length;j++){
            var st2=s.seq[j];
            if(!st2)continue;
            if(isMediaStep(st2)){s._liveFellOpen=true;return j;}
        }
        return -1;
    }

    // Whether a queued item can answer a control that only accepts one media kind.
    function pickMatchesAccept(st,acceptKind){
        if(!st||!acceptKind||acceptKind==='both')return true;
        if(acceptKind==='image')return st.kind==='photo';
        if(acceptKind==='video')return st.kind==='video';
        return true;
    }

    // Picker-surface step search. In eyedeekit mode (s._edk, default off) the
    // native document picker serves PHOTO steps only, so the front selfie video
    // stays reserved for the live camera. Otherwise identical to firstMediaFrom,
    // so normal browsing behavior is byte-for-byte unchanged.
    function firstPickFrom(idx,acceptKind){
        var s=gs();
        if(!s.seq)return -1;
        // eyedeekit mode: the native document picker serves PHOTO steps only, so
        // the front selfie video stays reserved for the live camera.
        if(s._edk){
            for(var j=Math.max(0,idx);j<s.seq.length;j++){var pt=s.seq[j];if(pt&&pt.kind==='photo'&&!pt.empty&&stepAnswers(pt,'native')&&pickMatchesAccept(pt,acceptKind))return j;}
            return -1;
        }
        for(var i=Math.max(0,idx);i<s.seq.length;i++){if(isMediaStep(s.seq[i])&&stepAnswers(s.seq[i],'native')&&pickMatchesAccept(s.seq[i],acceptKind))return i;}
        return -1;
    }

    // ---- Picker surface: ALWAYS faked while a sequence is active ----
    // The native file/photo/camera upload picker never opens the real iPhone
    // camera during an active sequence. It serves the current media step — or
    // the next media step in the list, skipping block / WebRTC-block steps — as
    // a fresh capture. Only when the list holds no media at all does the real
    // picker open. This is independent of each step's live-camera switch AND of
    // the live camera's own pointer(s) — the picker keeps its own cycle
    // position (_pkPtr) entirely separate, and always advances past whatever it
    // just served (including on wraparound), so repeated taps keep cycling
    // through the whole list instead of freezing on the first item once the
    // pointer reaches the end.
    // Resolve the next picker candidate without mutating cursor state. A native
    // hand-off is only committed after WebKit's real `files` getter confirms
    // the file landed in the target control.
    function pickerResolve(acceptKind){
        var s=gs();
        if(!s.a||!s.seq||!s.seq.length)return{a:'nativePicker'};
        var savedPick=s._askPick?{id:s._askPick.id,at:s._askPick.at}:null;
        // Honor a one-shot "serve this exact item" choice from the ask-me prompt.
        var picked=fslTakePick();
        if(picked&&pickMatchesAccept(picked,acceptKind)){
            return{a:'serve',step:picked,nextPtr:s._pkPtr||0,restorePick:savedPick};
        }
        // A selected item for the wrong input type is not consumed by this request.
        if(savedPick&&picked!==null)s._askPick=savedPick;
        var ptr=s._pkPtr||0;
        var idx=firstPickFrom(ptr,acceptKind);
        if(idx<0)idx=firstPickFrom(0,acceptKind);   // wrap when nothing remains ahead
        if(idx<0){                                 // nothing servable for this control
            if(isMediaStep(s._heldNative)&&stepAnswers(s._heldNative,'native')&&pickMatchesAccept(s._heldNative,acceptKind)){
                return{a:'serve',step:s._heldNative,nextPtr:s._pkPtr||0};
            }
            return{a:'nativePicker'};
        }
        return{a:'serve',step:s.seq[idx],nextPtr:idx+1};
    }

    function fslCommitPickerResult(result){
        var s=gs();
        if(!s||!result||result.a!=='serve'||!result.step)return;
        s._held=result.step;
        s._heldNative=result.step;
        if(typeof result.nextPtr==='number')s._pkPtr=result.nextPtr;
        reportSeq('serve',result.step.id,'native');
    }

    function fslRollbackPickerResult(result){
        var s=gs();
        if(!s||!result||!result.restorePick)return;
        s._askPick={id:result.restorePick.id,at:result.restorePick.at};
    }

    // Guard picker commit against sequence replacement during the async
    // capture hand-off (1.5–3.4s window while the fake camera screen shows).
    // Without this, editing media mid-capture would advance _pkPtr based on
    // the old layout and report a serve for a step that no longer exists.
    function fslDeliverCapture(result){
        var s=gs();
        if(!s||!result||result.a!=='serve'||!result.step)return;
        var seqV=s._seqV;
        return function(){
            var st=gs();
            if(!st||st._seqV!==seqV){
                try{fslTrace('sequence-replaced-during-capture','seqV='+seqV+' current='+((st&&st._seqV)||0));}catch(e){}
                return false;
            }
            if(s._seqV===seqV){
                s._held=result.step;
                s._heldNative=result.step;
                if(typeof result.nextPtr==='number')s._pkPtr=result.nextPtr;
                reportSeq('serve',result.step.id,'native');
                return true;
            }
            return false;
        };
    }

    // Hard gate (live/WebRTC surface only): when media is active and the method
    // is not passthrough, the real camera is never allowed. Block or hold instead.
    function endRes(facing,depth){
        var s=gs();
        var e=s.end||'hold';
        var isInjecting=s.a&&s._method!=='passthrough'&&s.seq&&s.seq.length;
        if(e==='refuse')return{a:'blockWebRTC'};
        if(e==='real'){
            // HARD GATE: never leak real camera when injecting
            if(isInjecting)return{a:'blockWebRTC'};
            return{a:'real'};
        }
        if(e==='loop'){
            if(depth>0){
                if(isInjecting)return{a:'blockWebRTC'};
                return{a:'real'};
            }
            s.pHead=0;
            return fslResolve(facing,depth+1);
        }
        // HOLD replay. Prefer the item the live surface itself last served, but
        // fall back to the last item served on ANY surface: refusing a request
        // that a held item could answer is strictly worse than replaying it.
        if(s._heldLive)return{a:'serve',step:s._heldLive};
        if(isMediaStep(s._held)){s._liveFellOpen=true;return{a:'serve',step:s._held};}
        // Nothing served yet on this page: hold on the first servable item rather
        // than refusing outright, which is what left first requests dead.
        var fi=firstMediaFrom(0);
        if(fi>=0){var fs=s.seq[fi];s._held=fs;s._heldLive=fs;return{a:'serve',step:fs};}
        // HOLD: if injecting, keep blocking; otherwise fall through
        if(isInjecting)return{a:'blockWebRTC'};
        return{a:'real'};
    }

    // Live/WebRTC surface consumer.
    function consume(step,adv,stay){
        if(step.kind==='webrtcBlock'){adv();return{a:'blockWebRTC'};}
        if(step.kind==='block'){
            if(step.block==='here'){if(stay)stay();return{a:'blockWebRTC'};}
            adv();return{a:'blockWebRTC'};
        }
        if(step.empty){adv();return{a:'real'};}
        // Per-step live-camera switch: when this media step blocks the live
        // camera, deny the in-page request without advancing. The picker can
        // still hand this exact photo over as a fresh capture.
        if(step.live==='block')return{a:'blockWebRTC'};
        var s=gs();s._held=step;s._heldLive=step;adv();return{a:'serve',step:step};
    }

    function fslResolve(facing,depth){
        var s=gs();
        if(!s.seq||!s.seq.length)return{a:'real'};
        // Honor a one-shot "serve this exact item" choice from the ask-me prompt.
        if(depth===0){
            var picked=fslTakePick();
            if(picked){s._held=picked;s._heldLive=picked;return{a:'serve',step:picked};}
        }
        var mode=s.mode||'advance';

        if(mode==='holdCurrent'){
            var ci=firstLiveIndexFrom(s.pHead||0);
            if(ci<0)ci=firstLiveIndexFrom(0);
            // Hold-current ALWAYS yields something: clamp to the last item the way
            // this mode originally did, instead of falling through to a refusal.
            if(ci<0&&s.seq.length){
                ci=Math.min(Math.max(0,s.pHead||0),s.seq.length-1);
                s._liveFellOpen=true;
            }
            if(ci<0)return endRes(facing,depth);
            var cs=s.seq[ci];
            return consume(cs,function(){},function(){});
        }

        var hi=firstLiveIndexFrom(s.pHead||0);
        // Wrap before giving up, so a pointer parked past the end never refuses a
        // request that the list can still answer.
        if(hi<0)hi=firstLiveIndexFrom(0);
        if(hi<0)return endRes(facing,depth);
        var hs=s.seq[hi];
        return consume(hs,function(){s.pHead=hi+1;},function(){s.pHead=hi;});
    }

    // Probe mode is ALWAYS time-boxed AND confined to the app's own test page.
    // On a page the user is actually browsing it can never engage, so an
    // interrupted diagnostic can never silence reporting or strip the real
    // capture behaviour from live browsing.
    function fslProbing(){
        try{
            var s=gs();
            if(!s||!s._probeMode)return false;
            if(!s._isHarness){s._probeMode=false;s._probeUntil=0;return false;}
            if(!s._probeUntil||Date.now()>s._probeUntil){s._probeMode=false;s._probeUntil=0;return false;}
            return true;
        }catch(e){return false;}
    }

    // Every request owns an immutable session + sequence-version context. Live
    // and native/file surfaces are independently serialized so an upload cannot
    // mute or starve an already-running live feed, while duplicate requests on
    // the same surface cannot race the queue cursor.
    function fslRequestSlot(surface){return surface==='native'?'_activeNativeRequest':'_activeLiveRequest';}
    function fslActiveRequest(surface){var s=gs();return s?s[fslRequestSlot(surface||'live')]:null;}
    function fslRequestCurrent(req){
        var s=gs();
        if(!s||!req||req.done)return false;
        return req.session===s._session&&req.sequenceVersion===s._seqV;
    }
    function fslStartRequest(surface,facing){
        var s=gs();if(!s)return null;
        var slot=fslRequestSlot(surface);
        // If an existing request still occupies the slot, force-complete it
        // so a stalled prior request cannot block the new one.
        var existing=s[slot];
        if(existing&&!existing.done){
            if(existing.connected){
                fslLifecycle('requestCompleted',existing,'force-completed-no-frame','A new request superseded this connected request before a frame was confirmed.',existing.surface);
            }
            fslEndRequest(existing,'requestCancelled','existing.connected','The prior request was cancelled because a new request arrived on the same surface.');
        }
        s._requestSerial=(s._requestSerial||0)+1;
        var req={id:'req_'+Date.now()+'_'+s._requestSerial,surface:surface||'live',facing:facing||'',session:s._session||'unsynced',sequenceVersion:s._seqV||0,startedAt:performance.now(),connected:false,frameSeen:false,done:false};
        s[slot]=req;
        fslLifecycle('requestSeen',req,'','The page request is bound to its current navigation session.',req.surface);
        // Watchdog: if a request is still not done after 15s, force-cancel it
        // so a permanently stalled native layer doesn't block the page indefinitely.
        req._watchdog = _nT(function(){
            if(req.done)return;
            req.cancelled = true;
            fslEndRequest(req, 'requestCancelled', 'watchdog-timeout', 'The request was cancelled after 15 seconds because no frame was confirmed.');
        }, 15000);
        return req;
    }
    function fslEndRequest(req,phase,reason,detail){
        var s=gs();if(!s||!req||req.done)return;
        req.done=true;
        if(req._watchdog){try{_nCT(req._watchdog);}catch(e){}req._watchdog=null;}
        // C-04: Clear the per-stream binding if it points to this request.
        if(s._streamReq===req)s._streamReq=null;
        fslLifecycle(phase||'requestCompleted',req,reason||'',detail||'',req.surface);
        var slot=fslRequestSlot(req.surface);
        if(s[slot]===req)s[slot]=null;
    }
    function fslConnectRequest(req,reason,detail){
        if(!fslRequestCurrent(req))return false;
        req.connected=true;
        // C-04: Bind this request to the active stream so fslNoteFrame
        // completes the correct request even if a newer request has
        // already overwritten the global live slot by the time the
        // first frame from THIS feed arrives.
        var s=gs();
        if(s&&req.surface==='live')s._streamReq=req;
        fslLifecycle('mediaConnected',req,reason||'',detail||'',req.surface);
        if(req.surface==='live'&&req.frameSeen){
            fslLifecycle('framesFlowing',req,'first-frame','The first rendered frame reached the virtual stream.','live');
            fslEndRequest(req,'requestCompleted','frame-delivered','The live stream was delivered after a confirmed frame.');
        }
        return true;
    }
    function fslNoteFrame(){
        var s=gs();
        if(!s)return;
        // C-04: Use the per-stream bound request instead of the global active
        // request slot. A frame from feed A must complete feed A's request,
        // not whatever request happens to occupy the live slot when the frame
        // arrives. Fall back to the global slot only if no stream is bound
        // (covers the pre-connect VTG/private-lane verification calls).
        var req=s._streamReq||fslActiveRequest('live');
        if(!req||req.done||!fslRequestCurrent(req)||req.frameSeen)return;
        req.frameSeen=true;
        req.frameAt=performance.now();
        if(req.connected){
            fslLifecycle('framesFlowing',req,'first-frame','The first rendered frame reached the virtual stream.','live');
            fslEndRequest(req,'requestCompleted','frame-delivered','The live stream was delivered after a confirmed frame.');
        }
    }
    function fslCancelRequests(reason){
        var live=fslActiveRequest('live'),native=fslActiveRequest('native');
        if(live)fslEndRequest(live,'requestCancelled',reason||'cancelled','The document lifecycle cancelled this pending request.');
        if(native)fslEndRequest(native,'requestCancelled',reason||'cancelled','The document lifecycle cancelled this pending request.');
        // C-04: Clear the per-stream binding on cancellation so a stale
        // frame from a retired feed cannot complete a cancelled request.
        var s=gs();if(s)s._streamReq=null;
    }
    _s._cancelRequests=fslCancelRequests;

    // Lifecycle messages are ephemeral UI telemetry. Failure recording remains
    // opt-in, while every active screen still receives clear progress or failure.
    function fslLifecycle(phase,req,reason,detail,surface){
        try{
            var s=gs();if(!s)return;
            if(fslProbing())return;
            var active=req||fslActiveRequest(surface||'live');
            var frames=s._ft||[],offset=frames.length?frames[frames.length-1]:null;
            var message={action:'lifecycle',phase:String(phase||''),requestId:(active&&active.id)||'',session:s._session||'',sequenceVersion:s._seqV||0,surface:String(surface||(active&&active.surface)||'live'),reason:String(reason||''),detail:String(detail||''),frameOffsetMs:offset,method:s._method||'',feed:s._activeFeed||'',lane:s._feedLane||'',timestampMs:Date.now()};
            if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.fslSeq){
                window.webkit.messageHandlers.fslSeq.postMessage(message);
            }
            fslTrace(message.phase,message.reason,message.detail,message.surface);
        }catch(e){}
    }
    _s._lifecycle=fslLifecycle;

    // Failure recorder. Silent unless the user switched it on. Reports only the
    // stage, a short reason and technical context — never media content.
    function fslTrace(stage,reason,detail,surface){
        try{
            var s=gs();
            if(!s||!s._traceOn||s._isHarness)return;
            var active=fslActiveRequest(surface||'live'),frames=s._ft||[];
            if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.fslTrace){
                window.webkit.messageHandlers.fslTrace.postMessage({
                    stage:String(stage||''),
                    reason:String(reason||''),
                    detail:String(detail||''),
                    surface:String(surface||'live'),
                    method:s._method||'',
                    host:(location&&location.host)?location.host:'',
                    session:s._session||'',
                    requestId:(active&&active.id)||'',
                    sequenceVersion:s._seqV||0,
                    frameOffsetMs:frames.length?frames[frames.length-1]:null,
                    timestampMs:Date.now()
                });
            }
        }catch(e){}
    }
    _s._trace=fslTrace;

    function reportSeq(action,id,surface){
        try{
            var s=gs();
            if(!s)return;
            // A diagnostics probe must not disturb the visible sequence state.
            if(fslProbing())return;
            var active=fslActiveRequest(surface||'live');
            if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.fslSeq){
                window.webkit.messageHandlers.fslSeq.postMessage({action:action,id:id||'',ptr:s.pHead,pickerPtr:s._pkPtr,surface:surface||'live',method:s._method||'canvasPipeline',feed:s._activeFeed||'',lane:s._feedLane||'',downgraded:!!s._feedDowngraded,reason:s._feedReason||'',engine:s._feedEngine||'',session:s._session||'',requestId:(active&&active.id)||'',sequenceVersion:s._seqV||0});
            }
        }catch(e){}
    }

    function payloadFor(step){
        var s=gs();
        return (s.payloads&&step&&step.id&&s.payloads[step.id])||step||{};
    }

    function buildDrawFromStep(step,facing){
        var s=gs();
        if(step.vid){
            // Video steps try MOTION first — a liveness check flags a frozen
            // still frame. Only if the video can't load (CSP blocks the blob,
            // decode error, etc.) do we fall back to the poster first-frame.
            return makeVideoDraw(facing,step.vid).catch(function(){
                var p=payloadFor(step);
                var fb64=p.fb64||'',fmime=p.fmime||'';
                if(fb64&&fmime){
                    s._servedAsStill=true;
                    try{fslTrace('poster-fallback','video-failed-using-first-frame','Video load failed; serving the prepared poster still.','live');}catch(e){}
                    return makeImageDrawFromBytes(facing,fb64,fmime);
                }
                return Promise.reject(new DOMException('Could not start video source','NotReadableError'));
            });
        }
        if(step.img)return makeImageDraw(facing,step.img);
        return Promise.reject(new DOMException('Could not start video source','NotFoundError'));
    }

    // ---- Canvas Pipeline: captureStream from canvas (original method) ----
    function getVirtStreamForStep(step,facing){
        var s=gs();
        s._lastFacing=facing;
        s._activeFeed='canvas';
        s._feedLane=null;
        s._feedEngine='';
        stopVTG();
        initCanvas(facing);
        return buildDrawFromStep(step,facing).then(function(active){
            if(s._ve&&(!active||active.el!==s._ve)){
                disposePrevVideoEl();
            }
            s._ve=(active.type==='video')?active.el:null;
            disposeActive();
            s._active=active;
            if(s._st){try{s._st.getTracks().forEach(function(t){t.stop();});}catch(e){}}
            var isBack=(facing==='environment');
            var p=isBack?(s.bp||s.fp||{}):(s.fp||{});
            var fps=p.frameRate||30;
            // Guard captureStream: if it's missing or blocked by the page,
            // reject with a NotReadableError (matching Safari's real camera
            // failure) instead of letting a raw TypeError escape.
            try{
                s._st=s._c.captureStream(canvasManual()?0:fps);
            }catch(capErr){
                fslTrace('captureStream','blocked',((capErr&&capErr.message)||''),'live');
                disposeActive();
                s._active=null;
                return Promise.reject(new DOMException('Could not start video source','NotReadableError'));
            }
            s._reqFrame=null;
            if(canvasManual()){var _vt=s._st.getVideoTracks()[0];if(_vt&&_vt.requestFrame)s._reqFrame=function(){try{_vt.requestFrame();}catch(e){}};}
            s._stFacing=facing;
            s._pubFps=fps;
            startPace();
            primeStream();
            return patchTrack(s._st,facing);
        });
    }

    // ---- Private Lane: clean feed built INSIDE the app-only isolated world ----
    // The dedicated Private Lane method does NOT run the worker on the page,
    // where a strict site's CSP can block it. Instead it asks the lane server
    // (installed at document-start in a separate WebKit content world the page's
    // security policy can't police) to build the clean VideoTrackGenerator feed
    // there and park it on its own hidden <video>. We read that element's
    // srcObject back on the page — the underlying MediaStream is shared across
    // worlds through the DOM — verify real frames arrive, then hand it to the
    // site. Any failure rejects so serveStep falls back to the in-page clean feed
    // and finally Canvas: never a dead camera, never a false "private" tag.
    //
    // The bridge element carries small JSON-array queues (data-q for requests,
    // data-a for responses, data-c for cancels) instead of single overwritten
    // values, and every request gets its OWN output <video> id derived from its
    // token. That way two overlapping checks (e.g. a front-camera check
    // immediately followed by a back-camera one) are each tracked and answered
    // independently — neither can clobber the other's queued request/response or
    // strand/cancel the other's in-flight build.
    function laneAppend(el,attr,entry){
        var arr=null;
        try{var raw=el.getAttribute(attr);if(raw)arr=JSON.parse(raw);}catch(e){arr=null;}
        if(!Array.isArray(arr))arr=[];
        arr.push(entry);
        if(arr.length>16)arr=arr.slice(arr.length-16);
        try{el.setAttribute(attr,JSON.stringify(arr));}catch(e){}
    }
    function getVirtStreamPrivateLane(step,facing){
        return new Promise(function(resolve,reject){
            var s=gs();
            if(typeof MutationObserver==='undefined'||typeof MediaStream==='undefined'){reject(new Error('lane-unsupported'));return;}
            var p=payloadFor(step);
            var vidUrl=p.vid||step.vid||'';
            var imgUrl=p.img||step.img||'';
            if(!vidUrl&&!imgUrl){reject(new Error('no-media'));return;}
            var isBack=(facing==='environment');
            var prof=isBack?(s.bp||s.fp||{}):(s.fp||{});
            var fps=prof.frameRate||30,W=prof.width||1280,H=prof.height||720;
            var BID='__fslLB';
            var token='q'+Date.now()+'_'+Math.floor(Math.random()*1000000);
            var VID='__fslLV_'+token;
            var settled=false,to=null,mo=null,b=null;
            function cleanup(){if(to){clearTimeout(to);to=null;}if(mo){try{mo.disconnect();}catch(e){}mo=null;}}
            // A lane build that hasn't answered yet when we give up (timeout, or the
            // page itself errors posting the request) is still running its worker +
            // pump loop in the private lane. Tell the lane to abort that exact token
            // so a late success doesn't leak a worker/video forever with nothing on
            // the page ever watching it — the lane retires it if still in flight, and
            // is a no-op if it already finished or never started. Every check carries
            // its own token end-to-end, so an overlapping check for the other camera
            // side can never strand or cancel this one.
            function fail(msg){if(settled)return;settled=true;cleanup();try{if(b)laneAppend(b,'data-c',{token:token});}catch(e){}reject(new Error(msg||'lane-fail'));}
            function adopt(){
                if(settled)return;settled=true;cleanup();
                var v=document.getElementById(VID);
                var stream=null;try{stream=v?v.srcObject:null;}catch(e){}
                if(!stream||!stream.getVideoTracks||stream.getVideoTracks().length===0){reject(new Error('lane-no-stream'));return;}
                var s2=gs();
                // The lane owns this feed now; retire any in-page worker/pace loop.
                stopVTG();
                s2._pacing=false;if(s2._paceT){clearTimeout(s2._paceT);s2._paceT=null;}
                s2._reqFrame=null;
                if(s2._st&&s2._st!==stream){try{s2._st.getTracks().forEach(function(t){t.stop();});}catch(e){}}
                s2._st=stream;s2._stFacing=facing;s2._lastFacing=facing;s2._pubFps=fps;
                s2._activeFeed='vtg';s2._feedLane='private';s2._feedDowngraded=false;s2._feedReason='';s2._feedEngine='element';
                // The lane assembles frames on its own canvas, so grain is applied
                // there (in the isolated world) whenever the toggle is on.
                s2._srCanvasFeed=true;
                disposeActive();
                s2._active={type:'image',el:v,draw:function(){}};
                // Prove real frames cross the world boundary before handing it to
                // the site; a lane that opened but delivers black still rejects
                // (and stops its stream) so serveStep falls back rather than
                // serving a frozen feed. Once published, track-end recovery must
                // create and bind a replacement instead of trying to reject an
                // already-settled Promise.
                var lanePublished=false,laneRecovering=false;
                var recoverLaneTrack=function(){
                    if(!lanePublished||laneRecovering)return;
                    var s3=gs();if(!s3||!s3.a||s3._st!==stream)return;
                    laneRecovering=true;
                    fslTrace('privateLane','track-ended','The private-lane track ended after publication; rebuilding an in-page fallback.','live');
                    getVirtStreamVTGRetry(step,facing,'rawFramePipe').then(function(fallbackStream){
                        var s4=gs();
                        s4._feedDowngraded=true;s4._feedReason='lane-runtime-ended';s4._feedLane=null;
                        var rebound=fslRebindPublishedStream(stream,fallbackStream);
                        fslTrace('privateLane','track-recovered','Rebound '+rebound+' published media element(s) after a private-lane track end.','live');
                        reportSeq('serve',step.id,'live');
                        laneRecovering=false;
                    },function(rawError){
                        getVirtStreamForStep(step,facing).then(function(canvasStream){
                            var s4=gs();
                            s4._feedDowngraded=true;s4._feedReason='lane-runtime-ended';s4._feedLane=null;
                            var rebound=fslRebindPublishedStream(stream,canvasStream);
                            fslTrace('privateLane','canvas-recovered','Rebound '+rebound+' published media element(s) after a private-lane track end.','live');
                            reportSeq('serve',step.id,'live');
                            laneRecovering=false;
                        },function(canvasError){
                            var s4=gs();if(s4._st===stream){try{s4._st.getTracks().forEach(function(t){t.stop();});}catch(e){}s4._st=null;s4._stFacing=null;}
                            if(s4._activeFeed==='vtg')s4._activeFeed=null;
                            laneRecovering=false;
                            fslTrace('privateLane','recovery-failed',((canvasError&&canvasError.message)||(rawError&&rawError.message)||''),'live');
                        });
                    });
                };
                var laneTrack=stream.getVideoTracks()[0];
                if(laneTrack){try{laneTrack.addEventListener('ended',recoverLaneTrack,{once:true});}catch(e){laneTrack.onended=recoverLaneTrack;}}
                verifyVTGDelivery(stream).then(function(){
                    lanePublished=true;
                    // The private lane stops the page-side pace loop, so fslTick /
                    // fslNoteFrame never fire on their own. Manually mark the frame
                    // as seen so the request lifecycle completes instead of staying
                    // stuck in _activeLiveRequest with done=false, which would
                    // block every subsequent getUserMedia call via the reentrant
                    // guard.
                    try{fslNoteFrame();}catch(e){}
                    resolve(patchTrack(stream,facing));
                },function(){
                    try{stream.getTracks().forEach(function(t){t.stop();});}catch(e){}
                    var s3=gs();if(s3._st===stream){s3._st=null;s3._stFacing=null;}
                    s3._feedLane=null;if(s3._activeFeed==='vtg')s3._activeFeed=null;
                    reject(new Error('lane-verify'));
                });
            }
            function check(){
                if(settled||!b)return;
                var raw=null;try{raw=b.getAttribute('data-a');}catch(e){}
                if(!raw)return;
                var arr=null;try{arr=JSON.parse(raw);}catch(e){return;}
                if(!arr||!arr.length)return;
                for(var i=arr.length-1;i>=0;i--){
                    var a=arr[i];
                    if(a&&a.token===token){if(a.ok)adopt();else fail('lane:'+(a.reason||'refused'));return;}
                }
            }
            // Create the shared bridge element (the page side owns it) so the
            // lane server — which only reacts to requests — has something to read.
            try{
                b=document.getElementById(BID);
                if(!b){b=document.createElement('div');b.id=BID;b.setAttribute('aria-hidden','true');b.style.cssText='position:absolute;left:-9999px;top:-9999px;width:0;height:0;overflow:hidden;opacity:0;pointer-events:none';(document.documentElement||document.body||document).appendChild(b);}
            }catch(e){reject(new Error('lane-absent'));return;}
            if(!b){reject(new Error('lane-absent'));return;}
            try{mo=new MutationObserver(function(){check();});mo.observe(b,{attributes:true,attributeFilter:['data-a']});}catch(e){}
            to=setTimeout(function(){fail('lane-timeout');},4500);
            try{laneAppend(b,'data-q',{token:token,facing:facing,vid:vidUrl,img:imgUrl,w:W,h:H,fps:fps,seed:(prof.seed||0),realism:(s._sensorRealism!==false)?1:0});}catch(e){fail('lane-post');return;}
            check();
        });
    }

    function shouldCacheLaneFailure(err){
        var m=(err&&err.message)?String(err.message):String(err||'');
        // Media-specific misses can change when the next step/media changes; lane
        // availability failures are page/device-policy facts, so remember those
        // for this page and skip the expensive 4.5s lane attempt next request.
        return !/no-media|video-fetch|video-load|img-fetch|img-load|media-load/i.test(m);
    }
    function markLaneBad(err){
        var s=gs();
        s._laneBad=true;
        s._laneBadReason=(err&&err.message)?String(err.message):'lane-failed';
    }
    // Gives the private lane one deliberate retry after a short beat — the same
    // second chance the other clean-feed methods already get — so a single
    // timeout or one-off hiccup doesn't permanently bench a lane that would have
    // worked on the very next attempt. Only benches the lane for the rest of
    // this page visit when BOTH the first attempt AND the retry fail with a
    // real, repeatable failure — never after just one miss.
    function getVirtStreamPrivateLaneRetry(step,facing){
        return getVirtStreamPrivateLane(step,facing).catch(function(){
            return new Promise(function(res){setTimeout(res,180);}).then(function(){
                return getVirtStreamPrivateLane(step,facing);
            }).catch(function(err2){
                if(shouldCacheLaneFailure(err2))markLaneBad(err2);
                throw err2;
            });
        });
    }

    // ---- Single decision point: route to the configured injection method ----
    // serveStep selects Canvas Pipeline, Raw Frame Pipe (VideoTrackGenerator),
    // or Private Lane based on s._method. Every method falls back to Canvas
    // on any failure — the camera is never left dead.
    function serveStep(step,facing){
        var s=gs();
        var method=s._method||'canvasPipeline';
        s._lastFacing=facing;

        // Private lane: clean feed built in the app-only isolated world
        if(method==='privateLane'&&!s._laneBad){
            s._feedIntended='privateLane';
            return getVirtStreamPrivateLaneRetry(step,facing).catch(function(err){
                fslTrace('serveStep','private-lane-failed',((err&&err.message)||''),'live');
                return getVirtStreamVTGRetry(step,facing,'rawFramePipe');
            }).catch(function(err){
                fslTrace('serveStep','private-lane-vtg-failed',((err&&err.message)||''),'live');
                return getVirtStreamForStep(step,facing);
            });
        }

        // Raw frame pipe: worker-backed VideoTrackGenerator
        if(method==='rawFramePipe'){
            s._feedIntended='rawFramePipe';
            return getVirtStreamVTGRetry(step,facing,'rawFramePipe').catch(function(err){
                fslTrace('serveStep','rawFramePipe-failed',((err&&err.message)||''),'live');
                return getVirtStreamForStep(step,facing);
            });
        }

        // Canvas pipeline (default, includes classicCanvas and auto)
        s._feedIntended='canvasPipeline';
        return getVirtStreamForStep(step,facing);
    }

    function refreshActive(){
        var s=gs();
        if(!s.a||!s._st||!s._active)return false;
        // The VTG feed runs its own frame pump (s._vtgT); don't start the canvas
        // pace loop on top of it, which would double-count frame cadence.
        if(s._activeFeed==='vtg')return true;
        startPace();
        return true;
    }
    _s._refresh=refreshActive;

    // ---- Manual sequence advancement (called from Swift toolbar button) ----
    // A returned MediaStream is held by the page, so changing the sequence cannot
    // merely replace s._st: the page's current media element would retain the old
    // (now stopped) stream. Remember virtual-stream consumers and atomically
    // rebind them after a successful replacement. The small WeakMap also repairs
    // a late `video.srcObject = oldStream` assignment made after the switch.
    function fslIsVirtualStream(stream){
        try{
            var tracks=stream&&stream.getVideoTracks?stream.getVideoTracks():[];
            for(var i=0;i<tracks.length;i++){if(tinfo(tracks[i]))return true;}
        }catch(e){}
        return false;
    }
    function fslRememberStreamTarget(el,stream){
        var s=gs();if(!s||!el||!stream)return;
        var list=s._streamTargets||(s._streamTargets=[]);
        for(var i=0;i<list.length;i++){if(list[i]===el)return;}
        list.push(el);
        if(list.length>32)list.splice(0,list.length-32);
    }
    function fslRebindPublishedStream(oldStream,newStream){
        var s=gs();if(!s||!oldStream||!newStream)return 0;
        if(typeof WeakMap!=='undefined'){
            try{if(!s._streamReplacements)s._streamReplacements=new WeakMap();s._streamReplacements.set(oldStream,newStream);}catch(e){}
        }
        var list=(s._streamTargets||[]).slice(0);
        try{
            var fallback=document.querySelectorAll('video,audio');
            for(var i=0;i<fallback.length;i++){if(list.indexOf(fallback[i])<0)list.push(fallback[i]);}
        }catch(e){}
        var rebound=0;
        for(var j=0;j<list.length;j++){
            var el=list[j];
            try{
                if(el&&el.srcObject===oldStream){
                    el.srcObject=newStream;
                    fslRememberStreamTarget(el,newStream);
                    try{var play=el.play&&el.play();if(play&&play.catch)play.catch(function(){});}catch(e){}
                    rebound++;
                }
            }catch(e){}
        }
        return rebound;
    }
    // Sets the live pointer directly WITHOUT resetting the sequence version or
    // payloads. Active replacements are serialized so two quick toolbar taps
    // cannot build overlapping feeds; progress is published only after the new
    // stream is ready and rebound.
    _s._setPointer=function(ptr, newSeqV){
        var s=gs();
        if(!s||!s.seq||ptr<0||ptr>=s.seq.length)return Promise.reject(new Error('bad-pointer'));
        if(s._pointerSwitching)return Promise.reject(new Error('pointer-switch-in-progress'));
        if(newSeqV !== undefined) s._seqV = newSeqV;
        var step=s.seq[ptr];
        if(!step)return Promise.reject(new Error('bad-step'));
        // Capture the sequence version so a sequence replacement during the
        // async serveStep build can never commit a stale step into the new
        // sequence — the cursor would point at an entirely different item.
        var seqV=s._seqV;
        var finish=function(stream){
            if(s._seqV!==seqV)return null;
            s.pHead=ptr;
            reportSeq('manualAdvance',step.id,'live');
            return stream;
        };
        // If no live feed is active, the next request will consume this pointer.
        if(!s.a||!s._st)return Promise.resolve(finish(null));
        var oldStream=s._st;
        var facing=s._stFacing||s._lastFacing||'user';
        s._pointerSwitching=true;
        return serveStep(step,facing).then(function(stream){
            // A sequence replacement (fslApplyRuntimeState with a new
            // sequenceVersion) may have run while serveStep was async. If so,
            // stop the stale stream and bail without touching the new state.
            if(s._seqV!==seqV){
                s._pointerSwitching=false;
                try{stream.getTracks().forEach(function(t){t.stop();});}catch(e){}
                fslTrace('setPointer','sequence-replaced-during-switch','The sequence was replaced while the new feed was being built.','live');
                return null;
            }
            s._st=stream;s._stFacing=facing;s._lastFacing=facing;
            var rebound=fslRebindPublishedStream(oldStream,stream);
            if(rebound===0)fslTrace('setPointer','no-bound-media-element','The new stream is ready; a page video element will adopt it on its next srcObject assignment.','live');
            s._pointerSwitching=false;
            return finish(stream);
        },function(err){
            s._pointerSwitching=false;
            fslTrace('setPointer','serve-failed',((err&&err.message)||''),'live');
            throw err;
        });
    };
    window.fslSetPointer=function(ptr, newSeqV){
        var s=gs();
        if(!s||!s._setPointer)return Promise.reject(new Error('not-ready'));
        return s._setPointer(ptr, newSeqV);
    };

    function addSilentAudio(stream){
        try{
            var s=gs();
            if(!s._silentAC){
                var AC=window.AudioContext||window.webkitAudioContext;
                if(!AC)return stream;
                s._silentAC=new AC();
                s._silentGain=s._silentAC.createGain();
                s._silentGain.gain.value=0;
                var osc=s._silentAC.createOscillator();
                osc.connect(s._silentGain);
                osc.start();
            }
            if(s._silentAC.state==='suspended'){try{s._silentAC.resume();}catch(e){}}
            var dest=s._silentAC.createMediaStreamDestination();
            s._silentGain.connect(dest);
            stream.addTrack(dest.stream.getAudioTracks()[0]);
            patchAudioTrack(stream);
        }catch(e){}
        return stream;
    }

    // ---- Device enumeration ----
    // Real MediaDeviceInfo exposes deviceId/kind/label/groupId as inherited
    // prototype accessors and has an EMPTY own-property set. The old builder
    // defined them as own enumerable values plus an own toJSON, so
    // Object.getOwnPropertyNames(syntheticDevice) was non-empty unlike a real
    // device — a detectable tell. We now back synthetic devices with a WeakMap
    // and serve the values through masked prototype getters, so a synthetic
    // device carries zero own properties and is shaped exactly like a real one.
    // Real devices simply fall through to the genuine native getter.
    var _devStore=(typeof WeakMap!=='undefined')?new WeakMap():null;
    function installDeviceInfoProto(){
        var s=gs();
        if(s._diPatched)return true;
        if(!_devStore||typeof MediaDeviceInfo==='undefined')return false;
        var P=MediaDeviceInfo.prototype;
        var names=['deviceId','groupId','kind','label'];
        // Verify every accessor exists BEFORE patching any, so a partial patch
        // can never leave the prototype half-wrapped.
        var descs={};
        for(var i=0;i<names.length;i++){
            var d=Object.getOwnPropertyDescriptor(P,names[i]);
            if(!d||typeof d.get!=='function')return false;
            descs[names[i]]=d;
        }
        try{
            for(var k=0;k<names.length;k++){
                (function(name,d){
                    var orig=d.get;
                    var g=function(){var r=_devStore.get(this);if(r&&Object.prototype.hasOwnProperty.call(r,name))return r[name];return orig.call(this);};
                    Object.defineProperty(P,name,{get:g,set:d.set,enumerable:d.enumerable,configurable:true});
                    maskFn(g,name,true);
                })(names[k],descs[names[k]]);
            }
            try{
                var oJSON=P.toJSON;
                var oEnum=(Object.getOwnPropertyDescriptor(P,'toJSON')||{}).enumerable||false;
                var j=function toJSON(){var r=_devStore.get(this);if(r)return{deviceId:this.deviceId,kind:this.kind,label:this.label,groupId:this.groupId};return (typeof oJSON==='function')?oJSON.call(this):{deviceId:this.deviceId,kind:this.kind,label:this.label,groupId:this.groupId};};
                Object.defineProperty(P,'toJSON',{value:j,writable:true,enumerable:oEnum,configurable:true});
                maskFn(j,'toJSON',false);
            }catch(e){}
            s._diPatched=true;
            return true;
        }catch(e){return false;}
    }
    function makeDeviceInfo(deviceId,groupId,kind,label){
        try{
            if(_devStore&&installDeviceInfoProto()){
                var info=Object.create(MediaDeviceInfo.prototype);
                _devStore.set(info,{deviceId:deviceId,groupId:groupId,kind:kind,label:label});
                return info;
            }
        }catch(e){}
        // Fallback (prototype accessors unavailable on this engine): keep the
        // original shape so enumeration still works.
        var info2=Object.create(MediaDeviceInfo.prototype);
        Object.defineProperties(info2,{
            deviceId:{value:deviceId,writable:false,enumerable:true,configurable:true},
            groupId:{value:groupId,writable:false,enumerable:true,configurable:true},
            kind:{value:kind,writable:false,enumerable:true,configurable:true},
            label:{value:label,writable:false,enumerable:true,configurable:true}
        });
        try{var tj=function toJSON(){return{deviceId:this.deviceId,groupId:this.groupId,kind:this.kind,label:this.label};};Object.defineProperty(info2,'toJSON',{value:tj,writable:true,enumerable:false,configurable:true});maskFn(tj,'toJSON',false);}catch(e){}
        return info2;
    }

    function extractFacing(vidC){
        if(!vidC||typeof vidC!=='object')return null;
        var fm=vidC.facingMode;
        if(!fm)return null;
        if(typeof fm==='string')return fm;
        if(typeof fm==='object'){
            if(fm.exact)return typeof fm.exact==='string'?fm.exact:(Array.isArray(fm.exact)?fm.exact[0]:null);
            if(fm.ideal)return typeof fm.ideal==='string'?fm.ideal:(Array.isArray(fm.ideal)?fm.ideal[0]:null);
        }
        return null;
    }

    function extractDeviceId(vidC){
        if(!vidC||typeof vidC!=='object')return null;
        var did=vidC.deviceId;
        if(!did)return null;
        if(typeof did==='string')return did;
        if(typeof did==='object'){
            if(did.exact)return typeof did.exact==='string'?did.exact:(Array.isArray(did.exact)?did.exact[0]:null);
            if(did.ideal)return typeof did.ideal==='string'?did.ideal:(Array.isArray(did.ideal)?did.ideal[0]:null);
        }
        return null;
    }

    // ---- Interception arming (installed first, each piece isolated) ----
    // Everything that actually takes over the camera lives in this one
    // re-runnable function: the getUserMedia gate, the device-list swap, the
    // legacy callback shim, the srcObject catcher, and the upload-picker swap.
    // It runs the instant the engine loads (called far above, before every
    // clean-feed / private-lane / fingerprint helper) and wraps each piece in
    // its own guard, so one failing piece can never disarm the rest. Idempotent:
    // each piece installs once (tracked in _s._armParts) so the self-heal path
    // can call arm() again to restore only what is missing.
    function arm(){
        var s=gs();if(!s)return;
        if(!s._armParts)s._armParts=Object.create(null);
        var _armErrs=[];

        // Device enumeration: swap real camera/mic entries for stable synthetic ones.
        if(!s._armParts.enumerate){try{
    MediaDevices.prototype.enumerateDevices=function enumerateDevices(){
        var self=this;
        var s=gs();
        if(!s.a)return origEnum.call(self);
        return origEnum.call(self).then(function(devices){
            var fp=s.fp||{};
            var bp=s.bp||{};
            var mp=s.mp||{};
            var frontId=fp.deviceId||'com.apple.avfoundation.avcapturedevice.front';
            var backId=bp.deviceId||'com.apple.avfoundation.avcapturedevice.back';

            if(s.ra){
                var filtered=[];
                for(var i=0;i<devices.length;i++){
                    var dk=devices[i].kind;
                    // Drop real camera + mic entries; we re-add stable synthetic
                    // ones below. Keep everything else (e.g. audiooutput) exactly
                    // as the platform reports it so the shape matches real Safari.
                    if(dk==='videoinput'||dk==='audioinput')continue;
                    filtered.push(devices[i]);
                }
                filtered.push(makeDeviceInfo(frontId,fp.groupId||frontId,'videoinput',fp.label||'Front Camera'));
                // Always present a back camera. When the profile has a real back
                // camera (s.bp with a deviceId), use it. When the device only has
                // one camera (e.g. the simulator), synthesize a stable back camera
                // entry so webcam-test sites that expect two cameras see both.
                if(bp.deviceId){
                    filtered.push(makeDeviceInfo(backId,bp.groupId||backId,'videoinput',bp.label||'Back Camera'));
                }else{
                    filtered.push(makeDeviceInfo(backId,backId,'videoinput',(bp.label||'Back Camera')));
                }
                var micId=mp.deviceId||'default';
                filtered.push(makeDeviceInfo(micId,mp.groupId||micId,'audioinput',mp.label||'Microphone'));
                return filtered;
            }

            var hasFront=false,hasBack=false;
            for(var j=0;j<devices.length;j++){
                if(devices[j].deviceId===frontId)hasFront=true;
                if(devices[j].deviceId===backId)hasBack=true;
            }
            if(!hasFront){
                devices.push(makeDeviceInfo(frontId,fp.groupId||frontId,'videoinput',fp.label||'Front Camera'));
            }
            if(!hasBack){
                if(bp.deviceId){
                    devices.push(makeDeviceInfo(backId,bp.groupId||backId,'videoinput',bp.label||'Back Camera'));
                }else{
                    devices.push(makeDeviceInfo(backId,backId,'videoinput',bp.label||'Back Camera'));
                }
            }
            return devices;
        });
    };

    maskFn(MediaDevices.prototype.enumerateDevices,'enumerateDevices',false);
        s._armParts.enumerate=true;
        }catch(e){_armErrs.push('enumerate:'+((e&&e.message)||e));}}

    function fslAsksFor(kind){
        var s=gs();
        if(!s||!s._askOn||!s._askKinds)return false;
        return s._askKinds.indexOf(kind)>=0;
    }

    function fslSiteRule(){
        var s=gs();
        if(!s||!s._askOn)return '';
        var rule=String(s._askRule||'').toLowerCase();
        return rule==='serve'||rule==='block'||rule==='real'?rule:'';
    }

    function fslAskDecision(kind,meta){ var s=gs(), askTimeout = setTimeout(function(){}, 1);
        return new Promise(function(resolve){
            if(!s)return resolve('serve');
            var pending = { resolved: false, resolve: resolve };
            
            // Add cancellable timeout fallback
            askTimeout = setTimeout(function() {
                // Auto-resolve after 30 seconds if no user response
                if(pending && !pending.resolved) {
                    pending.resolved = true;
                    pending.resolve({ action: 'serve' });
                }
            }, 30000);
            // Store timeout ID for cancellation
            if(pending) pending._askTimeout = askTimeout;
            
            if(!s._asks) s._asks = {};
            var token = Math.random().toString(36).substring(2);
            s._asks[token] = function(act){
                if(pending._askTimeout) clearTimeout(pending._askTimeout);
                if(pending && !pending.resolved) {
                    pending.resolved = true;
                    pending.resolve(act);
                }
            };
            try {
                if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.fslAsk) {
                    window.webkit.messageHandlers.fslAsk.postMessage({kind:kind, token:token, meta:meta||{}});
                } else {
                    s._asks[token]('serve');
                }
            } catch(e){ s._asks[token]('serve'); }
        });
    }

        // ---- SINGLE DECISION POINT: getUserMedia ----
        // The ONLY place the real camera can be served, and THE critical gate —
        // _s._armed tracks this piece specifically. When media is active and the
        // method is not passthrough, the real camera is NEVER reached.
        if(!s._armParts.gum){try{
    MediaDevices.prototype.getUserMedia=function getUserMedia(constraints){
        var self=this;
        var s=gs();
        // A page that asks before the reply bridge has supplied its state is queued
        // until the state is acknowledged, rather than racing into real hardware.
        if(!s._runtimeReady){
            return new Promise(function(resolve, reject){
                s._gumQueue = s._gumQueue || [];
                s._gumQueue.push(function(){
                    getUserMedia.call(self, constraints).then(resolve).catch(reject);
                });
            });
        }
        // Gate 0: injection not active → real camera
        if(!s.a||!s.seq||!s.seq.length){
            return origGUM.call(self,constraints);
        }
        // Gate 1: passthrough method → real camera allowed
        if(s._method==='passthrough'){
            return origGUM.call(self,constraints);
        }
        // Gate 2: no video constraints → real camera for audio-only
        if(!constraints||!constraints.video)return origGUM.call(self,constraints);

        var vidC=constraints.video;
        var fp=s.fp||{};
        var bp=s.bp||{};
        var frontId=fp.deviceId||'com.apple.avfoundation.avcapturedevice.front';
        var backId=bp.deviceId||'com.apple.avfoundation.avcapturedevice.back';
        var requestedFacing='user';

        if(typeof vidC==='object'){
            var reqDid=extractDeviceId(vidC);
            if(reqDid===backId)requestedFacing='environment';
            else if(reqDid===frontId)requestedFacing='user';
            else{
                var facing=extractFacing(vidC);
                if(facing==='environment')requestedFacing='environment';
                else if(facing==='user')requestedFacing='user';
            }
        }
        
        var normConstraints = constraints;
        if(typeof vidC==='object'){
            normConstraints = {};
            for(var k in constraints) normConstraints[k] = constraints[k];
            normConstraints.video = { facingMode: requestedFacing };
        }

        // A per-surface request guard prevents a second rapid call from consuming
        // the same queue slot while the first call is still constructing its feed.
        var request=fslStartRequest('live',requestedFacing);
        if(!request){
            return Promise.reject(new DOMException('A camera request is already being prepared','InvalidStateError'));
        }

        // A remembered "always do this for this site" answer. The app only sends
        // one while Ask Me is switched ON, so with the feature off nothing here
        // can divert or block a request. Both outcomes are reported so the app
        // can say on screen exactly why the request was not served.
        var _lrule=fslSiteRule();
        if(_lrule==='block'){
            fslEndRequest(request,'requestRejected','saved-answer-block','A saved answer blocked this live request.');
            reportSeq('blockWebRTC','');
            return Promise.reject(new DOMException('Permission denied','NotAllowedError'));
        }
        if(_lrule==='real'){
            fslEndRequest(request,'requestCompleted','saved-answer-real-camera','A saved answer selected the real camera path.');
            reportSeq('realCamera','');
            return origGUM.call(self,normConstraints);
        }

        // Ask-me mode (opt-in, default off): pause and let the user decide what
        // this live request receives. 'serve' continues through the normal gate.
        if(!_lrule&&fslAsksFor('liveCamera')){
            var _aw=0,_ah=0,_afps=0;
            try{
                if(typeof vidC==='object'){
                    _aw=_numFrom(vidC.width,0)||0;
                    _ah=_numFrom(vidC.height,0)||0;
                    _afps=_numFrom(vidC.frameRate,0)||0;
                }
            }catch(e){}
            return fslAskDecision('liveCamera',{facing:requestedFacing,w:_aw,h:_ah,fps:_afps}).then(function(act){
                if(!fslRequestCurrent(request)){
                    return Promise.reject(new DOMException('The page navigation changed before this request could be served','AbortError'));
                }
                if(act==='block'){
                    fslEndRequest(request,'requestRejected','asked-and-blocked','You chose to block this live request.');
                    reportSeq('blockWebRTC','');
                    return Promise.reject(new DOMException('Permission denied','NotAllowedError'));
                }
                if(act==='real'){
                    fslEndRequest(request,'requestCompleted','asked-and-real-camera','You chose the real camera path.');
                    reportSeq('realCamera','');
                    return origGUM.call(self,normConstraints);
                }
                return fslGumServe(self,normConstraints,requestedFacing,request);
            });
        }

        return fslGumServe(self,normConstraints,requestedFacing,request);
    };

    // The normal live-camera gate: resolve the queue and deliver, block, or
    // refuse. The request context is verified at every asynchronous boundary.
    function fslGumServe(self,constraints,requestedFacing,request){
        if(!fslRequestCurrent(request)){
            return Promise.reject(new DOMException('The page navigation changed before the camera request could be served','AbortError'));
        }
        var r=fslResolve(requestedFacing,0);

        // HARD GATE: blockWebRTC → never fall to real camera
        if(r.a==='blockWebRTC'){
            fslEndRequest(request,'requestRejected','queue-blocked','The current queue item blocks this live request.');
            reportSeq('blockWebRTC','');
            return Promise.reject(new DOMException('Permission denied','NotAllowedError'));
        }

        // deny: this side's turn simply hasn't come up yet (e.g. the opposite
        // side is due next) — a harmless, expected skip, distinct from an actual
        // block, so it gets its own label for activity/diagnostics.
        if(r.a==='deny'){
            fslEndRequest(request,'requestRejected','queue-denied','The queue has no item for this camera side yet.');
            reportSeq('deny','');
            return Promise.reject(new DOMException('Permission denied','NotAllowedError'));
        }

        // real camera: blocked by hard gate when injecting
        if(r.a==='real'){
            fslEndRequest(request,'requestRejected','no-servable-step','Nothing in the media list could answer this live request.');
            reportSeq('hardBlock','');
            return Promise.reject(new DOMException('Permission denied','NotAllowedError'));
        }

        // serve: deliver virtual stream through chosen method
        if(r.a==='serve'){
            fslLifecycle('queueResolved',request,'selected-step','The queue selected the requested media item.','live');
            var s = gs();
            if(!s._servePromises) s._servePromises = {};
            var pKey = r.step.id + '_' + requestedFacing;
            
            if(!s._servePromises[pKey]){
                fslLifecycle('mediaPrepared',request,'preparing-source','Preparing the selected item for the active feed.','live');
                s._servePromises[pKey] = serveStep(r.step,requestedFacing).then(function(st){
                    s._servePromises[pKey] = null;
                    return st;
                }).catch(function(err){
                    s._servePromises[pKey] = null;
                    throw err;
                });
            }

            return s._servePromises[pKey].then(function(st){
                var clonedSt = typeof st.clone==='function' ? st.clone() : st;
                if(!fslRequestCurrent(request)){
                    try{clonedSt.getTracks().forEach(function(t){t.stop();});}catch(e){}
                    throw new DOMException('The page navigation changed before the feed could connect','AbortError');
                }
                if(constraints&&constraints.audio){
                    return origGUM.call(self, {audio: constraints.audio}).then(function(audioSt){
                        if(audioSt && audioSt.getAudioTracks().length > 0) {
                            clonedSt.addTrack(audioSt.getAudioTracks()[0]);
                        } else {
                            addSilentAudio(clonedSt);
                        }
                        fslLifecycle('feedBuilt',request,'feed-created','The media stream and track were created.','live');
                        fslConnectRequest(request,'stream-attached','The selected stream is attached to this request context.');
                        reportSeq('serve',r.step.id,'live');
                        return clonedSt;
                    }).catch(function(){
                        addSilentAudio(clonedSt);
                        fslLifecycle('feedBuilt',request,'feed-created','The media stream and track were created.','live');
                        fslConnectRequest(request,'stream-attached','The selected stream is attached to this request context.');
                        reportSeq('serve',r.step.id,'live');
                        return clonedSt;
                    });
                }
                fslLifecycle('feedBuilt',request,'feed-created','The media stream and track were created.','live');
                fslConnectRequest(request,'stream-attached','The selected stream is attached to this request context.');
                reportSeq('serve',r.step.id,'live');
                return clonedSt;
            }).catch(function(err){
                if(fslRequestCurrent(request)){
                    fslEndRequest(request,'requestRejected',(err&&err.message)?String(err.message):'feed-failed','No delivery feed could be built for this request.');
                }
                throw err;
            });
        }

        // Fallback (should not reach): block
        fslEndRequest(request,'requestRejected','unresolved','The queue returned no usable action for this request.');
        reportSeq('hardBlock','');
        return Promise.reject(new DOMException('Permission denied','NotAllowedError'));
    }

    maskFn(MediaDevices.prototype.getUserMedia,'getUserMedia',false);
        s._armParts.gum=true;
        }catch(e){_armErrs.push('gum:'+((e&&e.message)||e));}}

        // ---- Legacy callback getUserMedia (navigator.getUserMedia + prefixes) ----
    // Older sites still call the callback-style navigator.getUserMedia (and the
    // webkit/moz aliases). These bypass MediaDevices.prototype.getUserMedia, so
    // without this they would be a path straight to the REAL camera while we
    // inject. We override an alias ONLY when it actually exists — creating one
    // where modern Safari has none would itself be a tell — routing it through
    // the gated promise path above, and masking it (name + native-code string)
    // so it is indistinguishable from the genuine legacy shim.
        if(!s._armParts.legacy){try{
    (function(){
        try{
            ['getUserMedia','webkitGetUserMedia','mozGetUserMedia'].forEach(function(name){
                try{
                    if(typeof navigator[name]!=='function')return; // absent in modern Safari — leave absent
                    var fn=function(constraints,onOK,onErr){
                        try{
                            var p=navigator.mediaDevices.getUserMedia(constraints);
                            if(p&&p.then){p.then(function(st){if(typeof onOK==='function')onOK(st);},function(e){if(typeof onErr==='function')onErr(e);});}
                        }catch(e){if(typeof onErr==='function')onErr(e);else throw e;}
                    };
                    try{Object.defineProperty(fn,'name',{value:name,configurable:true});}catch(e){}
                    var owner=navigator;
                    while(owner&&!Object.getOwnPropertyDescriptor(owner,name))owner=Object.getPrototypeOf(owner);
                    if(!owner)owner=navigator;
                    var prev=Object.getOwnPropertyDescriptor(owner,name)||{};
                    Object.defineProperty(owner,name,{value:fn,writable:('writable' in prev)?prev.writable:true,configurable:true,enumerable:!!prev.enumerable});
                    maskFn(fn,name,false);
                }catch(e){}
            });
        }catch(e){}
    })();
        s._armParts.legacy=true;
        }catch(e){_armErrs.push('legacy:'+((e&&e.message)||e));}}

        // ---- Direct-assignment catcher (srcObject) ----
        // Removed per M-25: Do not override HTMLMediaElement.prototype.srcObject.
        if(!s._armParts.srcObject){
            s._armParts.srcObject=true;
        }

        // ---- File picker interception ----
        // Removed per C-03: Exclude file input interceptors from controlled media bridging.
        if(!s._armParts.picker){try{
        s._armParts.picker=true;
        }catch(e){_armErrs.push('picker:'+((e&&e.message)||e));}}

        // ---- Optional SDK / bridge wrapping (toggle-gated via s._sdkWrap) ----
        // The refresh monitor revisits globals that SDKs add after document-start.
        // Keep each replacement idempotent so a late-bind scan can never stack
        // wrappers or alter a page's normal behavior while the toggle is off.
        function fslSdkAlreadyWrapped(fn){
            var state=gs();
            try{return !!(fn&&state&&state._sdkWrapped&&state._sdkWrapped.has(fn));}catch(e){return false;}
        }
        function fslSdkMarkWrapped(fn){
            var state=gs();
            try{if(fn&&state&&state._sdkWrapped)state._sdkWrapped.add(fn);}catch(e){}
            return fn;
        }
        function fslSdkFileURL(file){
            try{
                var url=URL.createObjectURL(file),state=gs();
                if(url&&state){if(!Array.isArray(state._sdkObjectURLs))state._sdkObjectURLs=[];state._sdkObjectURLs.push(url);}
                return url;
            }catch(e){return '';}
        }
        function fslSdkRevokeObjectURLs(){
            var state=gs(),urls=state&&Array.isArray(state._sdkObjectURLs)?state._sdkObjectURLs.splice(0):[];
            for(var i=0;i<urls.length;i++){try{URL.revokeObjectURL(urls[i]);}catch(e){}}
            if(state){state._lastBestEffortMedia=null;state._lastBestEffortMediaResult=null;}
            return urls.length;
        }
        function fslSdkFileDataURL(file){
            return new Promise(function(resolve,reject){
                try{var reader=new FileReader();reader.onload=function(){resolve(String(reader.result||''));};reader.onerror=function(){reject(new Error('file-read-failed'));};reader.readAsDataURL(file);}catch(e){reject(e);}
            });
        }
        function fslSdkCapacitorResult(file){
            var url=fslSdkFileURL(file);
            if(!url)throw new Error('file-url-unavailable');
            var type=String(file.type||'').toLowerCase();
            var format=type.indexOf('mp4')>=0?'mp4':(type.indexOf('quicktime')>=0||type.indexOf('mov')>=0?'mov':(type.indexOf('png')>=0?'png':(type.indexOf('gif')>=0?'gif':(type.indexOf('webp')>=0?'webp':'jpeg'))));
            return {path:url,webPath:url,format:format,saved:false};
        }
        function fslSdkCordovaResult(file,opts){
            var dt=null;
            try{dt=(navigator.camera&&navigator.camera.DestinationType?navigator.camera.DestinationType.DATA_URL:(window.Camera&&window.Camera.DestinationType?window.Camera.DestinationType.DATA_URL:null));}catch(e){}
            if(opts&&dt!==null&&opts.destinationType===dt)return fslSdkFileDataURL(file).then(function(dataURL){return dataURL.replace(/^data:[^,]*,/,'' );});
            var url=fslSdkFileURL(file);
            return url?Promise.resolve(url):Promise.reject(new Error('file-url-unavailable'));
        }
        function fslSdkMediaFile(file){
            var url=fslSdkFileURL(file);
            if(!url)throw new Error('file-url-unavailable');
            return {name:file.name||'capture',fullPath:url,localURL:url,type:file.type||'',size:Number(file.size||0),lastModifiedDate:new Date(Number(file.lastModified||Date.now())),getFormatData:function(success){if(typeof success==='function')success({codecs:'',bitRate:0,height:0,width:0,duration:0});}};
        }
        function fslSdkFileName(step,mime){
            var raw=String((step&&step.name)||'').trim();if(raw)return raw;
            if(step&&step.kind==='video')return mime.indexOf('quicktime')>=0?'media.mov':'media.mp4';
            if(mime.indexOf('png')>=0)return 'media.png';
            if(mime.indexOf('webp')>=0)return 'media.webp';
            return 'media.jpg';
        }
        function fslSdkServeFile(acceptKind,adapter){
            var state=gs();if(!state||!state.a||!state.seq||!state.seq.length||typeof adapter!=='function')return null;
            var execute=function(){
                var resolved=pickerResolve(acceptKind||'both');
                if(!resolved||resolved.a!=='serve'||!resolved.step)throw new Error('sdk-media-unavailable');
                var step=payloadFor(resolved.step),url=(step&&step.kind==='video'?(step.vid||step.img):(step.img||step.vid))||'';
                var seqV=state._seqV;
                if(!url){fslRollbackPickerResult(resolved);throw new Error('sdk-media-url-missing');}
                return fetch(url,{cache:'no-store'}).then(function(response){
                    if(!response||!response.ok)throw new Error('sdk-media-fetch-'+(response?response.status:'failed'));
                    return response.blob();
                }).then(function(blob){
                    var mime=String(blob.type||((step&&step.kind==='video')?'video/mp4':'image/jpeg'));
                    var name=fslSdkFileName(step,mime),file;
                    try{file=new File([blob],name,{type:mime,lastModified:Date.now()});}
                    catch(e){blob.name=name;blob.lastModified=Date.now();file=blob;}
                    return Promise.resolve(adapter(file));
                }).then(function(value){
                    if(value===undefined||value===null||value==='')throw new Error('sdk-adapter-empty-result');
                    var st=gs();
                    if(!st||st._seqV!==seqV){
                        try{fslTrace('sequence-replaced-during-build','seqV='+seqV+' current='+((st&&st._seqV)||0));}catch(e){}
                        throw new Error('sequence-replaced-during-build');
                    }
                    fslCommitPickerResult(resolved);
                    try{fslTrace('sdkServe',String(acceptKind||'both'),'An SDK adapter received queued media.','native');}catch(e){}
                    return value;
                }).catch(function(error){
                    fslRollbackPickerResult(resolved);
                    try{fslTrace('sdkServeFailed',String(acceptKind||'both'),String((error&&error.message)||error),'native');}catch(e){}
                    throw error;
                });
            };
            var prior=state._sdkQueue||Promise.resolve();
            var operation=prior.then(execute,execute);
            state._sdkQueue=operation.then(function(){},function(){});
            return operation;
        }
        function fslSdkGenericResult(file,label){
            var url=fslSdkFileURL(file);if(!url)throw new Error('file-url-unavailable');
            return {adapter:String(label||'generic'),url:url,path:url,webPath:url,name:file.name||'capture',type:file.type||'',size:Number(file.size||0),lastModified:Number(file.lastModified||Date.now()),validatedResultShape:false};
        }
        function fslSdkBestEffort(label,acceptKind){
            var promise=fslSdkServeFile(acceptKind||'both',function(file){return fslSdkGenericResult(file,label);});
            if(!promise)return null;
            var state=gs();if(state)state._lastBestEffortMedia=promise;
            return promise.then(function(result){
                if(state)state._lastBestEffortMediaResult=result;
                try{window.dispatchEvent(new CustomEvent('fslmediaresult',{detail:result}));}catch(e){}
                return result;
            });
        }
        try{window.__fslMediaAdapters=Object.freeze({request:function(kind,label){return fslSdkBestEffort(label||'generic',kind||'both');},last:function(){var state=gs();return state&&state._lastBestEffortMediaResult||null;},revokeAll:fslSdkRevokeObjectURLs});}catch(e){}
        if(!s._sdkURLCleanup){try{window.addEventListener('pagehide',fslSdkRevokeObjectURLs,{capture:true});s._sdkURLCleanup=true;}catch(e){}}
        function fslSdkLooksLikeCamera(value){
            var raw='';
            try{if(typeof value==='string'){try{value=JSON.parse(value);}catch(e){raw=value;}}if(!raw)raw=JSON.stringify(value||'');}catch(e){raw=String(value||'');}
            raw=String(raw||'').toLowerCase();
            return raw.indexOf('camera')>=0||raw.indexOf('photo')>=0||raw.indexOf('capture')>=0||raw.indexOf('selfie')>=0||raw.indexOf('liveness')>=0||raw.indexOf('document')>=0||raw.indexOf('barcode')>=0||raw.indexOf('scan')>=0||raw.indexOf('ocr')>=0;
        }
        // Host-defined bridges do not share a response schema. Observe them
        // without pretending a File object is a valid bridge response or
        // consuming the sequence before the page reaches a standard media API.
        function fslSdkNoteBridge(kind){
            var state=gs();
            if(!state||!state._sdkWrap||!state.a||!state.seq||!state.seq.length)return false;
            state._sdkWrapLastBridge=String(kind||'bridge');
            try{fslTrace('sdkBridge',state._sdkWrapLastBridge,'A host-defined bridge reported a camera-related command.','native');}catch(e){}
            return true;
        }
        // Wraps vendor SDK launchers, Cordova/Capacitor camera APIs, bridge
        // transports, and custom-scheme navigation so camera commands route
        // through the existing injection paths. Every wrap is conditional on the
        // target actually existing — no phantom globals are ever created.
        if(!s._armParts.sdkWrap){try{
        // Cordova: navigator.camera.getPicture(success,error,opts). Preserve the
        // plugin's output contract: DATA_URL receives base64; URI modes receive a
        // browser-local object URL rather than a File object the plugin never emits.
        if(typeof navigator!=='undefined'&&navigator.camera&&typeof navigator.camera.getPicture==='function'&&!fslSdkAlreadyWrapped(navigator.camera.getPicture)){
            var _origCDVGP=navigator.camera.getPicture;
            var _wrappedCDVGP=function getPicture(success,error,opts){
                var state=gs();
                if(!state||!state._sdkWrap||!state.a||!state.seq||!state.seq.length)return _origCDVGP.apply(navigator.camera,arguments);
                var fp=fslSdkServeFile('both',function(file){return fslSdkCordovaResult(file,opts);});
                if(fp){fp.then(function(value){if(typeof success==='function')success(value);}).catch(function(){if(typeof error==='function')error('capture failed');});return;}
                return _origCDVGP.apply(navigator.camera,arguments);
            };
            navigator.camera.getPicture=fslSdkMarkWrapped(_wrappedCDVGP);
            s._sdkWrap_cordova=true;
        }

        // Cordova Media Capture returns MediaFile-shaped records, not bare Files.
        if(typeof navigator!=='undefined'&&navigator.device&&navigator.device.capture){
            var _cap=navigator.device.capture;
            if(typeof _cap.captureImage==='function'&&!fslSdkAlreadyWrapped(_cap.captureImage)){var _oCI=_cap.captureImage;var _wCI=function(success,error,opts){var state=gs();if(!state||!state._sdkWrap||!state.a||!state.seq||!state.seq.length)return _oCI.apply(_cap,arguments);var fp=fslSdkServeFile('image',fslSdkMediaFile);if(fp){fp.then(function(mediaFile){if(typeof success==='function')success([mediaFile]);}).catch(function(){if(typeof error==='function')error('capture failed');});return;}return _oCI.apply(_cap,arguments);};_cap.captureImage=fslSdkMarkWrapped(_wCI);s._sdkWrap_cordovaCap=true;}
            if(typeof _cap.captureVideo==='function'&&!fslSdkAlreadyWrapped(_cap.captureVideo)){var _oCV=_cap.captureVideo;var _wCV=function(success,error,opts){var state=gs();if(!state||!state._sdkWrap||!state.a||!state.seq||!state.seq.length)return _oCV.apply(_cap,arguments);var fp=fslSdkServeFile('video',fslSdkMediaFile);if(fp){fp.then(function(mediaFile){if(typeof success==='function')success([mediaFile]);}).catch(function(){if(typeof error==='function')error('capture failed');});return;}return _oCV.apply(_cap,arguments);};_cap.captureVideo=fslSdkMarkWrapped(_wCV);s._sdkWrap_cordovaCapVid=true;}
        }

        // Capacitor Camera results expose usable local/web paths. Empty strings
        // break callers that immediately load the returned media.
        if(typeof window!=='undefined'&&window.Capacitor&&window.Capacitor.Plugins&&window.Capacitor.Plugins.Camera){
            var _capCam=window.Capacitor.Plugins.Camera;
            if(typeof _capCam.getPhoto==='function'&&!fslSdkAlreadyWrapped(_capCam.getPhoto)){var _oGP=_capCam.getPhoto;var _wGP=function(opts){var state=gs();if(!state||!state._sdkWrap||!state.a||!state.seq||!state.seq.length)return _oGP.apply(_capCam,arguments);var fp=fslSdkServeFile('both',fslSdkCapacitorResult);if(fp){return fp;}return _oGP.apply(_capCam,arguments);};_capCam.getPhoto=fslSdkMarkWrapped(_wGP);s._sdkWrap_capacitor=true;}
            // Capacitor v5+: Camera.takePhoto and Camera.recordVideo
            if(typeof _capCam.takePhoto==='function'&&!fslSdkAlreadyWrapped(_capCam.takePhoto)){var _oTP=_capCam.takePhoto;var _wTP=function(opts){var state=gs();if(!state||!state._sdkWrap||!state.a||!state.seq||!state.seq.length)return _oTP.apply(_capCam,arguments);var fp=fslSdkServeFile('image',fslSdkCapacitorResult);if(fp){return fp;}return _oTP.apply(_capCam,arguments);};_capCam.takePhoto=fslSdkMarkWrapped(_wTP);s._sdkWrap_capTakePhoto=true;}
            if(typeof _capCam.recordVideo==='function'&&!fslSdkAlreadyWrapped(_capCam.recordVideo)){var _oRV=_capCam.recordVideo;var _wRV=function(opts){var state=gs();if(!state||!state._sdkWrap||!state.a||!state.seq||!state.seq.length)return _oRV.apply(_capCam,arguments);var fp=fslSdkServeFile('video',fslSdkCapacitorResult);if(fp){return fp;}return _oRV.apply(_capCam,arguments);};_capCam.recordVideo=fslSdkMarkWrapped(_wRV);s._sdkWrap_capRecordVideo=true;}
        }

        // Vendor SDK launchers: wrap init/launch to intercept camera setup.
        // Each wrap only runs if the global is already present on the page.
        function fslWrapVendorLaunch(globalName,methodPath){
            try{
                var obj=window[globalName];if(!obj)return;
                var parts=methodPath.split('.');var cur=obj;
                for(var i=0;i<parts.length-1;i++){cur=cur[parts[i]];if(!cur)return;}
                var last=parts[parts.length-1];
                if(typeof cur[last]!=='function'||fslSdkAlreadyWrapped(cur[last]))return;
                var orig=cur[last];
                var wrapped=function(){
                    var result=orig.apply(this,arguments);
                    // SDKs using standard browser acquisition still pass through
                    // the getUserMedia gate. Preserve their launcher contract.
                    if(result&&typeof result.launch==='function'&&!fslSdkAlreadyWrapped(result.launch)){var _oL=result.launch;var _wL=function(){return _oL.apply(this,arguments);};result.launch=fslSdkMarkWrapped(_wL);}
                    return result;
                };
                cur[last]=fslSdkMarkWrapped(wrapped);
            }catch(e){}
        }
        fslWrapVendorLaunch('Onfido','init');
        fslWrapVendorLaunch('Veriff','init');
        fslWrapVendorLaunch('snsWebSdk','init');
        fslWrapVendorLaunch('iProov','init');
        fslWrapVendorLaunch('FaceTec','init');
        fslWrapVendorLaunch('BlinkID','init');
        fslWrapVendorLaunch('MiSnap','init');
        fslWrapVendorLaunch('Scandit','init');
        fslWrapVendorLaunch('Anyline','init');
        fslWrapVendorLaunch('Dynamsoft','init');

        // Bridge transports: detect camera command patterns in postMessage
        // and route through injection. Only wraps when the bridge exists.
        if(typeof window!=='undefined'&&window.ReactNativeWebView&&typeof window.ReactNativeWebView.postMessage==='function'&&!fslSdkAlreadyWrapped(window.ReactNativeWebView.postMessage)){
            var _origRNWV=window.ReactNativeWebView.postMessage;
            var _wRNWV=function(msg){if(fslSdkLooksLikeCamera(msg)){fslSdkNoteBridge('react-native-webview');fslSdkBestEffort('react-native-webview','both');}return _origRNWV.apply(window.ReactNativeWebView,arguments);};
            window.ReactNativeWebView.postMessage=fslSdkMarkWrapped(_wRNWV);
            s._sdkWrap_rnwv=true;
        }
        if(typeof window!=='undefined'&&window.bridge&&typeof window.bridge.callHandler==='function'&&!fslSdkAlreadyWrapped(window.bridge.callHandler)){
            var _origBCH=window.bridge.callHandler;
            var _wBCH=function(name,data,callback){if(fslSdkLooksLikeCamera(name)||fslSdkLooksLikeCamera(data)){fslSdkNoteBridge('webview-javascript-bridge:'+name);var fp=fslSdkBestEffort('webview-javascript-bridge:'+name,'both');if(fp){if(typeof callback==='function'){fp.then(callback);return;}return fp;}}return _origBCH.apply(window.bridge,arguments);};
            window.bridge.callHandler=fslSdkMarkWrapped(_wBCH);
            s._sdkWrap_bridge=true;
        }
        if(typeof window!=='undefined'&&window.dsBridge&&typeof window.dsBridge.call==='function'&&!fslSdkAlreadyWrapped(window.dsBridge.call)){
            var _origDSB=window.dsBridge.call;
            var _wDSB=function(name,data,callback){if(fslSdkLooksLikeCamera(name)||fslSdkLooksLikeCamera(data)){fslSdkNoteBridge('dsbridge:'+name);var fp=fslSdkBestEffort('dsbridge:'+name,'both');if(fp){if(typeof callback==='function'){fp.then(callback);return;}return fp;}}return _origDSB.apply(window.dsBridge,arguments);};
            window.dsBridge.call=fslSdkMarkWrapped(_wDSB);
            s._sdkWrap_dsBridge=true;
        }

        // WebViewJavascriptBridge: window.WebViewJavascriptBridge.callHandler (canonical global form)
        if(typeof window!=='undefined'&&window.WebViewJavascriptBridge&&typeof window.WebViewJavascriptBridge.callHandler==='function'&&!fslSdkAlreadyWrapped(window.WebViewJavascriptBridge.callHandler)){
            var _origWVJB=window.WebViewJavascriptBridge.callHandler;
            var _wWVJB=function(name,data,callback){if(fslSdkLooksLikeCamera(name)||fslSdkLooksLikeCamera(data)){fslSdkNoteBridge('webview-javascript-bridge-global:'+name);var fp=fslSdkBestEffort('webview-javascript-bridge-global:'+name,'both');if(fp){if(typeof callback==='function'){fp.then(callback);return;}return fp;}}return _origWVJB.apply(window.WebViewJavascriptBridge,arguments);};
            window.WebViewJavascriptBridge.callHandler=fslSdkMarkWrapped(_wWVJB);
            s._sdkWrap_wvjb=true;
        }

        // Generic WKWebView message handlers: only observe host-defined command
        // traffic. Their response schema belongs to the host, so returning a File
        // here would corrupt the contract and cannot safely fulfill the command.
        if(typeof window!=='undefined'&&window.webkit&&window.webkit.messageHandlers){
            try{
                var _mhNames=Object.getOwnPropertyNames(window.webkit.messageHandlers);
                for(var _mhi=0;_mhi<_mhNames.length;_mhi++){
                    var _mhName=_mhNames[_mhi];
                    if(_mhName.indexOf('fsl')===0)continue;
                    var _mh=window.webkit.messageHandlers[_mhName];
                    if(!_mh||typeof _mh.postMessage!=='function'||fslSdkAlreadyWrapped(_mh.postMessage))continue;
                    (function(mh,mhName){
                        var _origPM=mh.postMessage;
                        var _wPM=function(data){if(fslSdkLooksLikeCamera(data)||fslSdkLooksLikeCamera(mhName)){fslSdkNoteBridge('message-handler:'+mhName);fslSdkBestEffort('message-handler:'+mhName,'both');}return _origPM.apply(mh,arguments);};
                        mh.postMessage=fslSdkMarkWrapped(_wPM);
                    })(_mh,_mhName);
                }
                s._sdkWrap_msgHandler=true;
            }catch(e){}
        }

        // Flutter InAppWebView: preserve the host callback contract while noting
        // camera-like handlers for diagnostics and standard-media follow-through.
        if(typeof window!=='undefined'&&window.flutter_inappwebview&&typeof window.flutter_inappwebview.callHandler==='function'&&!fslSdkAlreadyWrapped(window.flutter_inappwebview.callHandler)){
            var _origFIW=window.flutter_inappwebview.callHandler;
            var _wFIW=function(name){if(fslSdkLooksLikeCamera(name)){fslSdkNoteBridge('flutter:'+name);var fp=fslSdkBestEffort('flutter:'+name,'both');if(fp)return fp;}return _origFIW.apply(window.flutter_inappwebview,arguments);};
            window.flutter_inappwebview.callHandler=fslSdkMarkWrapped(_wFIW);
            s._sdkWrap_flutter=true;
        }

        // Titanium/Appcelerator: only decorate known methods once and retain their
        // callback/return conventions instead of substituting a browser File.
        function fslWrapTiMedia(tiObj,label){
            try{
                if(!tiObj||!tiObj.Media)return;
                var _tm=tiObj.Media;
                var _camMethods=['openCamera','takePicture','showCamera','startCamera','createCamera','switchCamera'];
                for(var ci=0;ci<_camMethods.length;ci++){
                    var mn=_camMethods[ci];
                    if(typeof _tm[mn]==='function'&&!fslSdkAlreadyWrapped(_tm[mn])){
                        (function(orig,method){var wrapped=function(){fslSdkNoteBridge(label+'.Media.'+method);var fp=fslSdkBestEffort(label+'.Media.'+method,'both');if(fp){var args=arguments,cb=null;for(var ai=args.length-1;ai>=0;ai--){if(typeof args[ai]==='function'){cb=args[ai];break;}}if(cb){fp.then(function(result){cb(result);});return;}return fp;}return orig.apply(_tm,arguments);};_tm[method]=fslSdkMarkWrapped(wrapped);})(_tm[mn],mn);
                    }
                }
                s._sdkWrap_titanium=true;
            }catch(e){}
        }
        if(typeof window!=='undefined'){fslWrapTiMedia(window.Ti,'Ti');fslWrapTiMedia(window.Titanium,'Titanium');}

        // Veriff direct constructor and createVeriffFrame. A Proxy preserves
        // `new` semantics and static members; calling a class with `.apply` does not.
        if(typeof window!=='undefined'&&window.Veriff&&typeof window.Veriff==='function'&&!fslSdkAlreadyWrapped(window.Veriff)){
            try{
                var _origVeriffCtor=window.Veriff;
                if(typeof Proxy!=='undefined'&&typeof Reflect!=='undefined'){
                    var _veriffProxy=new Proxy(_origVeriffCtor,{apply:function(target,thisArg,args){fslSdkNoteBridge('veriff-call');return Reflect.apply(target,thisArg,args);},construct:function(target,args,newTarget){fslSdkNoteBridge('veriff-construct');return Reflect.construct(target,args,newTarget);}});
                    window.Veriff=fslSdkMarkWrapped(_veriffProxy);
                    s._sdkWrap_veriffCtor=true;
                }
            }catch(e){}
        }
        if(typeof window!=='undefined'&&typeof window.createVeriffFrame==='function'&&!fslSdkAlreadyWrapped(window.createVeriffFrame)){
            var _origCVF=window.createVeriffFrame;
            var _wCVF=function(){fslSdkNoteBridge('veriff-frame');return _origCVF.apply(this,arguments);};
            window.createVeriffFrame=fslSdkMarkWrapped(_wCVF);
            s._sdkWrap_veriffFrame=true;
        }

        // WebXR raw camera access has no portable synthetic XRSession contract.
        // Fail explicitly without consuming a queued asset or leaking hardware.
        if(typeof navigator!=='undefined'&&navigator.xr&&typeof navigator.xr.requestSession==='function'&&!fslSdkAlreadyWrapped(navigator.xr.requestSession)){
            var _origXRS=navigator.xr.requestSession;
            var _wXRS=function(mode,opts){var state=gs();if(state&&state._sdkWrap&&state.a&&state.seq&&state.seq.length&&fslSdkLooksLikeCamera(opts&&opts.requiredFeatures)){fslSdkNoteBridge('webxr-camera-access');return Promise.reject(new DOMException('Camera access via WebXR is unavailable while injected media is active.','NotAllowedError'));}return _origXRS.apply(navigator.xr,arguments);};
            navigator.xr.requestSession=fslSdkMarkWrapped(_wXRS);
            s._sdkWrap_webxr=true;
        }

        // Declarative camera/microphone/usermedia elements and iproov-me are
        // detected without consuming a sequence item. Any real browser camera
        // request they make still flows through the standard getUserMedia gate.
        if(typeof MutationObserver!=='undefined'&&!s._sdkWrap_declEl){
            try{
                var _declTags=['camera','microphone','usermedia','iproov-me'];
                var _declObs=new MutationObserver(function(muts){for(var mi=0;mi<muts.length;mi++){var added=muts[mi].addedNodes;for(var ai=0;ai<added.length;ai++){var n=added[ai];if(n.nodeType!==1)continue;var tag=n.tagName?n.tagName.toLowerCase():'';if(_declTags.indexOf(tag)>=0)fslSdkNoteBridge('declarative:'+tag);var sub=n.querySelectorAll?n.querySelectorAll(_declTags.join(',')):null;if(sub){for(var si=0;si<sub.length;si++)fslSdkNoteBridge('declarative:'+sub[si].tagName.toLowerCase());}}}});
                _declObs.observe(document.documentElement||document.body||document,{childList:true,subtree:true});
                s._sdkWrap_declEl=true;
            }catch(e){}
        }

        // Custom-scheme navigation has no shared response schema. For camera-like
        // routes, return the queued asset through the best-effort result event and
        // avoid launching a second native camera surface.
        if(!s._sdkWrap_scheme){
            var _origLocSet=null;
            try{
                var _locDesc=Object.getOwnPropertyDescriptor(window.Location.prototype,'href');
                if(_locDesc&&_locDesc.set){
                    _origLocSet=_locDesc.set;
                    Object.defineProperty(window.Location.prototype,'href',{configurable:true,enumerable:_locDesc.enumerable,get:_locDesc.get,set:function(v){if(fslSdkLooksLikeCamera(v)){fslSdkNoteBridge('custom-scheme-location');if(fslSdkBestEffort('custom-scheme-location','both'))return;}return _origLocSet.call(this,v);}});
                }
            }catch(e){}
            if(typeof window.open==='function'&&!fslSdkAlreadyWrapped(window.open)){var _origWO=window.open;var _wWO=function(url){if(fslSdkLooksLikeCamera(url)){fslSdkNoteBridge('custom-scheme-window-open');if(fslSdkBestEffort('custom-scheme-window-open','both'))return null;}return _origWO.apply(window,arguments);};window.open=fslSdkMarkWrapped(_wWO);maskFn(window.open,'open',false);}
            // Hidden iframe src custom-scheme navigation interception
            try{
                var _iframeSrcDesc=Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype,'src');
                if(_iframeSrcDesc&&_iframeSrcDesc.set){
                    var _origIframeSet=_iframeSrcDesc.set;
                    Object.defineProperty(HTMLIFrameElement.prototype,'src',{configurable:true,enumerable:_iframeSrcDesc.enumerable,get:_iframeSrcDesc.get,set:function(v){if(fslSdkLooksLikeCamera(v)){fslSdkNoteBridge('custom-scheme-iframe');if(fslSdkBestEffort('custom-scheme-iframe','both'))return;}return _origIframeSet.call(this,v);}});
                    s._sdkWrap_iframeScheme=true;
                }
            }catch(e){}
            s._sdkWrap_scheme=true;
        }

        s._armParts.sdkWrap=true;
        }catch(e){_armErrs.push('sdkWrap:'+((e&&e.message)||e));}}

    function fslApplyFile(input, file) { var dt = new DataTransfer();
        try {
            dt.items.add(file);
            input.files = dt.files;
            input.dispatchEvent(new Event('change', { bubbles: true }));
        } catch (e) {
            try {
                var list = new DataTransfer();
                list.items.add(file);
                input.files = list.files;
            } catch (err) {}
        }
    }

    function fslHybridAdapter() {
        if(window.cordova) return 'cordova';
        if(window.Capacitor) return 'capacitor';
        return null;
    }

    // Build a File from the inline payload bytes for a native camera-capture
    // hand-off. The stripped JPEG (sb64) is the preferred source — Safari drops
    // EXIF on a live capture — but we fall back through every available base64
    // field so a hand-off never fails just because one extraction hasn't run.
    function fslBuildCaptureFile(step,p,kind){
        var b64=p.sb64||step.sb64||p.b64||step.b64||p.pb64||step.pb64||'';
        var mime=p.fmime||step.fmime||p.jmime||'image/jpeg';
        if(!b64){return null;}
        try{
            var bin=atob(b64),n=bin.length,u=new Uint8Array(n);
            for(var i=0;i<n;i++)u[i]=bin.charCodeAt(i);
            var blob=new Blob([u],{type:mime});
            var name=(step&&step.name)?step.name:((kind==='video')?'media.mp4':'media.jpg');
            try{return new File([blob],name,{type:mime,lastModified:Date.now()});}
            catch(e){blob.name=name;blob.lastModified=Date.now();return blob;}
        }catch(e){return null;}
    }
    _s._buildCaptureFile=fslBuildCaptureFile;

        s._armed=!!s._armParts.gum;
        s._armError=_armErrs.join(' | ');
    }

    }catch(e){}
    })();
    """

    /// Fixed document-start bootstrap. It asks the native bridge for one versioned
    /// snapshot and applies it only through the engine's guarded state function.
    /// No page-facing callback is exposed and no user scripts are replaced at run time.
    static var runtimeStateBootstrapScript: String {
        return """
        (function(){
        var _docReqId=Date.now()+'_'+Math.random();
        function applyState(raw){
            try{
                var payload=(typeof raw==='string')?JSON.parse(raw):raw;
                if(payload&&payload.reqId&&payload.reqId!==_docReqId)return;
                var state=payload.state||payload;
                var s=window[Symbol.for('fsl')];
                if(s&&typeof s._applyRuntimeState==='function')s._applyRuntimeState(state);
            }catch(e){
                try{var s=window[Symbol.for('fsl')];if(s&&s._lifecycle)s._lifecycle('requestCancelled',null,'runtime-state-invalid','The document could not apply the native runtime state.','live');}catch(_){ }
            }
        }
        try{
            var handlers=window.webkit&&window.webkit.messageHandlers;
            var bridge=handlers&&handlers.fslState;
            if(!bridge||typeof bridge.postMessage!=='function')return;
            var reply=bridge.postMessage({action:'ready',protocol:1,reqId:_docReqId});
        }catch(e){ }
        })();
        """
    }

    /// Applies a newer runtime state to an already loaded document. The engine
    /// discards lower versions, so late WebKit evaluations cannot overwrite newer
    /// state after navigation, a sequence edit, or an asynchronous payload refresh.
    static func runtimeStateApplyScript(serializedState: String) -> String {
        let literal: String
        if let data = try? JSONSerialization.data(withJSONObject: [serializedState]),
           let array = String(data: data, encoding: .utf8), array.count >= 2 {
            literal = String(array.dropFirst().dropLast())
        } else {
            literal = "\"{}\""
        }
        return """
        (function(){
            try{
                var s=window[Symbol.for('fsl')];
                if(!s||typeof s._applyRuntimeState!=='function')return false;
                return s._applyRuntimeState(JSON.parse(\(literal)));
            }catch(e){return false;}
        })();
        """
    }

    /// Emits a lifecycle marker without altering media tracks. The next foreground
    /// snapshot restores state through the normal versioned path.
    static func pageLifecycleSignalScript(phase: MediaDeliveryPhase) -> String {
        let raw = phase.rawValue
        return """
        (function(){
            try{
                var s=window[Symbol.for('fsl')];
                if(s&&s._lifecycle)s._lifecycle('\(raw)',null,'','App lifecycle changed.','live');
            }catch(e){}
        })();
        """
    }

    // MARK: - Safari user agent builder

    static func buildSafariUserAgent(from defaultUA: String) -> String {
        if defaultUA.contains("Version/") && defaultUA.contains("Safari/") {
            return defaultUA
        }

        let v = ProcessInfo.processInfo.operatingSystemVersion
        let safariVer = v.patchVersion > 0
            ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "\(v.majorVersion).\(v.minorVersion)"

        if !defaultUA.isEmpty && defaultUA.contains("Mobile/") {
            return defaultUA.replacingOccurrences(
                of: "Mobile/",
                with: "Version/\(safariVer) Mobile/"
            ) + " Safari/604.1"
        }

        return safariUserAgent
    }

    static var safariUserAgent: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osUA = v.patchVersion > 0
            ? "\(v.majorVersion)_\(v.minorVersion)_\(v.patchVersion)"
            : "\(v.majorVersion)_\(v.minorVersion)"
        let safariVer = v.patchVersion > 0
            ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "\(v.majorVersion).\(v.minorVersion)"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osUA) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVer) Mobile/15E148 Safari/604.1"
    }

    // MARK: - Device profile JS builders

    /// Stable 32-bit seed derived from a camera's identity (FNV-1a). Identical
    /// every session for the same device, and different between devices — the
    /// anchor for the per-device sensor grain / PRNU pattern.
    private static func stableSeed(_ s: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return h
    }

    private static func buildDeviceProfileJS(dev: CameraDeviceSpec, facingMode: String, realSnapshot: MediaSnapshot?, fallbackModelName: String = "") -> String {
        let realSettings = realSnapshot?.trackSettings
        let realCaps = realSnapshot?.trackCapabilities
        let realVideoDevice = realSnapshot?.devices.first { $0.kind == "videoinput" }

        // Model-specific label fallback: "iPhone 15 Pro Front Camera" instead of
        // the generic "Front Camera" so synthetic devices are consistent with
        // what a real device of this model would report.
        let positionLabel = facingMode == "user" ? "Front Camera" : "Back Camera"
        let modelLabel = fallbackModelName.isEmpty ? "" : "\(fallbackModelName) "
        let fallbackLabel = "\(modelLabel)\(positionLabel)"

        // Profile-anchored deviceId: use the camera's uniqueID when available,
        // otherwise derive a stable, device-specific hash from the model name
        // and position so each profile gets distinct but consistent IDs.
        let fallbackDeviceId: String
        if !dev.uniqueID.isEmpty {
            fallbackDeviceId = dev.uniqueID
        } else {
            let hashSeed = "\(fallbackModelName)|\(dev.position)|\(facingMode)"
            let hash = stableSeed(hashSeed)
            fallbackDeviceId = "com.apple.avfoundation.avcapturedevice.\(dev.position)-\(hash)"
        }

        let deviceId = (facingMode == "user" ? realSettings?.deviceId : nil) ?? realVideoDevice?.deviceId ?? fallbackDeviceId
        let groupId = (facingMode == "user" ? realSettings?.groupId : nil) ?? realVideoDevice?.groupId ?? "com.apple.avfoundation.avcapturedevice.\(dev.position)"
        let label = (facingMode == "user" ? (realVideoDevice?.label ?? realSnapshot?.trackLabel) : nil) ?? (dev.label.isEmpty ? fallbackLabel : dev.label)
        let width = (facingMode == "user" ? realSettings?.width : nil) ?? dev.activeWidth
        let height = (facingMode == "user" ? realSettings?.height : nil) ?? dev.activeHeight
        let fps = (facingMode == "user" ? realSettings.map { Int($0.frameRate) } : nil) ?? Int(dev.activeFrameRate)
        let aspectRatio = Double(width) / Double(height)
        let resizeMode = (facingMode == "user" ? realSettings?.resizeMode : nil) ?? "none"
        let trackLabel = (facingMode == "user" ? realSnapshot?.trackLabel : nil) ?? label

        let maxWidth = (facingMode == "user" ? realCaps?.widthMax : nil) ?? dev.maxWidth
        let maxHeight = (facingMode == "user" ? realCaps?.heightMax : nil) ?? dev.maxHeight
        let minWidth = (facingMode == "user" ? realCaps?.widthMin : nil) ?? 1
        let minHeight = (facingMode == "user" ? realCaps?.heightMin : nil) ?? 1
        let maxFPS = (facingMode == "user" ? realCaps.map { Int($0.frameRateMax) } : nil) ?? Int(dev.maxFrameRate)
        let minFPS = (facingMode == "user" ? realCaps.map { Int($0.frameRateMin) } : nil) ?? Int(dev.minFrameRate)

        let eDid = deviceId.replacingOccurrences(of: "'", with: "\\'")
        let eGid = groupId.replacingOccurrences(of: "'", with: "\\'")
        let eLbl = label.replacingOccurrences(of: "'", with: "\\'")
        let eTlbl = trackLabel.replacingOccurrences(of: "'", with: "\\'")

        // Per-device sensor seed anchored to the saved camera identity so the
        // grain / PRNU pattern stays identical every session for this device.
        let seedSource = dev.uniqueID.isEmpty ? "\(dev.label)|\(dev.position)|\(facingMode)" : dev.uniqueID
        let seed = stableSeed(seedSource)

        return """
        {
            deviceId:'\(eDid)',
            seed:\(seed),
            groupId:'\(eGid)',
            label:'\(eLbl)',
            trackLabel:'\(eTlbl)',
            width:\(width),
            height:\(height),
            frameRate:\(fps),
            facingMode:'\(facingMode)',
            aspectRatio:\(aspectRatio),
            resizeMode:'\(resizeMode)',
            maxWidth:\(maxWidth),
            maxHeight:\(maxHeight),
            minWidth:\(minWidth),
            minHeight:\(minHeight),
            maxFrameRate:\(maxFPS),
            minFrameRate:\(minFPS),
            capFacingModes:['\(facingMode)'],
            capResizeModes:['none','crop-and-scale']
        }
        """
    }

    /// Synthesizes a stable back-camera profile JS from a front camera's specs,
    /// used when the device has no physical back camera (e.g. the simulator).
    /// The deviceId and label are position-based so they stay stable across
    /// sessions and are distinct from the front camera's identity.
    private static func buildSyntheticBackProfileJS(from frontDev: CameraDeviceSpec, fallbackModelName: String) -> String {
        let hashSeed = "\(fallbackModelName)|back|environment"
        let hash = stableSeed(hashSeed)
        let deviceId = "com.apple.avfoundation.avcapturedevice.back-\(hash)"
        let groupId = "com.apple.avfoundation.avcapturedevice.back"
        let modelLabel = fallbackModelName.isEmpty ? "" : "\(fallbackModelName) "
        let label = "\(modelLabel)Back Camera"
        let width = frontDev.activeWidth
        let height = frontDev.activeHeight
        let fps = Int(frontDev.activeFrameRate)
        let aspectRatio = Double(width) / Double(height)
        let seed = stableSeed("synthetic-back|\(fallbackModelName)|environment")

        let eDid = deviceId.replacingOccurrences(of: "'", with: "\\'")
        let eGid = groupId.replacingOccurrences(of: "'", with: "\\'")
        let eLbl = label.replacingOccurrences(of: "'", with: "\\'")

        return """
        {
            deviceId:'\(eDid)',
            seed:\(seed),
            groupId:'\(eGid)',
            label:'\(eLbl)',
            trackLabel:'\(eLbl)',
            width:\(width),
            height:\(height),
            frameRate:\(fps),
            facingMode:'environment',
            aspectRatio:\(aspectRatio),
            resizeMode:'none',
            maxWidth:\(frontDev.maxWidth),
            maxHeight:\(frontDev.maxHeight),
            minWidth:1,
            minHeight:1,
            maxFrameRate:\(Int(frontDev.maxFrameRate)),
            minFrameRate:\(Int(frontDev.minFrameRate)),
            capFacingModes:['environment'],
            capResizeModes:['none','crop-and-scale']
        }
        """
    }

    /// Test-visible wrapper for `buildDeviceProfileJS` so tests can verify
    /// synthetic camera naming without constructing a full `DeviceProfile`.
    static func buildDeviceProfileJSForTesting(
        dev: CameraDeviceSpec,
        facingMode: String,
        realSnapshot: MediaSnapshot?,
        fallbackModelName: String = ""
    ) -> String {
        buildDeviceProfileJS(dev: dev, facingMode: facingMode, realSnapshot: realSnapshot, fallbackModelName: fallbackModelName)
    }

    private static func buildMicProfileJS(mic: MicrophoneDeviceSpec, realSnapshot: MediaSnapshot?) -> String {
        let realAudioDevice = realSnapshot?.devices.first { $0.kind == "audioinput" }

        let deviceId = realAudioDevice?.deviceId ?? mic.uniqueID
        let groupId = realAudioDevice?.groupId ?? "com.apple.avfoundation.avcapturedevice.built-in_audio:0"
        let label = realAudioDevice?.label ?? mic.label
        let sampleRate = mic.testSampleRate ?? mic.sampleRate
        let channelCount = mic.testChannelCount ?? mic.channelCount

        let eDid = deviceId.replacingOccurrences(of: "'", with: "\\'")
        let eGid = groupId.replacingOccurrences(of: "'", with: "\\'")
        let eLbl = label.replacingOccurrences(of: "'", with: "\\'")

        return """
        {
            deviceId:'\(eDid)',
            groupId:'\(eGid)',
            label:'\(eLbl)',
            sampleRate:\(Int(sampleRate)),
            channelCount:\(channelCount),
            maxSampleRate:\(Int(sampleRate)),
            maxChannelCount:\(channelCount),
            latency:0.01
        }
        """
    }

    // MARK: - Profile apply script (identity + method)

    /// Pushes device identity and the active injection method into the page.
    /// Replaces the old profile-masking-flags approach with a single method
    /// string. Fingerprint stabilization is always applied separately.
    static func profileApplyScript(
        from profile: DeviceProfile,
        method: InjectionMethodKind = .canvasPipeline,
        sensorRealism: Bool = true,
        sdkWrap: Bool = false
    ) -> String {
        guard let frontDev = profile.frontCamera ?? profile.cameras.first else {
            return ""
        }

        let realSnapshot = profile.mediaTestResult?.realSnapshot

        let modelName = profile.deviceHardware.modelName
        let frontProfileJS = buildDeviceProfileJS(dev: frontDev, facingMode: "user", realSnapshot: realSnapshot, fallbackModelName: modelName)

        var backProfileJS = "null"
        if let backDev = profile.backCamera {
            backProfileJS = buildDeviceProfileJS(dev: backDev, facingMode: "environment", realSnapshot: nil, fallbackModelName: modelName)
        } else if frontDev.position == "front" {
            // No physical back camera (e.g. simulator with one injected camera).
            // Synthesize a stable back camera profile from the front camera's
            // specs so enumerateDevices can present both cameras. The deviceId
            // and label are position-based so they stay stable across sessions.
            backProfileJS = buildSyntheticBackProfileJS(from: frontDev, fallbackModelName: modelName)
        }

        var micProfileJS = "null"
        if let mic = profile.primaryMicrophone {
            micProfileJS = buildMicProfileJS(mic: mic, realSnapshot: realSnapshot)
        }

        let methodJS = method.jsValue

        return """
        (function(){
        var s=window[Symbol.for('fsl')];
        if(!s)return;
        s.fp=\(frontProfileJS);
        s.bp=\(backProfileJS);
        s.mp=\(micProfileJS);
        s._method='\(methodJS)';
        s._sensorRealism=\(sensorRealism ? "true" : "false");
        s._sdkWrap=\(sdkWrap ? "true" : "false");
        try{if(s._sdkWrap){if(s._watchSdkWraps)s._watchSdkWraps();if(s._refreshSdkWraps)s._refreshSdkWraps();}}catch(e){}
        })();
        """
    }

    /// Live toggle for the optional SDK / bridge wrapping layer. Flipping it
    /// pushes the new value into the live page so it takes effect immediately.
    /// The SDK wraps are installed by arm() unconditionally (guarded by
    /// existence of each target), but only route through the injection when
    /// this flag is on AND media is active.
    static func sdkWrapApplyScript(enabled: Bool) -> String {
        return """
        (function(){var s=window[Symbol.for('fsl')];if(!s)return;s._sdkWrap=\(enabled ? "true" : "false");try{if(s._sdkWrap){if(s._watchSdkWraps)s._watchSdkWraps();if(s._refreshSdkWraps)s._refreshSdkWraps();}}catch(e){}})();
        """
    }

    /// Live toggle for the Round 2 sensor-realism layer. Flipping it takes effect
    /// on the next frame (in-page feed) / next stream (private lane) with no
    /// reload, since the pump and grain wrapper read the flag every frame.
    static func sensorRealismApplyScript(enabled: Bool) -> String {
        return """
        (function(){var s=window[Symbol.for('fsl')];if(!s)return;s._sensorRealism=\(enabled ? "true" : "false");})();
        """
    }

    /// Live toggle for the opt-in failure recorder. Off by default, and silent
    /// on the page until the user switches it on.
    static func failureRecorderApplyScript(enabled: Bool) -> String {
        return """
        (function(){var s=window[Symbol.for('fsl')];if(!s)return;s._traceOn=\(enabled ? "true" : "false");})();
        """
    }

    /// Marks a web view as the app's OWN test page. Diagnostics behaviour that
    /// must never touch real browsing (probe mode) is gated on this flag, so a
    /// page the user is actually viewing can never be affected by a self-test.
    static var harnessMarkScript: String {
        return """
        (function(){var s=window[Symbol.for('fsl')];if(!s)return;s._isHarness=true;})();
        """
    }

    /// Releases any live-feed hold left over from a previous hand-off. Called
    /// whenever the app re-syncs the page, so a stuck hold can never survive
    /// into a new request.
    static var releaseFeedHoldScript: String {
        return """
        (function(){
        var s=window[Symbol.for('fsl')];
        if(!s||!s._feedHold)return;
        if(s._resumeFeed){try{s._resumeFeed();}catch(e){}}
        s._feedHold=false;
        })();
        """
    }

    // MARK: - Fingerprint stabilization (always active for all methods)

    /// Builds the fingerprint-stabilization JavaScript. Unlike the old
    /// profiles, fingerprint protection (canvas, WebGL, audio) is always
    /// applied for all injection methods — it's identity protection,
    /// not a masking-policy concern.
    static func buildFingerprintStabilizationJS(from profile: DeviceProfile) -> String {
        var lines: [String] = ["(function(){", "'use strict';", "try{"]

        // Shared disguise helpers
        lines.append("""
        var _fsl=window[Symbol.for('fsl')];
        function _own(o,n){var c=o;while(c){if(Object.getOwnPropertyDescriptor(c,n))return c;c=Object.getPrototypeOf(c);}return o;}
        function _mask(fn,n,g){try{if(_fsl&&_fsl._maskFn)_fsl._maskFn(fn,n,g);}catch(e){}}
        function _def(o,n,v){try{var w=_own(o,n);var d=Object.getOwnPropertyDescriptor(w,n);var en=d?!!d.enumerable:true;var g=function(){return v;};Object.defineProperty(w,n,{get:g,set:undefined,configurable:true,enumerable:en});_mask(g,n,true);}catch(e){}}
        function _del(o,n){try{var w=_own(o,n);if(w&&Object.getOwnPropertyDescriptor(w,n)){delete w[n];}}catch(e){}}
        function _maskMethod(o,n){try{if(o&&typeof o[n]==='function')_mask(o[n],n,false);}catch(e){}}
        """)

        // Step 0: Purge non-Safari PDF plugins
        lines.append("""
        (function(){
        try{
        var _blacklist=['Chrome PDF Viewer','Chromium PDF Viewer','Microsoft Edge PDF Viewer','WebKit built-in PDF'];
        if(navigator.plugins){
        var _real=[];
        for(var i=0;i<navigator.plugins.length;i++){
        if(_blacklist.indexOf(navigator.plugins[i].name)<0)_real.push(navigator.plugins[i]);
        }
        _def(navigator,'plugins',_real);
        }
        if(navigator.mimeTypes){
        var _rm=[];
        for(var j=0;j<navigator.mimeTypes.length;j++){
        if(_blacklist.indexOf(navigator.mimeTypes[j].enabledPlugin?navigator.mimeTypes[j].enabledPlugin.name:'')<0)_rm.push(navigator.mimeTypes[j]);
        }
        _def(navigator,'mimeTypes',_rm);
        }
        }catch(e){}
        })();
        """)

        // Step 1: Navigator identity
        let hwc = profile.webFingerprint.hardwareConcurrency
        let vendor = profile.webFingerprint.vendor.isEmpty ? "Apple Computer, Inc." : profile.webFingerprint.vendor
        let platform = profile.webFingerprint.platform.isEmpty ? "iPhone" : profile.webFingerprint.platform
        let maxTouch = profile.webFingerprint.maxTouchPoints > 0 ? profile.webFingerprint.maxTouchPoints : 5
        let language = profile.webFingerprint.language.isEmpty ? "en-US" : profile.webFingerprint.language
        let langs = profile.webFingerprint.languages.isEmpty ? [language] : profile.webFingerprint.languages
        let langsJS = "[" + langs.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" }.joined(separator: ",") + "]"
        let eVendor = vendor.replacingOccurrences(of: "'", with: "\\'")
        let ePlatform = platform.replacingOccurrences(of: "'", with: "\\'")
        let eLang = language.replacingOccurrences(of: "'", with: "\\'")
        let colorDepth = profile.webFingerprint.screenColorDepth > 0 ? profile.webFingerprint.screenColorDepth : 24
        let dpr = profile.webFingerprint.devicePixelRatio > 0 ? profile.webFingerprint.devicePixelRatio : 3.0
        let eUA = StyleSheetProvider.safariUserAgent.replacingOccurrences(of: "'", with: "\\'")
        let eAppVersion = String(StyleSheetProvider.safariUserAgent.dropFirst("Mozilla/".count)).replacingOccurrences(of: "'", with: "\\'")
        lines.append("""
        _def(navigator,'hardwareConcurrency',\(hwc));
        _def(navigator,'vendor','\(eVendor)');
        _def(navigator,'platform','\(ePlatform)');
        _def(navigator,'maxTouchPoints',\(maxTouch));
        _def(navigator,'language','\(eLang)');
        _def(navigator,'languages',Object.freeze(\(langsJS)));
        _def(window,'devicePixelRatio',\(dpr));
        _def(screen,'colorDepth',\(colorDepth));
        _def(screen,'pixelDepth',\(colorDepth));
        _def(navigator,'appVersion','\(eAppVersion)');
        _def(navigator,'appName','Netscape');
        _def(navigator,'product','Gecko');
        _def(navigator,'productSub','20030107');
        _def(navigator,'userAgent','\(eUA)');
        _def(navigator,'vendorSub','');
        _def(navigator,'doNotTrack',null);
        _def(navigator,'webdriver',false);
        _del(navigator,'deviceMemory');
        """)

        // Step 2: Screen metrics
        let sw = profile.webFingerprint.screenWidth
        let sh = profile.webFingerprint.screenHeight
        let availTop: Int = 47
        let availLeft: Int = 0
        if let baseline = profile.fingerprintBaseline {
            let at = baseline.screenFrameTop > 0 ? baseline.screenFrameTop : availTop
            let al = baseline.screenFrameLeft > 0 ? baseline.screenFrameLeft : availLeft
            let aw = baseline.screenWidth > 0 ? baseline.screenWidth : sw
            let ah = baseline.screenHeight > 0 ? baseline.screenHeight : sh
            let availH = ah - at
            lines.append("""
            _def(screen,'width',\(aw));
            _def(screen,'height',\(ah));
            _def(screen,'availWidth',\(aw));
            _def(screen,'availHeight',\(availH));
            _def(screen,'availTop',\(at));
            _def(screen,'availLeft',\(al));
            _def(window,'screenY',\(at));
            _def(window,'screenTop',\(at));
            _def(window,'screenLeft',\(al));
            _def(window,'screenX',\(al));
            _def(screen,'left',\(al));
            _def(screen,'top',\(at));
            """)
        } else {
            let at = availTop
            let availH2 = sh - at
            lines.append("""
            _def(screen,'width',\(sw));
            _def(screen,'height',\(sh));
            _def(screen,'availWidth',\(sw));
            _def(screen,'availHeight',\(availH2));
            _def(screen,'availTop',\(at));
            _def(screen,'availLeft',0);
            _def(window,'screenY',\(at));
            _def(window,'screenTop',\(at));
            _def(window,'screenLeft',0);
            _def(window,'screenX',0);
            _def(screen,'left',0);
            _def(screen,'top',\(at));
            """)
        }

        // Step 3: Stabilize AudioContext fingerprint
        if let baseline = profile.fingerprintBaseline, let audioFP = baseline.audioFingerprint {
            lines.append("""
            (function(){
            try{
            if(!_fsl||_fsl._fpAudio)return;
            _fsl._fpAudio=true;
            var _savedAudioFP=\(audioFP);
            var _origCTX=window.AudioContext||window.webkitAudioContext;
            var _origOAC=window.OfflineAudioContext||window.webkitOfflineAudioContext;
            if(!_origOAC||!_origCTX)return;
            var _OrigProto=_origOAC.prototype;
            var _origStartRendering=_OrigProto.startRendering;
            _OrigProto.startRendering=function startRendering(){
                var self=this;
                return _origStartRendering.call(this).then(function(buf){
                    var ch=buf.getChannelData(0);
                    var isFingerprintCall=(self.length>=44100&&self.sampleRate>=44100);
                    if(isFingerprintCall){
                        var targetPerSample=_savedAudioFP/500;
                        for(var i=4500;i<Math.min(5000,ch.length);i++){
                            ch[i]=(i%2===0?1:-1)*targetPerSample;
                        }
                    }
                    return buf;
                });
            };
            _maskMethod(_OrigProto,'startRendering');
            var _origCreate=new _origCTX();
            var _sr=_origCreate.sampleRate||44100;
            _origCreate.close();
            var _srGet=function(){return _sr;};
            Object.defineProperty(_origCTX.prototype,'sampleRate',{get:_srGet,configurable:true,enumerable:true});
            _mask(_srGet,'sampleRate',true);
            }catch(e){}
            })();
            """)
        }

        // Step 4: Stabilize Canvas fingerprint
        if let baseline = profile.fingerprintBaseline, let canvasHash = baseline.canvasHash {
            let escapedHash = canvasHash.replacingOccurrences(of: "'", with: "\\'")
            lines.append("""
            (function(){
            try{
            if(!_fsl||_fsl._fpCanvas)return;
            _fsl._fpCanvas=true;
            var _savedCanvasHash='\(escapedHash)';
            var _origToDataURL=HTMLCanvasElement.prototype.toDataURL;
            var _canvasCache={};
            HTMLCanvasElement.prototype.toDataURL=function toDataURL(){
                try{
                    var result=_origToDataURL.apply(this,arguments);
                    if(this.width<=300&&this.height<=80){
                        if(!_canvasCache[_savedCanvasHash]){
                            _canvasCache[_savedCanvasHash]=result;
                        }
                        return _canvasCache[_savedCanvasHash];
                    }
                    return result;
                }catch(e){return _origToDataURL.apply(this,arguments);}
            };
            _maskMethod(HTMLCanvasElement.prototype,'toDataURL');
            var _origToBlob=HTMLCanvasElement.prototype.toBlob;
            HTMLCanvasElement.prototype.toBlob=function toBlob(cb){
                var self=this;
                try{
                    if(typeof cb==='function'&&self.width<=300&&self.height<=80){
                        var dataUrl=self.toDataURL.apply(self,[].slice.call(arguments,1));
                        var parts=dataUrl.split(',');
                        var mimeMatch=parts.length?parts[0].match(/:(.*?);/):null;
                        if(parts.length===2&&mimeMatch){
                            var raw=atob(parts[1]);
                            var arr=new Uint8Array(raw.length);
                            for(var i=0;i<raw.length;i++)arr[i]=raw.charCodeAt(i);
                            cb(new Blob([arr],{type:mimeMatch[1]}));
                            return;
                        }
                    }
                }catch(e){}
                return _origToBlob.apply(self,arguments);
            };
            _maskMethod(HTMLCanvasElement.prototype,'toBlob');
            }catch(e){}
            })();
            """)
        }

        // Step 5: Stabilize WebGL fingerprint
        if let baseline = profile.fingerprintBaseline, let webglHash = baseline.webglHash {
            let escapedWGLHash = webglHash.replacingOccurrences(of: "'", with: "\\'")
            lines.append("""
            (function(){
            try{
            if(!_fsl||_fsl._fpWebGL)return;
            _fsl._fpWebGL=true;
            var _savedWebGLHash='\(escapedWGLHash)';
            var _origGetParam=WebGLRenderingContext.prototype.getParameter;
            var _cachedParams={};
            WebGLRenderingContext.prototype.getParameter=function getParameter(p){
                var result=_origGetParam.call(this,p);
                if(p===this.RENDERER||p===this.VENDOR||p===this.VERSION||p===this.SHADING_LANGUAGE_VERSION){
                    if(!_cachedParams[p])_cachedParams[p]=result;
                    return _cachedParams[p];
                }
                return result;
            };
            _maskMethod(WebGLRenderingContext.prototype,'getParameter');
            var _origGetExt=WebGLRenderingContext.prototype.getExtension;
            var _extCache={};
            WebGLRenderingContext.prototype.getExtension=function getExtension(name){
                if(!_extCache[name])_extCache[name]=_origGetExt.call(this,name);
                return _extCache[name];
            };
            _maskMethod(WebGLRenderingContext.prototype,'getExtension');
            if(typeof WebGL2RenderingContext!=='undefined'){
                var _origGetParam2=WebGL2RenderingContext.prototype.getParameter;
                WebGL2RenderingContext.prototype.getParameter=function getParameter(p){
                    var result=_origGetParam2.call(this,p);
                    if(p===this.RENDERER||p===this.VENDOR||p===this.VERSION||p===this.SHADING_LANGUAGE_VERSION){
                        if(!_cachedParams[p])_cachedParams[p]=result;
                        return _cachedParams[p];
                    }
                    return result;
                };
                _maskMethod(WebGL2RenderingContext.prototype,'getParameter');
                var _origGetExt2=WebGL2RenderingContext.prototype.getExtension;
                WebGL2RenderingContext.prototype.getExtension=function getExtension(name){
                    if(!_extCache[name])_extCache[name]=_origGetExt2.call(this,name);
                    return _extCache[name];
                };
                _maskMethod(WebGL2RenderingContext.prototype,'getExtension');
            }
            }catch(e){}
            })();
            """)
        }

        lines.append("}catch(e){}")
        lines.append("})();")
        return lines.joined(separator: "\n")
    }

    // MARK: - Constraint logging

    static var constraintLoggingScript: String {
        return """
        (function(){
        'use strict';
        try{
        var s=window[Symbol.for('fsl')];
        if(!s)return;
        if(!s._constraintLog)s._constraintLog=[];
        var _origGUM=MediaDevices.prototype.getUserMedia;
        if(s._gumWrapped)return;
        s._gumWrapped=true;
        var _realGUM=_origGUM;
        MediaDevices.prototype.getUserMedia=function getUserMedia(constraints){
            var entry={
                timestamp:Date.now(),
                url:window.location.href,
                constraints:JSON.stringify(constraints||{}),
                result:'pending',
                fallbackReason:null
            };
            s._constraintLog.push(entry);
            if(s._constraintLog.length>100)s._constraintLog.shift();
            return _realGUM.call(this,constraints).then(function(stream){
                var vt=stream.getVideoTracks()[0];
                if(vt&&vt.getSettings){
                    entry.result=JSON.stringify(vt.getSettings());
                }else{
                    entry.result='no-video-track';
                }
                entry.wasSuccessful=true;
                return stream;
            }).catch(function(err){
                entry.result='error: '+err.name;
                entry.fallbackReason=err.message;
                entry.wasSuccessful=false;
                throw err;
            });
        };
        try{if(s._maskFn)s._maskFn(MediaDevices.prototype.getUserMedia,'getUserMedia',false);}catch(e){}
        }catch(e){}
        })();
        """
    }

    static var constraintLogReadScript: String {
        return """
        (function(){
        var s=window[Symbol.for('fsl')];
        if(!s||!s._constraintLog)return '[]';
        return JSON.stringify(s._constraintLog);
        })();
        """
    }

    static var constraintLogClearScript: String {
        return """
        (function(){
        var s=window[Symbol.for('fsl')];
        if(s)s._constraintLog=[];
        })();
        """
    }

    // MARK: - Private lane viability (Stage 1 check)

    /// Document-start server installed in the app-only isolated content world
    /// (the "private lane") on every page. It does two jobs:
    ///
    /// 1. Marker — sets `self.__fslLane.opened/openedAt` so the Stage 1 probe can
    ///    confirm the lane genuinely opened in this world.
    /// 2. Live delivery server — watches a shared hidden bridge element for a
    ///    build request from the page (written by the Private Lane camera method),
    ///    builds the clean VideoTrackGenerator feed HERE — where the page's CSP
    ///    can't block the worker — parks the resulting MediaStream on a shared
    ///    hidden <video>, and reports success/failure back through the bridge. The
    ///    page reads that <video>'s srcObject to receive the stream across the
    ///    world boundary (the underlying MediaStream is shared through the DOM).
    ///    Inert until the page actually requests a lane feed.
    static var privateLaneBootstrapScript: String {
        return """
        (function(){
        try{var w=self;w.__fslLane=w.__fslLane||{};w.__fslLane.opened=true;if(!w.__fslLane.openedAt)w.__fslLane.openedAt=Date.now();}catch(e){}
        try{
        if(self.__fslLaneServer)return;self.__fslLaneServer=true;
        var BID='__fslLB',active=Object.create(null),seenReq=Object.create(null),seenCancel=Object.create(null);
        // Round 2 sensor realism, mirrored into the private lane (a separate
        // content world) so a lane-carried clean feed gets the same capture-clock
        // timing + grain/PRNU as the in-page feed. Self-contained; any hiccup
        // silently yields the plain frame.
        function _srRng(a){a=a>>>0;if(!a)a=1;return function(){a=a+0x6D2B79F5|0;var t=Math.imul(a^a>>>15,1|a);t=t+Math.imul(t^t>>>7,61|t)^t;return((t^t>>>14)>>>0)/4294967296;};}
        function _srNoise(w,h,rng,amp){var c=document.createElement('canvas');c.width=w;c.height=h;var x=c.getContext('2d');var id=x.createImageData(w,h),d=id.data;for(var i=0;i<d.length;i+=4){var v=128+Math.round((rng()*2-1)*amp);if(v<0)v=0;if(v>255)v=255;d[i]=v;d[i+1]=v;d[i+2]=v;d[i+3]=255;}x.putImageData(id,0,0);return c;}
        function _srBuild(seed,W,H){if(!W||!H||W<2||H<2)return null;var rng=_srRng(seed);var pw=Math.max(2,Math.min(320,Math.round(W/5))),ph=Math.max(2,Math.min(320,Math.round(H/5)));var prnu=_srNoise(pw,ph,rng,12);var pool=[_srNoise(120,120,rng,30),_srNoise(120,120,rng,30),_srNoise(120,120,rng,30)];var out=document.createElement('canvas');out.width=W;out.height=H;var octx=out.getContext('2d');if(!octx)return null;var pats=[];for(var i=0;i<pool.length;i++){try{pats.push(octx.createPattern(pool[i],'repeat'));}catch(e){pats.push(null);}}var gi=0;function render(src){octx.globalCompositeOperation='source-over';octx.globalAlpha=1;octx.drawImage(src,0,0,W,H);octx.globalCompositeOperation='overlay';octx.globalAlpha=0.05;octx.drawImage(prnu,0,0,W,H);var pat=pats[gi%pats.length];gi++;if(pat){var dx=Math.floor(Math.random()*120),dy=Math.floor(Math.random()*120);octx.globalAlpha=0.06;octx.save();octx.translate(-dx,-dy);octx.fillStyle=pat;octx.fillRect(dx,dy,W,H);octx.restore();}octx.globalCompositeOperation='source-over';octx.globalAlpha=1;}return {seed:seed,W:W,H:H,canvas:out,render:render};}
        function _srClock(fps){var ff=fps||30;if(ff<1)ff=1;var base=Math.floor(300000000+Math.random()*1200000000);var ideal=base,uni=0,last=-1,started=false,uniStarted=false;return function(rate,realism){var r=rate||ff;if(r<1)r=1;var su=1000000/r;var t;if(realism){if(!started){started=true;}else{ideal+=su;}t=Math.round(ideal+(Math.random()-0.5)*su*0.03);}else{if(!uniStarted){uniStarted=true;uni=0;}else{uni+=Math.round(su);}t=uni;}if(t<=last)t=last+1;last=t;return t;};}
        function wsrc(){return ''
        +'var gen=null,writer=null;'
        +'self.onmessage=function(e){var d=e.data||{};'
        +'if(d.type===\"init\"){try{if(typeof VideoTrackGenerator===\"undefined\"){self.postMessage({type:\"error\",message:\"no-videotrackgenerator\"});return;}gen=new VideoTrackGenerator();writer=gen.writable.getWriter();self.postMessage({type:\"track\",track:gen.track},[gen.track]);}catch(err){self.postMessage({type:\"error\",message:String((err&&err.message)||err)});}}'
        +'else if(d.type===\"frame\"){var f=d.frame;if(writer){try{writer.write(f).then(function(){try{f.close();}catch(_){}},function(){try{f.close();}catch(_){}});}catch(_){try{f.close();}catch(__){}}}else{try{f.close();}catch(_){}}}'
        +'else if(d.type===\"stop\"){try{if(writer)writer.close();}catch(_){}try{self.close();}catch(_){}}};';}
        function readQ(el,attr){var arr=null;try{var raw=el.getAttribute(attr);if(raw)arr=JSON.parse(raw);}catch(e){return[];}return Array.isArray(arr)?arr:[];}
        function respond(b,tok,ok,reason){
        var arr=readQ(b,'data-a');arr.push({token:tok,ok:!!ok,reason:reason||''});
        if(arr.length>16)arr=arr.slice(arr.length-16);
        try{b.setAttribute('data-a',JSON.stringify(arr));}catch(e){}
        }
        // Each in-flight build is keyed by its own token, so a request for one
        // camera side can never retire or overwrite a still-running build for the
        // other side — two overlapping checks are tracked fully independently.
        function retire(tok){
        var c=active[tok];if(!c)return;delete active[tok];
        try{if(c.pumpT)clearTimeout(c.pumpT);}catch(e){}
        try{if(c.worker)c.worker.postMessage({type:'stop'});}catch(e){}
        try{if(c.worker)c.worker.terminate();}catch(e){}
        try{if(c.url)URL.revokeObjectURL(c.url);}catch(e){}
        try{if(c.srcUrl)URL.revokeObjectURL(c.srcUrl);}catch(e){}
        try{if(c.svideo){c.svideo.pause();c.svideo.removeAttribute('src');c.svideo.load();if(c.svideo.parentNode)c.svideo.parentNode.removeChild(c.svideo);}}catch(e){}
        try{if(c.outVideo){c.outVideo.pause();c.outVideo.srcObject=null;c.outVideo.removeAttribute('src');c.outVideo.load();if(c.outVideo.parentNode)c.outVideo.parentNode.removeChild(c.outVideo);}}catch(e){}
        }
        function ready(vid,cb){var t=0;var ck=function(){if(vid.videoWidth>0&&vid.videoHeight>0&&vid.readyState>=2){cb();return;}if(t++>40){cb();return;}setTimeout(ck,25);};ck();}
        function build(req,b){
        var tok=req.token;
        if(active[tok])return;
        var vidUrl=req.vid,imgUrl=req.img,W=req.w||1280,H=req.h||720,fps=req.fps||30;
        var seed=req.seed||0,realism=!!req.realism;
        var v=null;
        try{
        v=document.createElement('video');v.id='__fslLV_'+tok;v.muted=true;v.defaultMuted=true;v.playsInline=true;v.setAttribute('playsinline','');v.setAttribute('aria-hidden','true');
        v.style.cssText='position:absolute;left:-9999px;top:-9999px;width:1px;height:1px;opacity:0;pointer-events:none';
        b.appendChild(v);
        }catch(e){respond(b,tok,false,'lane-el');return;}
        var dc=document.createElement('canvas');dc.width=W;dc.height=H;var dctx=dc.getContext('2d');dctx.fillStyle='#000';dctx.fillRect(0,0,W,H);
        var st={worker:null,url:null,srcUrl:null,svideo:null,outVideo:v,pumpT:null,token:tok,track:null};
        active[tok]=st;
        var laneSR=null;try{if(realism)laneSR=_srBuild(seed,W,H);}catch(e){laneSR=null;}
        function srFrame(srcCanvas,ts){if(!laneSR)return new VideoFrame(srcCanvas,{timestamp:ts});try{laneSR.render(srcCanvas);return new VideoFrame(laneSR.canvas,{timestamp:ts});}catch(e){return new VideoFrame(srcCanvas,{timestamp:ts});}}
        function initWorker(){return new Promise(function(res,rej){
        var url=null,worker=null,done=false;
        var to=setTimeout(function(){if(done)return;done=true;try{if(worker)worker.terminate();}catch(e){}try{if(url)URL.revokeObjectURL(url);}catch(e){}rej(new Error('vtg-timeout'));},2500);
        try{url=URL.createObjectURL(new Blob([wsrc()],{type:'text/javascript'}));worker=new Worker(url);}catch(e){clearTimeout(to);if(url){try{URL.revokeObjectURL(url);}catch(_){}}rej(new Error('worker-blocked:'+((e&&e.name)||'')));return;}
        st.worker=worker;st.url=url;
        worker.onmessage=function(ev){var d=ev.data||{};if(d.type==='track'){if(done)return;done=true;clearTimeout(to);res(d.track);}else if(d.type==='error'){if(done)return;done=true;clearTimeout(to);rej(new Error('vtg:'+(d.message||'init')));}};
        worker.onerror=function(){if(done)return;done=true;clearTimeout(to);rej(new Error('vtg-worker-error'));};
        worker.postMessage({type:'init'});
        });}
        function buildSrc(){return new Promise(function(res,rej){
        if(vidUrl){
        fetch(vidUrl).then(function(r){return r.blob();}).then(function(blob){
        var url=URL.createObjectURL(blob);st.srcUrl=url;var dv=document.createElement('video');
        dv.setAttribute('playsinline','');dv.loop=true;dv.muted=true;dv.playsInline=true;dv.src=url;st.svideo=dv;b.appendChild(dv);
        dv.onloadeddata=function(){dv.play().then(function(){ready(dv,function(){
        var draw=function(){var vw=dv.videoWidth||W,vh=dv.videoHeight||H;var sc=Math.max(W/vw,H/vh);var dw=vw*sc,dh=vh*sc;dctx.drawImage(dv,(W-dw)/2,(H-dh)/2,dw,dh);};
        res(function(ts){draw();return srFrame(dc,ts);});
        });}).catch(function(e){rej(e);});};
        dv.onerror=function(){rej(new Error('video-load'));};
        }).catch(function(){rej(new Error('video-fetch'));});
        }else if(imgUrl){
        fetch(imgUrl).then(function(r){return r.blob();}).then(function(bl){
        var fin=function(dr,iw,ih){var draw=function(){var sc=Math.max(W/iw,H/ih);var dw=iw*sc,dh=ih*sc;dctx.drawImage(dr,(W-dw)/2,(H-dh)/2,dw,dh);};draw();res(function(ts){draw();return srFrame(dc,ts);});};
        if(typeof createImageBitmap==='function'){createImageBitmap(bl).then(function(bm){fin(bm,bm.width,bm.height);}).catch(function(){rej(new Error('img-load'));});}
        else{var u=URL.createObjectURL(bl);var im=new Image();im.onload=function(){fin(im,im.naturalWidth,im.naturalHeight);try{URL.revokeObjectURL(u);}catch(_){}};im.onerror=function(){try{URL.revokeObjectURL(u);}catch(_){}rej(new Error('img-load'));};im.src=u;}
        }).catch(function(){rej(new Error('img-fetch'));});
        }else{rej(new Error('no-media'));}
        });}
        var frameFrom=null,track=null;
        buildSrc().then(function(ff){frameFrom=ff;return initWorker();}).then(function(t){
        if(active[tok]!==st){
        // Canceled while this build was still in flight (e.g. an overlapping
        // check on the other camera side finished and this one timed out) —
        // clean up whatever this attempt already created; nothing is
        // listening for it anymore.
        try{if(st.worker){st.worker.postMessage({type:'stop'});st.worker.terminate();}}catch(e){}
        try{if(st.url)URL.revokeObjectURL(st.url);}catch(e){}
        try{if(st.srcUrl)URL.revokeObjectURL(st.srcUrl);}catch(e){}
        try{if(st.svideo){st.svideo.pause();st.svideo.removeAttribute('src');st.svideo.load();if(st.svideo.parentNode)st.svideo.parentNode.removeChild(st.svideo);}}catch(e){}
        try{if(v){v.pause();v.srcObject=null;v.removeAttribute('src');v.load();if(v.parentNode)v.parentNode.removeChild(v);}}catch(e){}
        return;
        }
        track=t;st.track=t;
        try{var tf=frameFrom(0);tf.close();}catch(e){throw new Error('vtg-frame');}
        var stream=new MediaStream([track]);
        try{v.srcObject=stream;}catch(e){}
        var clock=_srClock(fps);
        var pumpErrs=0;
        var pump=function(){
        if(active[tok]!==st)return;
        if(track&&track.readyState==='ended'){respond(b,tok,false,'lane-track-ended');retire(tok);return;}
        try{var f=frameFrom(clock(fps,realism));st.worker.postMessage({type:'frame',frame:f},[f]);pumpErrs=0;}
        catch(e){pumpErrs++;if(pumpErrs>=30){respond(b,tok,false,'lane-frame-fail');retire(tok);return;}}
        st.pumpT=setTimeout(pump,Math.max(4,1000/(fps||30)));
        };
        try{for(var k=0;k<5;k++){var pf=frameFrom(clock(fps,realism));st.worker.postMessage({type:'frame',frame:pf},[pf]);}}catch(e){}
        st.pumpT=setTimeout(pump,Math.max(4,1000/(fps||30)));
        respond(b,tok,true,'');
        }).catch(function(err){
        try{if(st.worker){st.worker.postMessage({type:'stop'});st.worker.terminate();}}catch(e){}
        try{if(st.url)URL.revokeObjectURL(st.url);}catch(e){}
        try{if(st.srcUrl)URL.revokeObjectURL(st.srcUrl);}catch(e){}
        try{if(st.svideo){st.svideo.pause();st.svideo.removeAttribute('src');st.svideo.load();if(st.svideo.parentNode)st.svideo.parentNode.removeChild(st.svideo);}}catch(e){}
        try{if(v){v.pause();v.srcObject=null;v.removeAttribute('src');v.load();if(v.parentNode)v.parentNode.removeChild(v);}}catch(e){}
        if(active[tok]===st)delete active[tok];
        respond(b,tok,false,(err&&err.message)?String(err.message):'lane-fail');
        });
        }
        function onReq(){
        var b=document.getElementById(BID);if(!b)return;
        var arr=readQ(b,'data-q');
        for(var i=0;i<arr.length;i++){
        var req=arr[i];
        if(!req||!req.token||seenReq[req.token])continue;
        seenReq[req.token]=true;
        build(req,b);
        }
        }
        // The page gives up on a build after its own timeout (or a post error) and
        // appends a cancel token here. If that exact build is still running,
        // retire it immediately — otherwise a late success would leave the worker +
        // pump loop alive forever with nothing on the page ever watching it. Every
        // cancel is scoped to its own token, so canceling one check never touches
        // another still-running one.
        function onCancel(){
        var b=document.getElementById(BID);if(!b)return;
        var arr=readQ(b,'data-c');
        for(var i=0;i<arr.length;i++){
        var req=arr[i];
        if(!req||!req.token||seenCancel[req.token])continue;
        seenCancel[req.token]=true;
        retire(req.token);
        }
        }
        function startObs(){
        var root=document.documentElement;
        if(!root){setTimeout(startObs,50);return;}
        try{var mo=new MutationObserver(function(){onReq();onCancel();});mo.observe(root,{attributes:true,attributeFilter:['data-q','data-c'],subtree:true});}catch(e){}
        onReq();
        }
        startObs();
        }catch(e){}
        })();
        """
    }

    /// Body for `callAsyncJavaScript`. Runs the SAME clean-feed engine start the
    /// live feed uses (a Dedicated-Worker-backed VideoTrackGenerator), but as a
    /// self-contained, self-cleaning probe that never touches the page's `fsl`
    /// state or the user's live feed. Returns a JSON string describing whether
    /// the worker started (the security-policy gate), whether a real video track
    /// was produced, and whether the engine accepted real frames. Run this body
    /// in BOTH the page world and the private lane to compare them side by side.
    static var privateLaneProbeBody: String {
        return """
        'use strict';
        var out={ran:true,laneTag:0,capable:false,workerStarted:false,trackProduced:false,frameVerified:false,error:'',ms:0,metaCSP:''};
        function _now(){return (typeof performance!=='undefined'&&performance.now)?performance.now():Date.now();}
        var _t0=_now();
        function _fin(){out.ms=Math.round(_now()-_t0);return JSON.stringify(out);}
        try{
          try{if(self.__fslLane&&self.__fslLane.opened)out.laneTag=self.__fslLane.openedAt||1;}catch(e){}
          try{var _m=document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]')||document.querySelector('meta[http-equiv=\"content-security-policy\"]');if(_m&&_m.content)out.metaCSP=String(_m.content).slice(0,2000);}catch(e){}
          var hasWorker=(typeof Worker!=='undefined');
          var hasVF=(typeof VideoFrame!=='undefined');
          var hasMS=(typeof MediaStream!=='undefined');
          out.capable=hasWorker&&hasVF&&hasMS;
          if(!hasWorker){out.error='no-worker';return _fin();}
          if(!hasVF||!hasMS){out.error='no-webcodecs';return _fin();}

          var workerSrc=''
            +'var gen=null,writer=null,wrote=0;'
            +'self.onmessage=function(e){'
            +'var d=e.data||{};'
            +'if(d.type===\"init\"){try{'
            +'if(typeof VideoTrackGenerator===\"undefined\"){self.postMessage({type:\"error\",message:\"no-videotrackgenerator\"});return;}'
            +'gen=new VideoTrackGenerator();writer=gen.writable.getWriter();'
            +'self.postMessage({type:\"track\",track:gen.track},[gen.track]);'
            +'}catch(err){self.postMessage({type:\"error\",message:String((err&&err.message)||err)});}}'
            +'else if(d.type===\"frame\"){var f=d.frame;if(writer){try{writer.write(f).then(function(){try{f.close();}catch(_){}wrote++;self.postMessage({type:\"wrote\",n:wrote});},function(){try{f.close();}catch(_){}});}catch(_){try{f.close();}catch(__){}}}else{try{f.close();}catch(_){}}}'
            +'else if(d.type===\"stop\"){try{if(writer)writer.close();}catch(_){}try{self.close();}catch(_){}}'
            +'};';

          var url=null,worker=null;
          try{
            url=URL.createObjectURL(new Blob([workerSrc],{type:'text/javascript'}));
            worker=new Worker(url);
            out.workerStarted=true;
          }catch(e){
            out.error='worker-blocked:'+((e&&e.name)||'')+':'+((e&&e.message)||e);
            if(url){try{URL.revokeObjectURL(url);}catch(_){}}
            return _fin();
          }

          var track=await new Promise(function(resolve){
            var settled=false;
            var to=setTimeout(function(){if(!settled){settled=true;resolve(null);}},2200);
            worker.onmessage=function(ev){
              var d=ev.data||{};
              if(d.type==='track'){if(settled)return;settled=true;clearTimeout(to);resolve(d.track||null);}
              else if(d.type==='error'){if(settled)return;settled=true;clearTimeout(to);if(!out.error)out.error='vtg:'+(d.message||'init');resolve(null);}
            };
            worker.onerror=function(ev){if(settled)return;settled=true;clearTimeout(to);if(!out.error)out.error='worker-error:'+((ev&&ev.message)||'');resolve(null);};
            try{worker.postMessage({type:'init'});}catch(e){if(!settled){settled=true;clearTimeout(to);out.error='post-init:'+((e&&e.message)||e);resolve(null);}}
          });

          if(track){
            out.trackProduced=(track.kind==='video'&&track.readyState!=='ended');
            try{
              var stream=new MediaStream([track]);
              out.frameVerified=await new Promise(function(resolve){
                var done=false,timer=null,canvas,ctx;
                try{canvas=document.createElement('canvas');canvas.width=160;canvas.height=120;ctx=canvas.getContext('2d');}catch(e){resolve(false);return;}
                function finish(v){if(done)return;done=true;if(timer){clearInterval(timer);timer=null;}resolve(v);}
                worker.onmessage=function(ev){var d=ev.data||{};if(d.type==='wrote'&&d.n>=1)finish(true);};
                worker.onerror=function(){finish(false);};
                var ts=0,count=0;
                function draw(){try{ctx.fillStyle=(count%2===0)?'#0a84ff':'#30d158';ctx.fillRect(0,0,160,120);}catch(e){}}
                function pump(){
                  if(done)return;
                  if(count>=10){finish(false);return;}
                  try{draw();var f=new VideoFrame(canvas,{timestamp:ts});ts+=33333;worker.postMessage({type:'frame',frame:f},[f]);}catch(e){}
                  count++;
                }
                timer=setInterval(pump,60);pump();
                setTimeout(function(){finish(false);},1500);
              });
              try{stream.getTracks().forEach(function(t){t.stop();});}catch(e){}
            }catch(e){if(!out.error)out.error='stream:'+((e&&e.message)||e);}
          }else if(!out.error){
            out.error='no-track';
          }

          try{worker.postMessage({type:'stop'});}catch(e){}
          try{worker.terminate();}catch(e){}
          if(url){try{URL.revokeObjectURL(url);}catch(e){}}
        }catch(e){
          if(!out.error)out.error='probe:'+((e&&e.message)||e);
        }
        return _fin();
        """
    }

    // MARK: - Engine armed self-check (self-heal)

    /// Verifies the camera-takeover interception is genuinely installed and, if
    /// the engine state loaded but the takeover is missing, re-installs it on the
    /// spot via `_s._arm()`. Returns a JSON status the browser reads to surface an
    /// honest "engine armed / not armed (reason)" indicator. Safe to call any
    /// time — it never disturbs a healthy engine, and self-heals a broken one.
    static var engineArmCheckScript: String {
        return """
        (function(){
        try{
          var s=window[Symbol.for('fsl')];
          if(!s)return JSON.stringify({present:false,armed:false,partial:false,gum:false,active:false,method:'',error:'engine-not-loaded'});
          // Self-heal: re-run arm() when the critical getUserMedia gate OR any
          // supplementary interception piece (device list, srcObject catcher,
          // upload picker, legacy shim) is missing. arm() only installs pieces
          // that aren't already present, so this is safe to call repeatedly and
          // never disturbs a healthy engine — it just restores whatever silently
          // failed to arm, instead of only retrying when the gate itself is gone.
          var p=s._armParts||{};
          if((!p.gum||!p.enumerate||!p.srcObject||!p.picker||!p.legacy)&&typeof s._arm==='function'){try{s._arm();}catch(e){}p=s._armParts||{};}
          // The primary gate (getUserMedia) is what blocks the real camera; a
          // 'partial' arm means that gate is up but a secondary piece couldn't
          // install, so the readout can stay honest instead of a flat green.
          var partial=!!p.gum&&(!p.enumerate||!p.srcObject||!p.picker||!p.legacy);
          return JSON.stringify({present:true,armed:!!s._armed,partial:partial,gum:!!p.gum,enumerate:!!p.enumerate,srcObject:!!p.srcObject,picker:!!p.picker,legacy:!!p.legacy,sdkWrap:!!p.sdkWrap,sdkWrapEnabled:!!s._sdkWrap,sdkWrapMonitor:!!s._sdkWrapMonitor,lastSdkBridge:s._sdkWrapLastBridge||'',capTakePhoto:!!s._sdkWrap_capTakePhoto,capRecordVideo:!!s._sdkWrap_capRecordVideo,msgHandler:!!s._sdkWrap_msgHandler,wvjb:!!s._sdkWrap_wvjb,veriffCtor:!!s._sdkWrap_veriffCtor,veriffFrame:!!s._sdkWrap_veriffFrame,iframeScheme:!!s._sdkWrap_iframeScheme,flutter:!!s._sdkWrap_flutter,titanium:!!s._sdkWrap_titanium,webxr:!!s._sdkWrap_webxr,declEl:!!s._sdkWrap_declEl,active:!!s.a,method:s._method||'',error:s._armError||''});
        }catch(e){return JSON.stringify({present:false,armed:false,gum:false,active:false,method:'',error:'check-failed:'+((e&&e.message)||e)});}
        })();
        """
    }

    // MARK: - Injection inspection

    /// Reader for the drift monitor. Returns the injected stream's recorded
    /// frame-delivery timestamps plus live track shape. Synchronous, but exposed
    /// as a `callAsyncJavaScript` body for a uniform await path.
    static var injectedFrameTimingBody: String {
        return """
        var s=window[Symbol.for('fsl')];
        if(!s)return JSON.stringify({active:false,armed:false,armError:'engine-not-loaded',method:'',width:0,height:0,fps:0,times:[]});
        var w=0,h=0,fps=0;
        try{
          var st=s._st;
          if(st&&st.getVideoTracks){
            var vt=st.getVideoTracks()[0];
            if(vt&&vt.getSettings){var g=vt.getSettings();w=g.width||0;h=g.height||0;fps=g.frameRate||0;}
          }
        }catch(e){}
        var times=(s._ft||[]).slice(-240);
        return JSON.stringify({active:!!s.a,armed:!!s._armed,armError:s._armError||'',method:s._method||'',feed:s._activeFeed||'',lane:s._feedLane||'',intended:s._feedIntended||'',downgraded:!!s._feedDowngraded,reason:s._feedReason||'',engine:s._feedEngine||'',sensorRealism:(s._sensorRealism!==false),srCanvas:!!s._srCanvasFeed,width:w,height:h,fps:fps,times:times});
        """
    }

    // MARK: - Injection inspection

    /// Body for `callAsyncJavaScript`. The inspection routine is async (image
    /// decode, permission queries, createImageBitmap), so it must be awaited;
    /// `evaluateJavaScript` returns nothing for the Promise and the caller then
    /// wrongly reports "Inspection blocked".
    static var injectionInspectionBody: String {
        return """
        'use strict';
        const out={
          url:String(location.href||''),
          title:String(document.title||''),
          userAgent:String(navigator.userAgent||''),
          secureContext:!!window.isSecureContext,
          hasMediaDevices:!!(navigator.mediaDevices&&navigator.mediaDevices.getUserMedia),
          cspText:'',
          policyCameraAllowed:'unknown',
          cameraPermissionState:'unsupported',
          dataImageOK:false,
          dataImageError:'',
          blobImageOK:false,
          blobImageError:'',
          canvasCaptureOK:false,
          canvasCaptureError:'',
          nativeHandoffAttempted:false,
          nativeHandoffLanded:false,
          nativeHandoffFileName:'',
          nativeHandoffFileSize:0,
          nativeHandoffFileType:'',
          nativeHandoffError:'',
          nativeHandoffControl:'',
          nativeHandoffSkipped:'',
          customSchemeFetchName:'',
          customSchemeFetchMessage:'',
          gumLooksNative:false,
          enumerateLooksNative:false,
          gumStringSnippet:'',
          enumerateStringSnippet:'',
          iframeCompareAvailable:false,
          iframeFunctionMismatch:false,
          iframeEvidence:'',
          captureInputCount:0,
          captureInputSummary:'',
          activeTrackSettings:null,
          putImageDataOK:false,
          putImageDataError:'',
          createImageBitmapOK:false,
          createImageBitmapError:''
        };
        function errName(e){return e&&e.name?String(e.name):String(e||'unknown');}
        function errMsg(e){return e&&e.message?String(e.message):'';}
        function nativeLike(fn){
          try{return /\\[native code\\]/.test(Function.prototype.toString.call(fn));}
          catch(e){return false;}
        }
        function snippet(fn){
          try{return Function.prototype.toString.call(fn).slice(0,220);}
          catch(e){return ''+e;}
        }
        try{
          const metas=[].slice.call(document.querySelectorAll('meta[http-equiv]'));
          out.cspText=metas.filter(m=>String(m.getAttribute('http-equiv')||'').toLowerCase()==='content-security-policy').map(m=>m.content||'').join('; ');
        }catch(e){}
        try{
          const pp=document.permissionsPolicy||document.featurePolicy;
          if(pp&&typeof pp.allowsFeature==='function')out.policyCameraAllowed=String(pp.allowsFeature('camera'));
        }catch(e){out.policyCameraAllowed='error:'+errName(e);}
        try{
          const pc=document.createElement('canvas');
          pc.width=4;pc.height=3;
          const pctx=pc.getContext('2d');
          if(pctx&&typeof pctx.putImageData==='function'){
            const testID=new ImageData(new Uint8ClampedArray([255,0,0,255,0,255,0,255,0,0,255,255,255,255,0,255,0,255,255,255,255,0,255,255,128,128,128,255,0,0,0,255,32,64,128,255,200,200,200,255,64,128,32,255,255,255,255,255]),4,3);
            pctx.putImageData(testID,0,0);
            const check=pctx.getImageData(0,0,1,1);
            out.putImageDataOK=check&&check.data[0]===255&&check.data[1]===0&&check.data[2]===0;
          }else{
            out.putImageDataError='putImageData or ImageData is not available';
          }
        }catch(e){out.putImageDataError=errName(e)+': '+errMsg(e);}
        try{
          if(typeof createImageBitmap==='function'){
            // A REAL, complete JPEG produced by the page itself. The previous
            // 4-byte header fragment is not a decodable image, so this check could
            // only ever fail — reporting a blocker that did not exist.
            const tc=document.createElement('canvas');
            tc.width=1;tc.height=1;
            const tctx=tc.getContext('2d');
            if(tctx){tctx.fillStyle='#3a7bd5';tctx.fillRect(0,0,1,1);}
            const testB64=String(tc.toDataURL('image/jpeg')).split(',')[1]||'';
            const testBin=atob(testB64);
            const testBytes=new Uint8Array(testBin.length);
            for(let i=0;i<testBin.length;i++)testBytes[i]=testBin.charCodeAt(i);
            const testBlob=new Blob([testBytes],{type:'image/jpeg'});
            const bmp=await createImageBitmap(testBlob);
            out.createImageBitmapOK=!!bmp&&bmp.width>0;
            try{bmp.close();}catch(e){}
          }else{
            out.createImageBitmapError='createImageBitmap is not available';
          }
        }catch(e){out.createImageBitmapError=errName(e)+': '+errMsg(e);}
        try{
          if(navigator.permissions&&navigator.permissions.query){
            const st=await navigator.permissions.query({name:'camera'});
            out.cameraPermissionState=String(st.state||'unknown');
          }
        }catch(e){out.cameraPermissionState='error:'+errName(e);}
        async function testImage(src,kind){
          return await new Promise(resolve=>{
            try{
              const img=new Image();
              const timer=setTimeout(()=>resolve({ok:false,error:'timeout'}),1500);
              img.onload=function(){
                clearTimeout(timer);
                try{
                  const c=document.createElement('canvas');
                  c.width=2;c.height=2;
                  const ctx=c.getContext('2d');
                  ctx.drawImage(img,0,0,2,2);
                  ctx.getImageData(0,0,1,1);
                  resolve({ok:true,error:''});
                }catch(e){resolve({ok:false,error:kind+' draw '+errName(e)+': '+errMsg(e)});}
              };
              img.onerror=function(e){clearTimeout(timer);resolve({ok:false,error:kind+' load error'});};
              img.src=src;
            }catch(e){resolve({ok:false,error:kind+' '+errName(e)+': '+errMsg(e)});}
          });
        }
        try{
          const dataRes=await testImage('data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%222%22 height=%222%22%3E%3Crect width=%222%22 height=%222%22 fill=%22%2300ff00%22/%3E%3C/svg%3E','data');
          out.dataImageOK=!!dataRes.ok; out.dataImageError=dataRes.error||'';
        }catch(e){out.dataImageError=errName(e)+': '+errMsg(e);}
        try{
          const blob=new Blob(['<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><rect width="2" height="2" fill="#00ff00"/></svg>'],{type:'image/svg+xml'});
          const url=URL.createObjectURL(blob);
          const blobRes=await testImage(url,'blob');
          URL.revokeObjectURL(url);
          out.blobImageOK=!!blobRes.ok; out.blobImageError=blobRes.error||'';
        }catch(e){out.blobImageError=errName(e)+': '+errMsg(e);}
        try{
          const c=document.createElement('canvas');
          c.width=16;c.height=9;
          const ctx=c.getContext('2d');
          ctx.fillStyle='#111';ctx.fillRect(0,0,16,9);
          if(typeof c.captureStream==='function'){
            const st=c.captureStream(30);
            const vt=st.getVideoTracks()[0];
            out.canvasCaptureOK=!!vt;
            if(vt&&vt.getSettings)out.activeTrackSettings=vt.getSettings();
            try{st.getTracks().forEach(t=>t.stop());}catch(e){}
          }else{
            out.canvasCaptureError='captureStream missing';
          }
        }catch(e){out.canvasCaptureError=errName(e)+': '+errMsg(e);}
        try{
          await fetch('fslimage://__probe__/missing',{cache:'no-store'});
          out.customSchemeFetchName='ok';
        }catch(e){
          out.customSchemeFetchName=errName(e);
          out.customSchemeFetchMessage=errMsg(e);
        }
        try{
          const gum=navigator.mediaDevices&&navigator.mediaDevices.getUserMedia;
          const en=navigator.mediaDevices&&navigator.mediaDevices.enumerateDevices;
          out.gumLooksNative=nativeLike(gum);
          out.enumerateLooksNative=nativeLike(en);
          out.gumStringSnippet=snippet(gum);
          out.enumerateStringSnippet=snippet(en);
        }catch(e){}
        try{
          const iframe=document.createElement('iframe');
          iframe.setAttribute('aria-hidden','true');
          iframe.style.cssText='position:absolute;width:1px;height:1px;left:-9999px;top:-9999px;border:0;opacity:0;pointer-events:none;';
          document.documentElement.appendChild(iframe);
          await new Promise(r=>setTimeout(r,40));
          const cw=iframe.contentWindow;
          if(cw&&cw.navigator&&cw.navigator.mediaDevices){
            out.iframeCompareAvailable=true;
            const a=snippet(navigator.mediaDevices.getUserMedia);
            const b=snippet(cw.navigator.mediaDevices.getUserMedia);
            out.iframeFunctionMismatch=a!==b;
            out.iframeEvidence=out.iframeFunctionMismatch?'main and same-origin frame function strings differ':'main and same-origin frame function strings match';
          }
          iframe.remove();
        }catch(e){out.iframeEvidence=errName(e)+': '+errMsg(e);}
        try{
          const inputs=[].slice.call(document.querySelectorAll('input[type="file"][capture],input[type="file"][accept*="image"],input[type="file"][accept*="video"]'));
          out.captureInputCount=inputs.length;
          out.captureInputSummary=inputs.slice(0,5).map(i=>'accept='+(i.getAttribute('accept')||'')+', capture='+(i.getAttribute('capture')||'')).join(' | ');
        }catch(e){}
        // Native hand-off probe: use a detached, app-created input only. Never
        // click or rewrite a site's control during inspection: even restoring its
        // FileList cannot undo an upload listener, navigation, or form mutation.
        try{
          const st=window[Symbol.for('fsl')];
          if(st&&st._pkBusy){
            out.nativeHandoffSkipped='a real camera hand-off was already in flight';
          }else if(st&&st._askOn){
            out.nativeHandoffSkipped='ask-me-every-request is on, so a test click would raise a prompt';
          }else if(st&&st.a&&st.seq&&st.seq.length){
            const savedPtr=st._pkPtr,savedHeld=st._held,savedHeldN=st._heldNative,savedLast=st._pkLast;
            try{
              st._probeMode=true;st._probeUntil=Date.now()+15000;st._pkBusy=false;st._pkLast=0;
              const target=document.createElement('input');
              target.type='file';
              target.accept='image/*';
              target.setAttribute('capture','environment');
              out.nativeHandoffControl='app-fixture';
              out.nativeHandoffAttempted=true;
              try{target.click();}catch(e){out.nativeHandoffError=errName(e)+': '+errMsg(e);}
              const deadline=Date.now()+3000;
              while(Date.now()<deadline){
                await new Promise(r=>setTimeout(r,60));
                let files=null;
                try{const d=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'files');files=d&&d.get?d.get.call(target):null;}catch(e){}
                if(files&&files.length>0){
                  out.nativeHandoffLanded=true;
                  out.nativeHandoffFileName=files[0].name||'';
                  out.nativeHandoffFileSize=files[0].size||0;
                  out.nativeHandoffFileType=files[0].type||'';
                  break;
                }
              }
            }finally{
              st._probeMode=false;st._probeUntil=0;st._pkBusy=false;
              st._pkPtr=savedPtr;st._held=savedHeld;st._heldNative=savedHeldN;st._pkLast=savedLast;
            }
          }else{
            out.nativeHandoffSkipped='no active app media sequence is available';
          }
        }catch(e){
          out.nativeHandoffError=errName(e)+': '+errMsg(e);
          try{const st2=window[Symbol.for('fsl')];if(st2){st2._probeMode=false;st2._probeUntil=0;st2._pkBusy=false;}}catch(e2){}
        }
        try{
          const s=window[Symbol.for('fsl')];
          if(s&&s._st&&s._st.getVideoTracks){
            const vt=s._st.getVideoTracks()[0];
            if(vt&&vt.getSettings)out.activeTrackSettings=vt.getSettings();
          }
        }catch(e){}
        return JSON.stringify(out);
        """
    }

    // MARK: - Network backend defuse layer

    /// Injected at document start when either Network Backend switch is active.
    /// The substantive script blocking is handled by the compiled content rule
    /// list; the rewrite proxy is handled at the web-view data-store level. This
    /// companion layer only marks which backend tools are on, strips integrity
    /// locks, and re-asserts native-code masks before late detector code runs.
    static func networkBackendDefuseScript(options: NetworkBackendOptions) -> String {
        let filterEnabled = options.blockDetectionScripts ? "true" : "false"
        let rewriteEnabled = options.useRewriteProxy ? "true" : "false"
        return """
        (function(){
        'use strict';
        try{
          var s=window[Symbol.for('fsl')];
          if(!s)return;
          s._netFilter=\(filterEnabled);
          s._netRewrite=\(rewriteEnabled);
          s._networkBackend={blockDetectionScripts:\(filterEnabled),rewriteProxy:\(rewriteEnabled)};
          // Re-assert toString masks for the camera surface so late detector
          // script still sees native code even when only the proxy switch is on.
          try{
            if(s._maskFn&&navigator.mediaDevices){
              s._maskFn(MediaDevices.prototype.getUserMedia,'getUserMedia',false);
              s._maskFn(MediaDevices.prototype.enumerateDevices,'enumerateDevices',false);
            }
          }catch(e){}
          // Strip Subresource Integrity locks so blocked/replaced/rewrite-touched
          // resources are not rejected for a hash mismatch. Runs at document start
          // and watches for nodes inserted later. Best-effort: parser-inserted
          // scripts may already be in flight, but most dynamic detector loaders
          // insert their <script>/<link> after this point.
          try{
            var _stripSRI=function(el){try{if(el&&el.nodeType===1&&(el.tagName==='SCRIPT'||el.tagName==='LINK')&&el.hasAttribute('integrity'))el.removeAttribute('integrity');}catch(e){}};
            if(typeof MutationObserver!=='undefined'){
              var _sriMO=new MutationObserver(function(muts){
                for(var i=0;i<muts.length;i++){var an=muts[i].addedNodes;for(var j=0;j<an.length;j++)_stripSRI(an[j]);}
              });
              _sriMO.observe(document.documentElement||document,{childList:true,subtree:true});
            }
            var _sriExisting=document.querySelectorAll?document.querySelectorAll('script[integrity],link[integrity]'):[];
            for(var _k=0;_k<_sriExisting.length;_k++)_stripSRI(_sriExisting[_k]);
          }catch(e){}
          // Neutralize a few common automation/fingerprint tells the blocked
          // scripts would otherwise probe for.
          try{Object.defineProperty(navigator,'webdriver',{get:function(){return false;},configurable:true});}catch(e){}
        }catch(e){}
        })();
        """
    }

    /// Compatibility wrapper for any older caller still expecting the original
    /// Network Filter companion script.
    static var networkFilterDefuseScript: String {
        networkBackendDefuseScript(options: NetworkBackendOptions(blockDetectionScripts: true))
    }

    // MARK: - Detector self-test

    /// Body for `callAsyncJavaScript`. Runs the same tricks detection sites use
    /// against whatever injection method is currently live in the page and
    /// returns a per-check pass/fail plus an overall score. Static checks run
    /// always; live-stream checks require an active injected stream.
    static var detectorSelfTestBody: String {
        return """
        'use strict';
        const out={active:false,method:'',score:0,checks:[]};
        function add(id,title,status,detail){out.checks.push({id:id,title:title,status:status,detail:detail||''});}
        function nativeLike(fn){try{return /\\[native code\\]/.test(Function.prototype.toString.call(fn));}catch(e){return false;}}
        function reasonText(code){
          if(code==='device-unsupported')return "this browser lacks the iOS 18+ background feed";
          if(code==='site-blocked-worker')return "the site's security rules blocked the background feed";
          if(code==='media-load')return "your media couldn't be loaded into the clean feed";
          if(code==='no-frames')return "the clean feed delivered no real frames in time";
          return "the clean feed couldn't start";
        }
        const s=window[Symbol.for('fsl')];
        out.method=(s&&s._method)||'';
        const md=navigator.mediaDevices;
        try{
          const gum=md&&md.getUserMedia,en=md&&md.enumerateDevices;
          const gN=nativeLike(gum),eN=nativeLike(en);
          add('apiNative','Camera functions look native',(gN&&eN)?'pass':'fail',(gN?'getUserMedia native':'getUserMedia wrapped')+' · '+(eN?'enumerateDevices native':'enumerateDevices wrapped'));
        }catch(e){add('apiNative','Camera functions look native','fail',''+e);}
        let firstId='',firstLabel='',camCount=0;
        try{
          const d1=await md.enumerateDevices();
          const cams=d1.filter(x=>x.kind==='videoinput');
          camCount=cams.length;
          if(cams[0]){firstId=cams[0].deviceId;firstLabel=cams[0].label;}
          const ok=cams.length>0&&!!firstId&&!!firstLabel;
          add('deviceList','Device list stays consistent',ok?'pass':'warn',cams.length+' camera(s)'+(firstLabel?' · '+firstLabel:''));
        }catch(e){add('deviceList','Device list stays consistent','fail',''+e);}
        try{
          const d2=await md.enumerateDevices();
          const c2=d2.filter(x=>x.kind==='videoinput')[0];
          const stable=!!c2&&c2.deviceId===firstId&&c2.label===firstLabel;
          add('identityStable','Camera identity holds steady',stable?'pass':(camCount?'fail':'warn'),stable?'IDs identical across repeated checks':'IDs shifted between checks');
        }catch(e){add('identityStable','Camera identity holds steady','fail',''+e);}
        try{
          const da=await md.enumerateDevices();
          const m1=da.filter(x=>x.kind==='audioinput')[0];
          const db=await md.enumerateDevices();
          const m2=db.filter(x=>x.kind==='audioinput')[0];
          if(m1&&m2){
            const ok=!!m1.deviceId&&m1.deviceId===m2.deviceId&&m1.label===m2.label;
            add('micStable','Microphone identity holds steady',ok?'pass':'warn',m1.label?('mic: '+m1.label):'microphone present');
          }else{
            add('micStable','Microphone identity holds steady','skip','no microphone enumerated');
          }
        }catch(e){add('micStable','Microphone identity holds steady','fail',''+e);}
        try{
          const dl=await md.enumerateDevices();
          const cam=dl.filter(x=>x.kind==='videoinput')[0];
          if(cam){
            const own=Object.getOwnPropertyNames(cam);
            const ok=own.length===0;
            add('deviceTells','Device list carries no tells',ok?'pass':'warn',ok?'camera entries expose no own properties, like a real device':('own properties present: '+own.join(',')));
          }else{
            add('deviceTells','Device list carries no tells','skip','no camera enumerated');
          }
        }catch(e){add('deviceTells','Device list carries no tells','fail',''+e);}
        const active=!!(s&&s.a&&s.seq&&s.seq.length&&s._method!=='passthrough');
        out.active=active;
        if(!active){
          add('streamShape','Stream shape stays consistent','skip','Turn on Enable Media with a step to test the live feed');
          add('nativeHandoff','Camera handoff looks native','skip','Needs an active injected stream');
          add('resolution','Resolution changes are honored','skip','Needs an active injected stream');
          add('timing','Feed timing looks real','skip','Needs an active injected stream');
        }else{
          let stream=null,track=null;
          // Snapshot the live sequence position so a diagnostic run never advances
          // or perturbs the user's actual progress when it opens the feed.
          const _snap={pHead:s.pHead,held:s._held,heldLive:s._heldLive,heldNative:s._heldNative};
          try{stream=await md.getUserMedia({video:true});track=stream.getVideoTracks()[0];}
          catch(e){add('streamShape','Stream shape stays consistent','fail','getUserMedia failed: '+e);}
          if(track){
            try{const g=track.getSettings();const ok=!!g&&g.width>0&&g.height>0&&g.frameRate>0&&!!g.deviceId;add('streamShape','Stream shape stays consistent',ok?'pass':'fail',g?(g.width+'×'+g.height+' @'+Math.round(g.frameRate)+'fps'):'no settings');}catch(e){add('streamShape','Stream shape stays consistent','fail',''+e);}
            try{
              const tm=['getSettings','getCapabilities','getConstraints','applyConstraints'];
              let ownAny=false,protoAll=true;const offenders=[];
              for(const m of tm){
                if(Object.prototype.hasOwnProperty.call(track,m)){ownAny=true;offenders.push(m);}
                if(track[m]!==MediaStreamTrack.prototype[m])protoAll=false;
              }
              const ok=(!ownAny&&protoAll);
              add('nativeHandoff','Camera handoff looks native',ok?'pass':'warn',ok?'all track info methods live on the prototype like a real camera':('track carries own-property overrides: '+(offenders.join(',')||'method differs from prototype')));
            }catch(e){add('nativeHandoff','Camera handoff looks native','fail',''+e);}
            try{
              const before=track.getSettings();
              const tgtW=(before.width>=1280)?640:1280,tgtH=(before.height>=720)?480:720;
              await track.applyConstraints({width:{ideal:tgtW},height:{ideal:tgtH}});
              await new Promise(r=>setTimeout(r,140));
              const after=track.getSettings();
              const changed=(Math.abs(after.width-tgtW)<=2&&Math.abs(after.height-tgtH)<=2)||(after.width!==before.width||after.height!==before.height);
              add('resolution','Resolution changes are honored',changed?'pass':'fail','asked '+tgtW+'×'+tgtH+', got '+after.width+'×'+after.height);
            }catch(e){add('resolution','Resolution changes are honored','fail',''+e);}
            try{
              const v=document.createElement('video');v.muted=true;v.playsInline=true;v.srcObject=stream;
              try{await v.play();}catch(e){}
              const claimed=track.getSettings().frameRate||30;
              let count=0,first=0,last=0;
              await new Promise(res=>{
                let done=false;
                const cb=(now)=>{count++;if(!first)first=now;last=now;if(count>=24||(last-first)>900){done=true;return res();}if(typeof v.requestVideoFrameCallback==='function')v.requestVideoFrameCallback(cb);};
                if(typeof v.requestVideoFrameCallback==='function'){v.requestVideoFrameCallback(cb);}else{res();}
                setTimeout(()=>{if(!done)res();},1400);
              });
              try{v.srcObject=null;}catch(e){}
              if(count>=5&&last>first){
                const meas=(count-1)*1000/(last-first);
                const ratio=meas/claimed;
                const ok=ratio>0.7&&ratio<1.3;
                add('timing','Feed timing looks real',ok?'pass':'warn','measured '+meas.toFixed(1)+'fps vs claimed '+Math.round(claimed)+'fps');
              }else{
                add('timing','Feed timing looks real','skip','not enough frames sampled');
              }
            }catch(e){add('timing','Feed timing looks real','fail',''+e);}
            try{
              const feed=s&&s._activeFeed;
              const reason=(s&&s._feedReason)||'';
              const isVTG=(out.method==='videoDirect'||out.method==='rawFramePipe'||out.method==='privateLane');
              if(isVTG){
                if(feed==='vtg'){
                  const lane=(s&&s._feedLane)||'';
                  const fallback=(out.method==='privateLane'&&lane!=='private');
                  add('feedEngine','Feed engine matches the method',fallback?'warn':'pass',fallback?'private lane refused this page, but the clean in-page track engaged':'clean worker track (VideoTrackGenerator) engaged'+(lane==='private'?' through the private lane':''));
                }else if(reason==='photo-step'){
                  add('feedEngine','Feed engine matches the method','pass','still photo under Video Direct intentionally uses the Canvas draw (no video to stream)');
                }else if(feed==='canvas'){
                  add('feedEngine','Feed engine matches the method','warn','downgraded to Canvas — '+reasonText(reason));
                }else{
                  add('feedEngine','Feed engine matches the method','fail','no feed engine recorded');
                }
              }else{
                add('feedEngine','Feed engine',feed?'pass':'skip',feed==='canvas'?'Canvas feed (the engine for this method)':(feed==='vtg'?'clean worker track engaged':'no feed engine recorded'));
              }
            }catch(e){add('feedEngine','Feed engine','fail',''+e);}
          }
          try{if(stream)stream.getTracks().forEach(t=>t.stop());}catch(e){}
          // Restore the snapshotted position and push it back to native so the
          // self-test leaves the live sequence exactly where it found it.
          try{
            s.pHead=_snap.pHead;s._held=_snap.held;s._heldLive=_snap.heldLive;s._heldNative=_snap.heldNative;
            if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.fslSeq){
              window.webkit.messageHandlers.fslSeq.postMessage({action:'progressSync',id:(_snap.held&&_snap.held.id)?_snap.held.id:'',ptr:s.pHead,method:s._method||''});
            }
          }catch(e){}
        }
        const applic=out.checks.filter(c=>c.status!=='skip');
        const passed=applic.filter(c=>c.status==='pass').length;
        out.score=applic.length?Math.round(passed*100/applic.length):0;
        return JSON.stringify(out);
        """
    }

    // MARK: - Step 1 native WebRTC delivery client

    static var nativeWebRTCClientScript: String {
        return """
        (function(){
        'use strict';
        if(window.__fslNativeRTCStep1)return;
        var handler=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.fslNativeRTC;
        if(!handler||typeof handler.postMessage!=='function')return;
        var peers=Object.create(null);
        function id(){try{if(crypto&&typeof crypto.randomUUID==='function')return crypto.randomUUID();}catch(e){}return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,function(c){var r=Math.random()*16|0,v=c==='x'?r:(r&3|8);return v.toString(16);});}
        function parseReply(value){
          if(typeof value==='string'){try{return JSON.parse(value);}catch(e){throw new Error('Native WebRTC bridge returned invalid JSON.');}}
          if(value&&typeof value==='object')return value;
          throw new Error('Native WebRTC bridge returned no result.');
        }
        async function call(payload){
          var result=await handler.postMessage(payload),parsed=parseReply(result);
          if(parsed.ok===false)throw new Error(parsed.error||'Native WebRTC request failed.');
          return parsed;
        }
        function normalize(raw){
          raw=raw||{};var v=raw.video||{};
          return {
            wantsVideo:raw.video!==false,
            wantsAudio:!!raw.audio,
            facingMode:String(v.facingMode&&v.facingMode.exact||v.facingMode&&v.facingMode.ideal||v.facingMode||'unspecified'),
            width:Number(v.width&&v.width.exact||v.width&&v.width.ideal||v.width||0)||0,
            height:Number(v.height&&v.height.exact||v.height&&v.height.ideal||v.height||0)||0,
            frameRate:Number(v.frameRate&&v.frameRate.exact||v.frameRate&&v.frameRate.ideal||v.frameRate||0)||0,
            audioPolicy:String(raw.audioPolicy||'compatibilitySilentFallback'),
            rawSampleMode:String(raw.rawSampleMode||'off'),
            rawSampleInterval:Number(raw.rawSampleInterval||1)
          };
        }
        function makeSilentAudio(entry){
          var AC=window.AudioContext||window.webkitAudioContext;if(!AC)throw new Error('Silent audio fallback is unavailable.');
          var ac=new AC(),osc=ac.createOscillator(),gain=ac.createGain(),dest=ac.createMediaStreamDestination();
          gain.gain.value=0;osc.connect(gain);gain.connect(dest);osc.start();
          var track=dest.stream.getAudioTracks()[0];if(!track)throw new Error('Silent audio fallback produced no track.');
          entry.silentAudio={context:ac,oscillator:osc,track:track};return track;
        }
        function maybeResolve(requestId,entry,timeout){
          if(entry.settled||!entry.stream.getVideoTracks().length)return;
          if(entry.wantsAudio&&!entry.stream.getAudioTracks().length)return;
          entry.settled=true;clearTimeout(timeout);call({action:'active',requestId:requestId}).catch(function(){});entry.resolve(entry.stream);
        }
        function queuePageCandidate(requestId,entry,payload,timeout){
          entry.candidateChain=entry.candidateChain.then(function(){return call(payload);});
          entry.candidateChain.catch(function(error){
            entry.candidateError=error;
            if(!entry.settled){entry.settled=true;clearTimeout(timeout);entry.reject(new DOMException('Native ICE candidate failed: '+String((error&&error.message)||error),'NotReadableError'));}
            stop(requestId);
          });
          return entry.candidateChain;
        }
        async function start(raw){
          raw=raw||{};var requestId=String(raw.requestId||id()),constraints=normalize(raw.constraints||raw);
          if(peers[requestId])throw new Error('Native WebRTC request already exists.');
          var pc=new RTCPeerConnection({iceServers:[]});
          var entry={pc:pc,stream:new MediaStream(),pending:[],localCandidates:[],candidateChain:Promise.resolve(),candidateError:null,answerApplied:false,settled:false,wantsAudio:!!constraints.wantsAudio,audioOutcome:{kind:constraints.wantsAudio?'unavailable':'notRequested'}};peers[requestId]=entry;
          try{entry.stream.addEventListener('inactive',function(){stop(requestId);},{once:true});}catch(e){}
          var trackReady=new Promise(function(resolve,reject){entry.resolve=resolve;entry.reject=reject;});
          var timeout=setTimeout(function(){if(!entry.settled){entry.settled=true;entry.reject(new DOMException('Native media timed out.','NotReadableError'));stop(requestId);}},Number(raw.timeoutMs||20000));
          pc.ontrack=function(ev){
            var tracks=ev.streams&&ev.streams[0]?ev.streams[0].getTracks():[ev.track];
            tracks.forEach(function(track){
              if(!entry.stream.getTracks().some(function(t){return t.id===track.id;})){
                try{var nativeStop=track.stop.bind(track);track.stop=function(){try{nativeStop();}finally{stop(requestId);}};}catch(e){}
                entry.stream.addTrack(track);
              }
            });
            maybeResolve(requestId,entry,timeout);
          };
          pc.onicecandidate=function(ev){
            if(!ev.candidate)return;
            var payload={action:'candidate',requestId:requestId,candidate:{sdp:ev.candidate.candidate,sdpMLineIndex:ev.candidate.sdpMLineIndex||0,sdpMid:ev.candidate.sdpMid||null}};
            if(!entry.answerApplied){entry.localCandidates.push(payload);return;}
            queuePageCandidate(requestId,entry,payload,timeout);
          };
          pc.onconnectionstatechange=function(){var state=pc.connectionState;if(state==='failed'||state==='closed'){if(!entry.settled){entry.settled=true;clearTimeout(timeout);entry.reject(new DOMException('Native peer '+state+'.','NotReadableError'));}if(state==='closed')delete peers[requestId];}};
          try{
            var started=await call({action:'start',requestId:requestId,constraints:constraints});
            if(!started.offer||!started.offer.sdp)throw new Error('Native WebRTC offer was missing.');
            entry.audioOutcome=started.audioOutcome||entry.audioOutcome;
            if(entry.wantsAudio&&entry.audioOutcome.kind==='silentFallback')entry.stream.addTrack(makeSilentAudio(entry));
            try{Object.defineProperty(entry.stream,'__fslAudioOutcome',{value:entry.audioOutcome,enumerable:false});}catch(e){}
            try{Object.defineProperty(entry.stream,'__fslNativeRequestId',{value:requestId,enumerable:false});}catch(e){}
            await pc.setRemoteDescription(started.offer);
            for(var i=0;i<entry.pending.length;i++)await pc.addIceCandidate(entry.pending[i]);entry.pending=[];
            var answer=await pc.createAnswer();await pc.setLocalDescription(answer);
            await call({action:'answer',requestId:requestId,answer:{type:answer.type,sdp:answer.sdp}});
            entry.answerApplied=true;
            var buffered=entry.localCandidates.splice(0);
            for(var ci=0;ci<buffered.length;ci++)queuePageCandidate(requestId,entry,buffered[ci],timeout);
            await entry.candidateChain;
            if(entry.candidateError)throw entry.candidateError;
            return await trackReady;
          }catch(error){clearTimeout(timeout);if(entry.silentAudio){try{entry.silentAudio.oscillator.stop();}catch(e){}try{entry.silentAudio.context.close();}catch(e){}}try{pc.close();}catch(e){}delete peers[requestId];throw error;}
        }
        async function receiveSignal(event){
          event=event||{};var requestId=String(event.requestID||event.requestId||''),entry=peers[requestId];if(!entry)return false;
          if(event.kind==='localCandidate'&&event.candidate){
            var candidate={candidate:event.candidate.sdp,sdpMLineIndex:event.candidate.sdpMLineIndex||0,sdpMid:event.candidate.sdpMid||null};
            if(entry.pc.remoteDescription)await entry.pc.addIceCandidate(candidate);else entry.pending.push(candidate);
          }
          return true;
        }
        async function stop(requestId){
          requestId=String(requestId||'');var entry=peers[requestId];
          if(entry){delete peers[requestId];try{entry.stream.getTracks().forEach(function(t){t.stop();});}catch(e){}if(entry.silentAudio){try{entry.silentAudio.oscillator.stop();}catch(e){}try{entry.silentAudio.context.close();}catch(e){}}try{entry.pc.close();}catch(e){}}
          try{await call({action:'stop',requestId:requestId});}catch(e){}
        }
        try{window.addEventListener('pagehide',function(){Object.keys(peers).forEach(function(requestId){stop(requestId);});},{capture:true});}catch(e){}
        window.__fslNativeRTCStep1=Object.freeze({start:start,stop:stop,receiveSignal:receiveSignal,activeRequestIDs:function(){return Object.keys(peers);}});
        })();
        """
    }
}
