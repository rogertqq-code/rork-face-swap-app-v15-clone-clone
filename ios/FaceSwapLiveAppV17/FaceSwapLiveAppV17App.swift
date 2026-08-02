import SwiftUI

@main
struct FaceSwapLiveAppV17App: App {
#if QA_AUTOMATION
    @StateObject private var qaRuntime = QAAutomationRuntime()
#endif

    var body: some Scene {
        WindowGroup {
#if QA_AUTOMATION
            ContentView()
                .environmentObject(qaRuntime)
                .sheet(isPresented: $qaRuntime.isControlSurfacePresented) {
                    QAControlSurfaceView(runtime: qaRuntime)
                }
                .overlay(alignment: .topLeading) {
                    QAAutomationProbeView(runtime: qaRuntime)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    QAAutomationBanner(runtime: qaRuntime)
                }
                .task {
                    await qaRuntime.bootstrap()
                }
#else
            ContentView()
#endif
        }
    }
}
