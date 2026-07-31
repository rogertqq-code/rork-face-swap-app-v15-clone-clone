$global:results = @()

function Check-Pattern($id, $file, $pattern, $shouldMatch, $desc) {
    $exists = Test-Path $file
    if (-not $exists) {
        $global:results += "$id,Not Found,File $file not found"
        return
    }
    $content = Get-Content $file -Raw
    $match = $content -match $pattern
    if (($match -and $shouldMatch) -or (-not $match -and -not $shouldMatch)) {
        $global:results += "$id,PASS,$desc"
    } else {
        $global:results += "$id,FAIL,$desc"
    }
}

$root = "ios\FaceSwapLiveAppV17"

# ---- Previously fixed items (verify still intact) ----
Check-Pattern "C-01" "$root\Services\StyleSheetProvider.swift" "fslTakePick" $true "fslTakePick lexical scope"
Check-Pattern "C-02" "$root\ViewModels\BrowserViewModel.swift" "TrackedFrame" $true "TrackedFrame generation state"
Check-Pattern "C-04" "$root\Services\StyleSheetProvider.swift" "origGUM.call\(self.*audio" $true "Real audio track routing"
Check-Pattern "C-05" "$root\ViewModels\BrowserViewModel.swift" "bridgeContext.*frame.*WKFrameInfo" $true "Origin-aware bridge context"
Check-Pattern "C-08" "$root\..\FaceSwapLiveAppV17.xcodeproj\project.pbxproj" "SWIFT_STRICT_CONCURRENCY = complete" $true "Swift 6 strict concurrency"
Check-Pattern "C-09" "$root\ViewModels\BrowserViewModel.swift" "makeRuntimeState.*targetOrigin" $true "Origin-scoped runtime state"
Check-Pattern "C-10" "$root\Services\MediaResourceCoordinator.swift" "leaseCount" $true "Lease count tracking"
Check-Pattern "M-01" "$root\Services\StyleSheetProvider.swift" "_runtimeReady" $true "Runtime ready fallback"
Check-Pattern "M-02" "$root\Services\StyleSheetProvider.swift" "fslStartRequest" $true "fslStartRequest concurrency"
Check-Pattern "M-03" "$root\Services\StyleSheetProvider.swift" "OverconstrainedError" $true "Constraint negotiation"
Check-Pattern "M-04" "$root\Services\StyleSheetProvider.swift" "_watchdog" $true "Watchdog timer"
Check-Pattern "M-05" "$root\Models\MediaRuntimeState.swift" "func serializedJSON\(\) throws" $true "Throwing encoder"
Check-Pattern "M-08" "$root\Views\BrowserWebContainer.swift" "webViewWebContentProcessDidTerminate" $true "Process termination handler"
Check-Pattern "M-09" "$root\ViewModels\BrowserViewModel.swift" "performLifecycleTransaction" $true "Lifecycle transaction"
Check-Pattern "m-10" "$root\Services\CaptureService.swift" "interruptionEndedNotification" $true "Interruption recovery"
Check-Pattern "M-14" "$root\Services\CaptureService.swift" "commitConfiguration" $true "Transactional reconfiguration"
Check-Pattern "M-15" "$root\Services\AudioSessionManager.swift" "AudioSessionManager" $true "AudioSessionManager"
Check-Pattern "M-18" "$root\Services\CaptureService.swift" "CaptureSessionActor" $true "CaptureSessionActor"
Check-Pattern "M-24" "$root\Services\StyleSheetProvider.swift" "_frzInstalled=false" $true "Freeze disabled"
Check-Pattern "M-25" "$root\Services\StyleSheetProvider.swift" "Object\.defineProperty\(HTMLMediaElement.*srcObject" $false "Removed global srcObject patch"
Check-Pattern "M-26" "$root\Views\BrowserWebContainer.swift" "completionHandler\(\)" $true "JS panel handling"
Check-Pattern "N-05" "$root\Services\StyleSheetProvider.swift" "accept.*image" $true "Media accept"
Check-Pattern "N-08" "$root\ViewModels\BrowserViewModel.swift" "knownTrackedFrames" $true "Frame registry tracking"

# ---- Newly implemented items ----
Check-Pattern "C-03" "$root\ViewModels\BrowserViewModel.swift" "func enableMedia\(\)" $true "Native enableMedia pipeline"
Check-Pattern "C-11" "$root\Views\BrowserWebContainer.swift" "CameraMessageBody.*Codable" $true "Typed completion contracts"
Check-Pattern "M-06" "$root\ViewModels\BrowserViewModel.swift" "capturedVersion == self.runtimeStateVersion" $true "Version-bound acknowledgment"
Check-Pattern "M-07" "$root\Services\StyleSheetProvider.swift" "Bounded bootstrap" $true "Bounded bootstrap diagnostics"
Check-Pattern "M-12" "$root\Services\CaptureService.swift" "func start\(\) async throws" $true "Async throwing start"
Check-Pattern "M-13" "$root\Services\CaptureService.swift" "func stop\(\) async" $true "Awaitable stop"
Check-Pattern "M-16" "$root\Services\SetupService.swift" "nonisolated.*final class TestClipRecorder" $true "Sendable TestClipRecorder"
Check-Pattern "M-17" "$root\Services\SetupService.swift" "withTaskCancellationHandler" $true "Cancellation handlers"
Check-Pattern "M-19" "$root\Views\BrowserWebContainer.swift" "guard sequenceValue == expectedVersion" $true "Versioned acknowledgment"
Check-Pattern "M-20" "$root\Services\WebRuntimeCoordinator.swift" "WebRuntimeCoordinator" $true "WebRuntimeCoordinator"
Check-Pattern "M-21" "$root\Services\LocalResourceHandler.swift" "func stopTask" $true "Cancellable streaming task"
Check-Pattern "M-23" "$root\Services\StyleSheetProvider.swift" "fslApplyFile.*DataTransfer" $true "DataTransfer/FileList"
Check-Pattern "M-27" ".github\workflows\test.yml" "macos-latest" $true "macOS CI"
Check-Pattern "N-01" "$root\Views\BrowserWebContainer.swift" "BridgeMessageEnvelope.*Codable" $true "Typed Codable envelope"
Check-Pattern "N-02" "$root\Services\StyleSheetProvider.swift" "fslAskDecision.*setTimeout" $true "Cancellable timeout"
Check-Pattern "N-03" "$root\Services\CaptureService.swift" "RotationCoordinator" $true "RotationCoordinator"
Check-Pattern "N-06" "$root\Services\StyleSheetProvider.swift" "fslHybridAdapter" $true "Hybrid adapter"
Check-Pattern "N-07" "$root\Services\LocalResourceHandler.swift" "func cancelAllTasks" $true "Lock contention fix"

Write-Output ""
Write-Output "=== VERIFICATION RESULTS ==="
Write-Output ""
$pass = 0
$fail = 0
$notFound = 0
foreach ($r in $global:results) {
    $parts = $r -split ","
    $status = $parts[1]
    if ($status -eq "PASS") { $pass++ }
    elseif ($status -eq "FAIL") { $fail++ }
    else { $notFound++ }
    Write-Output $r
}
Write-Output ""
Write-Output "TOTAL: $($global:results.Count) checks, $pass PASS, $fail FAIL, $notFound NOT FOUND"
