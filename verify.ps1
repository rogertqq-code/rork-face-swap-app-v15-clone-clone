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
        $global:results += "$id,Fixed,$desc"
    } else {
        $global:results += "$id,Not Fixed,$desc"
    }
}

Check-Pattern "C-03" "ios\FaceSwapLiveAppV17\ViewModels\BrowserViewModel.swift" "func applyMediaActive" $false "Native enableMedia takeover vs JS"
Check-Pattern "C-11" "ios\FaceSwapLiveAppV17\ViewModels\BrowserViewModel.swift" "func handleCameraMessage.*result" $true "Typed completion contracts"
Check-Pattern "M-05" "ios\FaceSwapLiveAppV17\Models\MediaRuntimeState.swift" "func serializedJSON\(\) throws" $true "Throwing encoder for JSON"
Check-Pattern "M-06" "ios\FaceSwapLiveAppV17\ViewModels\BrowserViewModel.swift" "applyRuntimeState.*version" $true "Bind acknowledgment to version"
Check-Pattern "M-07" "ios\FaceSwapLiveAppV17\Services\StyleSheetProvider.swift" "Bounded bootstrap" $true "Bounded bootstrap retry"
Check-Pattern "M-09" "ios\FaceSwapLiveAppV17\ViewModels\BrowserViewModel.swift" "performLifecycleTransaction" $true "Lifecycle transaction"
Check-Pattern "m-10" "ios\FaceSwapLiveAppV17\Services\CaptureService.swift" "AVCaptureSession.interruptionEndedNotification" $true "Observer-driven recovery"
Check-Pattern "M-12" "ios\FaceSwapLiveAppV17\Services\CaptureService.swift" "func start\(\) async throws" $true "Async throwing start"
Check-Pattern "M-13" "ios\FaceSwapLiveAppV17\Services\CaptureService.swift" "func stop\(\) async" $true "Awaitable stop"
Check-Pattern "M-14" "ios\FaceSwapLiveAppV17\Services\CaptureService.swift" "session.commitConfiguration\(\)" $true "Transactional reconfiguration"
Check-Pattern "M-15" "ios\FaceSwapLiveAppV17\Services\AudioSessionManager.swift" "AudioSessionManager" $true "AudioSessionManager exists"
Check-Pattern "M-16" "ios\FaceSwapLiveAppV17\Services\TestAudioRecorder.swift" "actor TestAudioRecorder" $true "Actor TestAudioRecorder"
Check-Pattern "M-17" "ios\FaceSwapLiveAppV17\Services\SetupService.swift" "withTaskCancellationHandler" $true "withTaskCancellationHandler"
Check-Pattern "M-18" "ios\FaceSwapLiveAppV17\Services\CaptureService.swift" "@CaptureSessionActor" $true "CaptureSessionActor exists"
Check-Pattern "M-19" "ios\FaceSwapLiveAppV17\ViewModels\BrowserViewModel.swift" "guard sequenceVersion ==" $true "Versioned acknowledgment"
Check-Pattern "M-20" "ios\FaceSwapLiveAppV17\ViewModels\BrowserViewModel.swift" "WebRuntimeCoordinator" $true "WebRuntimeCoordinator"
Check-Pattern "M-21" "ios\FaceSwapLiveAppV17\Services\LocalResourceHandler.swift" "func stopTask" $true "Cancellable streaming task"
Check-Pattern "M-23" "ios\FaceSwapLiveAppV17\Services\StyleSheetProvider.swift" "fslApplyFile.*DataTransfer" $true "DataTransfer and FileList"
Check-Pattern "M-26" "ios\FaceSwapLiveAppV17\Views\BrowserWebContainer.swift" "completionHandler\(.cancel\)" $false "Proper JS panel handling"
Check-Pattern "M-27" ".github\workflows\test.yml" "macos-latest" $true "macOS CI"
Check-Pattern "M-28" "ios\FaceSwapLiveAppV17Tests\FaceSwapLiveAppV17Tests.swift" "assertGoldenImage" $true "Golden-image verification"
Check-Pattern "N-01" "ios\FaceSwapLiveAppV17\Views\BrowserWebContainer.swift" "JSONDecoder" $true "Typed Codable envelope"
Check-Pattern "N-02" "ios\FaceSwapLiveAppV17\Services\StyleSheetProvider.swift" "fslAskDecision.*setTimeout" $true "Cancellable timeout in fslAskDecision"
Check-Pattern "N-03" "ios\FaceSwapLiveAppV17\Services\CaptureService.swift" "RotationCoordinator" $true "RotationCoordinator"
Check-Pattern "N-05" "ios\FaceSwapLiveAppV17\Services\StyleSheetProvider.swift" "accept.*image" $true "Require media accept"
Check-Pattern "N-06" "ios\FaceSwapLiveAppV17\Services\StyleSheetProvider.swift" "fslHybridAdapter" $true "Hybrid adapter fidelity"
Check-Pattern "N-07" "ios\FaceSwapLiveAppV17\Services\LocalResourceHandler.swift" "lock.unlock" $true "Unlock before transform"

$global:results -join "`n"
