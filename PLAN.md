# Separate Front & Back Camera Spoofing

## Features

- **Assign separate videos for front and back camera** — pick one video to serve when a website requests the front camera, and a different video for the back camera
- **Independent controls** — load, clear, and preview front and back sources independently
- **Automatic variant matching** — when selecting a saved video, the front-transcoded version goes to front camera and the back-transcoded version goes to back camera
- **File input capture respects facing** — when a website's "Take Photo" button specifies front or back camera, the correct video is injected
- **Backward compatible** — if only one video is loaded, it serves for both cameras like today

## Design

- The "Camera Controls" sheet gets a new section layout with two media slots: **Front Camera Source** and **Back Camera Source**, each with their own photo/video picker and preview thumbnail
- A quick-load option in Saved Videos lets you tap a video and auto-assign its front-transcoded version to front, and back-transcoded version to back, in one tap
- Active status badges show which cameras have media loaded (green dot for back, cyan dot for front) in the toolbar
- The virtual camera toggle activates both sources simultaneously

## Changes

1. **Video serving** — the video handler will support two separate paths (`fslvideo://front` and `fslvideo://back`) so the browser can fetch different video files for each camera
2. **Camera-aware injection script** — the script that intercepts camera requests will check whether the website asked for "user" (front) or "environment" (back) and serve the matching video source
3. **Browser controls** — the view model tracks two separate video/image sources and conversion states
4. **Overlay sheet** — split into two clear sections for front and back camera media selection
5. **Saved video quick-assign** — one-tap to assign both front and back versions from a saved video

---

# Diagnostics, Fingerprint Stabilization & Advanced Media Tools

## New Features

### Camera & Media Diagnostics
- **Requested vs actual capture report** — Shows the site's requested width, height, frame rate, facing mode, and device ID beside what the app actually delivers
- **Live session diagnostics panel** — Displays active resolution, aspect ratio, fps, color space, orientation, mirroring, HDR state, and stabilization in real time
- **Camera capability snapshot** — Reads and saves each device's supported formats, min/max fps ranges, photo dimensions, video dimensions, and field of view
- **Front/back profile comparison** — Separate saved profiles for front and rear cameras displayed side-by-side for comparison
- **Negotiated constraints log** — Logs every getUserMedia constraint set, the negotiation result, and why a fallback format was chosen
- **Metadata inspector** — Shows video container, codec, bitrate, frame rate, keyframe interval, pixel format, rotation metadata, and audio track details
- **Drift and timing monitor** — Measures real frame cadence over time to spot jitter, duplicate frames, and timing instability
- **Orientation and transform debugger** — Visualizes portrait/landscape transforms, mirroring, clean aperture, crop, and display matrix issues
- **Preview-to-output comparison** — Shows on-screen preview size versus actual encoded frame size
- **Overscan/crop guide overlay** — Debug overlay for safe area, crop area, and visible framing
- **Audio route and microphone profile panel** — Captures current input route, sample rate, channel count, bit depth, echo cancellation state, and audio session mode
- **Color and tone pipeline viewer** — Shows SDR/HDR, color primaries, transfer function, matrix coefficients, full-range vs video-range
- **Lighting and exposure telemetry** — Surfaces ISO, shutter duration, white balance, exposure bias, torch state, and focus mode
- **Media conformance scorer** — "Matches saved camera profile" score based on resolution, fps, codec, bitrate, orientation, and audio settings

### Transcoding Improvements
- **Transcode presets locked to common formats** — Output restricted to 720p30, 1080p30, 1080p60, and 4K30
- **Progress plus phase breakdown** — Transcoding progress split into analysis, audio prep, video encode, muxing, verification, and library save
- **Post-transcode verification pass** — After export, re-reads the file and confirms it matches the intended format

### Browser Fingerprint Stabilization
- **Lock hardwareConcurrency** — Always reports the saved processorCount, never fluctuates
- **Lock screenResolution and screenFrame** — Consistent screen.width, screen.height, and window.screenY/screenTop values
- **Stabilize AudioContext fingerprint** — AudioContext oscillator test always produces the same floating-point number
- **Stabilize Canvas and WebGL fingerprint hashes** — Canvas and WebGL fingerprint tests always produce consistent output
- **Fingerprint consistency self-test panel** — Runs standard fingerprint entropy tests multiple times, flags inconsistencies, shows pass/fail

### Data & Export
- **Exportable debug bundle** — Shareable diagnostics package containing session logs, constraints, settings, and media properties
- **Website compatibility history** — Per-site history showing what constraints were requested, what worked, and which profile succeeded

