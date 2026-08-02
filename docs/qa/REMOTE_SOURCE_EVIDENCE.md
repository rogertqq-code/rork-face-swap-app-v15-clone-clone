# Final remote source evidence

## Remote main

GitHub API source: https://api.github.com/repos/rogertqq-code/rork-face-swap-app-v15-clone-clone/commits/main

The remote `main` head was observed twice without change at `9ad90f2d4179bbdbd9a6b53ebd0d6d61d583743b`, authored by Rork at 2026-08-01 23:46:51 UTC. The commit message is `Failed: Precondition Failed`; it changes `ios/FaceSwapLiveAppV17/Services/SetupService.swift`.

## Local-versus-remote comparison

GitHub comparison: https://github.com/rogertqq-code/rork-face-swap-app-v15-clone-clone/compare/b57c13c60a9463ba94f035da11505b9d57b36e5f...9ad90f2d4179bbdbd9a6b53ebd0d6d61d583743b

The comparison reports `diverged`, with remote `main` ten commits ahead and six commits behind local `b57c13c`; merge base is `7ae1dc723f6624d61569c0974d1028e062cc0883`.

Key remote changes include Swift 6 concurrency fixes in `CaptureService`, `SetupService`, `NativeWebRTCSession`, `BrowserWebContainer`, `DiagnosticsHarnessWebView`, `WebRuntimeCoordinator`, `BrowserViewModel`, `PreviewViewModel`, `ConnectionLogService`, `NetworkRewriteProxyService`, `MediaAudioPolicyResolver`, `MediaResourceCoordinator`, `AudioSessionManager`, and `Improved_Gatekeeper`.

The remote `CaptureService` removes the unavailable `DispatchQueue.asUnownedSerialExecutor()` custom-executor wiring and replaces it with `CaptureSessionActor.queue`, but still calls `AVCaptureSession.stopRunning()` from that unrelated queue in `deinit`, still schedules the photo timeout on that queue, and still has no idempotent async `shutdown()` lifecycle method. Therefore, the CaptureService prerequisite remains open even on final remote main.

## Current CI and QA scan

The current local workflow already extracts exact Swift-embedded JavaScript, runs syntax and ESLint checks, executes the deterministic media harness, dynamically selects an available simulator, runs Swift 6 complete-concurrency tests, and uploads `.xcresult`.

A repository search found no `QA-Debug`, `QA_AUTOMATION`, `QAFeatureRegistry`, `QASessionManifest`, typed QA command router, Appium, WebDriverAgent, comprehensive accessibility identifiers, `.xctestplan`, `workflow_dispatch`, self-hosted device runner, `devicectl`, or USB lab agent. The current UI test target still contains only launch visibility and launch performance.
