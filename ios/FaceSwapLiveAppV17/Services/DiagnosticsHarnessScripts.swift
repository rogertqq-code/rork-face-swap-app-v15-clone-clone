import Foundation

/// Self-contained HTML + JavaScript for the Diagnostics full-test harness.
///
/// The harness loads `testPageHTML` into a hidden web view given an `https://`
/// base URL so the page is a genuine secure context (where `navigator.media
/// Devices`, Workers, and WebCodecs exist). The injection engine is installed
/// exactly as it is for the real browser, then these probe bodies drive it —
/// requesting the camera, measuring the frames the "site" receives, exercising
/// the file picker, and reading which delivery engine actually ran.
nonisolated enum DiagnosticsHarnessScripts {

    /// The built-in camera test page the app serves to itself. Deliberately tiny:
    /// the probes create whatever elements they need, so this only has to be a
    /// valid secure document with a body to attach to.
    static let testPageHTML: String = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>FSL Camera Test Page</title>
    <style>
      html,body{margin:0;padding:0;background:#0b0b0f;color:#8a8a99;font:12px -apple-system,system-ui,sans-serif;}
      .wrap{padding:8px;}
      video{width:64px;height:48px;background:#000;border-radius:4px;}
      .dot{display:inline-block;width:6px;height:6px;border-radius:3px;background:#30d158;margin-right:5px;}
    </style>
    </head>
    <body>
    <div class="wrap">
      <span class="dot"></span><span id="status">camera test page</span>
      <div><video id="fslTestVideo" autoplay muted playsinline></video></div>
      <input id="fslTestUpload" type="file" accept="image/*,video/*" capture="user" style="opacity:0;position:absolute;left:-9999px">
    </div>
    <script>
      // Readiness marker the harness polls before driving the page.
      window.__fslHarnessReady = true;
    </script>
    </body>
    </html>
    """

    /// Reads the environment the test actually ran in (secure context, WebCodecs
    /// availability, user agent). Synchronous; exposed as an async body for a
    /// uniform await path.
    static var environmentProbeBody: String {
        return """
        var out={secureContext:!!window.isSecureContext,userAgent:String(navigator.userAgent||''),hasMediaDevices:!!(navigator.mediaDevices&&navigator.mediaDevices.getUserMedia),hasWorker:(typeof Worker!=='undefined'),hasVideoFrame:(typeof VideoFrame!=='undefined'),hasVTG:(typeof VideoTrackGenerator!=='undefined'),ready:!!window.__fslHarnessReady,enginePresent:!!window[Symbol.for('fsl')]};
        return JSON.stringify(out);
        """
    }

    /// The core per-method probe. With the sequence + method already pushed by
    /// the harness, it: reads the takeover arm state, calls getUserMedia, measures
    /// the frames the page receives, reads which delivery engine ran, and
    /// exercises the fake file-upload picker. Returns one JSON blob.
    static var fullTestProbeBody: String {
        return """
        'use strict';
        var out={armed:false,armError:'',method:'',gumOK:false,gumError:'',width:0,height:0,fps:0,feed:'',lane:'',downgraded:false,reason:'',framesFlowing:false,measuredFps:0,frameCount:0,pickerOK:false,pickerType:'',pickerSize:0,captureOK:false,captureType:'',captureSize:0,captureName:'',srRealism:false,srCanvas:false};
        function gs(){try{return window[Symbol.for('fsl')];}catch(e){return null;}}
        var s=gs();
        if(!s){out.armError='engine-not-loaded';return JSON.stringify(out);}
        out.method=s._method||'';
        out.armed=!!s._armed;
        out.armError=s._armError||'';
        var md=navigator.mediaDevices;

        function measure(stream){
          return new Promise(function(resolve){
            var v=document.getElementById('__fslProbeVid');
            if(!v){
              v=document.createElement('video');v.id='__fslProbeVid';
              v.muted=true;v.playsInline=true;v.setAttribute('playsinline','');v.setAttribute('muted','');
              v.style.position='fixed';v.style.left='-9999px';v.style.top='0';v.style.width='64px';v.style.height='48px';
              try{document.body.appendChild(v);}catch(e){}
            }
            try{v.srcObject=stream;}catch(e){try{document.body.removeChild(v);}catch(e){}resolve({count:0,fps:0});return;}
            var count=0,first=0,last=0,done=false;
            function finish(){if(done)return;done=true;var fps=(count>=2&&last>first)?((count-1)*1000/(last-first)):0;try{document.body.removeChild(v);}catch(e){}resolve({count:count,fps:fps});}
            try{v.play().then(function(){},function(){});}catch(e){}
            if(typeof v.requestVideoFrameCallback==='function'){
              var cb=function(now,meta){count++;if(!first)first=now;last=now;if(count>=30||(last-first)>900){finish();return;}try{v.requestVideoFrameCallback(cb);}catch(e){finish();}};
              try{v.requestVideoFrameCallback(cb);}catch(e){}
              setTimeout(finish,1400);
            }else{
              var startCT=v.currentTime||0,ticks=0;
              var iv=setInterval(function(){ticks++;if((v.currentTime||0)>startCT+0.04)count=Math.max(count,ticks);if(ticks>=14){clearInterval(iv);first=0;last=count>0?900:0;finish();}},70);
            }
          });
        }

        // Read through WebKit's own `files` getter. A JavaScript-shadowed property
        // could report success for a FileList the browser actually rejected.
        function nativeFiles(el){
          try{
            var d=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'files');
            if(d&&d.get)return d.get.call(el);
          }catch(e){}
          return null;
        }

        // Exercise one file control end to end. `useCapture` mirrors a site's
        // camera button (an input carrying the `capture` attribute), which takes a
        // different path through the engine than an ordinary file pick.
        function pickerTest(useCapture){
          var empty={ok:false,type:'',size:0,name:''};
          return new Promise(function(resolve){
            var inp;
            try{
              inp=document.createElement('input');inp.type='file';inp.accept='image/*,video/*';
              if(useCapture)inp.setAttribute('capture','environment');
              inp.style.position='fixed';inp.style.left='-9999px';document.body.appendChild(inp);
            }catch(e){resolve(empty);return;}
            var settled=false;
            function done(res){if(settled)return;settled=true;try{document.body.removeChild(inp);}catch(e){}resolve(res);}
            try{
              inp.addEventListener('change',function(){
                try{
                  var fl=nativeFiles(inp);var f=fl&&fl.length?fl[0]:null;
                  if(f&&f.size>0){done({ok:true,type:f.type||'',size:f.size||0,name:f.name||''});}
                  else{done(empty);}
                }catch(e){done(empty);}
              });
            }catch(e){}
            // One tap = one serve: clear the per-gesture debounce so a second
            // control in the same run is not swallowed as a duplicate event.
            try{s._pkBusy=false;s._pkLast=0;}catch(e){}
            try{inp.click();}catch(e){}
            // The engine deliberately holds a hand-off for a believable capture
            // window. Probe mode shortens it, and this still allows generous room
            // for the file to be built and land before giving up.
            setTimeout(function(){done(empty);},2500);
          });
        }

        var stream=null;
        try{
          stream=await md.getUserMedia({video:true,audio:false});
          out.gumOK=true;
        }catch(e){
          out.gumError=((e&&e.name)?e.name+': ':'')+((e&&e.message)||e);
        }
        if(stream){
          try{
            var vt=stream.getVideoTracks()[0];
            if(vt&&vt.getSettings){var g=vt.getSettings();out.width=g.width||0;out.height=g.height||0;out.fps=g.frameRate||0;}
          }catch(e){}
          try{var m=await measure(stream);out.frameCount=m.count;out.measuredFps=m.fps;out.framesFlowing=(m.count>=2);}catch(e){}
          out.feed=s._activeFeed||'';
          out.lane=s._feedLane||'';
          out.downgraded=!!s._feedDowngraded;
          out.reason=s._feedReason||'';
          out.srRealism=(s._sensorRealism!==false);
          out.srCanvas=!!s._srCanvasFeed;
          try{stream.getTracks().forEach(function(t){t.stop();});}catch(e){}
        }
        // Probe mode runs the real delivery path without freezing the page,
        // interrupting the live feed, showing the capture screen, or reporting
        // progress that would disturb the user's own queue position.
        var prevProbe=false;
        try{prevProbe=!!s._probeMode;s._probeMode=true;s._probeUntil=Date.now()+15000;}catch(e){}
        try{var pk=await pickerTest(false);out.pickerOK=!!pk.ok;out.pickerType=pk.type||'';out.pickerSize=pk.size||0;}catch(e){}
        try{
          var pc=await pickerTest(true);
          out.captureOK=!!pc.ok;out.captureType=pc.type||'';out.captureSize=pc.size||0;out.captureName=pc.name||'';
        }catch(e){}
        try{s._probeMode=prevProbe;s._probeUntil=prevProbe?(Date.now()+15000):0;s._pkBusy=false;s._pkLast=0;}catch(e){}
        return JSON.stringify(out);
        """
    }

    /// A lighter probe used for Passthrough and block-step checks: just calls
    /// getUserMedia and reports whether it succeeded and whether any virtual feed
    /// engaged. No frame measurement or picker test.
    static var simpleGumProbeBody: String {
        return """
        'use strict';
        var out={method:'',gumOK:false,gumError:'',feed:'',armed:false};
        function gs(){try{return window[Symbol.for('fsl')];}catch(e){return null;}}
        var s=gs();
        if(s){out.method=s._method||'';out.armed=!!s._armed;}
        var stream=null;
        try{stream=await navigator.mediaDevices.getUserMedia({video:true,audio:false});out.gumOK=true;}
        catch(e){out.gumError=((e&&e.name)?e.name+': ':'')+((e&&e.message)||e);}
        try{var s2=gs();out.feed=(s2&&s2._activeFeed)||'';}catch(e){}
        if(stream){try{stream.getTracks().forEach(function(t){t.stop();});}catch(e){}}
        return JSON.stringify(out);
        """
    }

    /// Runs against the LIVE browser web view for Fix Trusted-Browser. Re-reads
    /// the page's browser identity after the Safari identity + fingerprint
    /// stabilization + native-code masks were re-applied, and scores whether the
    /// page now looks like a genuine untouched phone browser.
    static var trustedBrowserCheckScript: String {
        return """
        (function(){
        function nativeLike(fn){try{return /\\[native code\\]/.test(Function.prototype.toString.call(fn));}catch(e){return false;}}
        var out={ua:String(navigator.userAgent||''),secureContext:!!window.isSecureContext,vendor:String(navigator.vendor||''),platform:String(navigator.platform||''),standalone:(typeof navigator.standalone!=='undefined'),maxTouchPoints:(navigator.maxTouchPoints||0),webdriver:!!navigator.webdriver,hasChrome:(typeof window.chrome!=='undefined'),gumNative:false,enumerateNative:false,toStringNative:false};
        try{var md=navigator.mediaDevices;out.gumNative=!!(md&&nativeLike(md.getUserMedia));out.enumerateNative=!!(md&&nativeLike(md.enumerateDevices));}catch(e){}
        try{out.toStringNative=nativeLike(Function.prototype.toString);}catch(e){}
        var isSafariUA=/Safari/.test(out.ua)&&/Version\\//.test(out.ua)&&!/CriOS|FxiOS|EdgiOS|Chrome/.test(out.ua);
        var isApple=/iPhone|iPad|iPod/.test(out.ua)||/iPhone|iPad|iPod|MacIntel/.test(out.platform);
        out.looksSafari=isSafariUA;
        out.looksApple=isApple;
        out.trusted=isSafariUA&&isApple&&out.gumNative&&out.enumerateNative&&out.toStringNative&&!out.webdriver&&!out.hasChrome;
        return JSON.stringify(out);
        })();
        """
    }
}
