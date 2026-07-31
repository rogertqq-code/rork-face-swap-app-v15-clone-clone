import SwiftUI

import AudioToolbox

/// A camera-style screen shown for exactly the window a native camera hand-off
/// occupies. The page is frozen and its live feed interrupted underneath, so this
/// is what makes the capture visible to the user while the site sees the freeze a
/// genuine camera launch produces.
struct NativeCaptureOverlay: View {
    let isActive: Bool
    let didFire: Bool

    @State private var shutterFlash: Bool = false
    @State private var shutterPressed: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                viewfinder
                Spacer(minLength: 0)
                bottomBar
            }

            if shutterFlash {
                Color.white
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .transition(.opacity)
        .onChange(of: didFire) { _, fired in
            guard fired else { return }
            fireShutter()
        }
    }

    private var topBar: some View {
        HStack(spacing: 22) {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 17, weight: .medium))
            Spacer()
            Image(systemName: "livephoto")
                .font(.system(size: 19, weight: .medium))
            Spacer()
            Image(systemName: "chevron.up")
                .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 26)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }

    /// Live-camera-style viewfinder. Deliberately abstract (grid + focus frame)
    /// rather than a fake photo preview — the real photo goes to the page.
    private var viewfinder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(white: 0.14),
                            Color(white: 0.07),
                            Color(white: 0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            GeometryReader { geo in
                Path { path in
                    let w = geo.size.width
                    let h = geo.size.height
                    for i in 1..<3 {
                        let x = w * CGFloat(i) / 3
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: h))
                        let y = h * CGFloat(i) / 3
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: w, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
            }

            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.yellow.opacity(0.9), lineWidth: 1.2)
                .frame(width: 88, height: 88)
                .shadow(color: .yellow.opacity(0.25), radius: 5)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 6))
        .padding(.horizontal, 2)
    }

    private var bottomBar: some View {
        VStack(spacing: 20) {
            Text("PHOTO")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.yellow)
                .tracking(1.4)

            HStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(white: 0.18))
                    .frame(width: 40, height: 40)

                Spacer()

                shutterButton

                Spacer()

                ZStack {
                    Circle()
                        .fill(Color(white: 0.18))
                        .frame(width: 40, height: 40)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(.horizontal, 34)
        }
        .padding(.bottom, 26)
        .padding(.top, 18)
    }

    private var shutterButton: some View {
        ZStack {
            Circle()
                .stroke(Color.white, lineWidth: 3)
                .frame(width: 70, height: 70)
            Circle()
                .fill(Color.white)
                .frame(width: 58, height: 58)
                .scaleEffect(shutterPressed ? 0.86 : 1)
        }
        .animation(.easeOut(duration: 0.12), value: shutterPressed)
    }

    private func fireShutter() {
        shutterPressed = true
        // The shutter click a real capture makes.
        AudioServicesPlaySystemSound(1108)
        withAnimation(.easeOut(duration: 0.06)) { shutterFlash = true }
        Task {
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.easeIn(duration: 0.16)) { shutterFlash = false }
            shutterPressed = false
        }
    }
}
