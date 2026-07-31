import SwiftUI

struct DebugOverlayView: View {
    var previewWidth: Int
    var previewHeight: Int
    var encodedWidth: Int
    var encodedHeight: Int
    var showSafeArea: Bool = true
    var showCropArea: Bool = true

    private var previewAspect: CGFloat {
        guard previewHeight > 0 else { return 1 }
        return CGFloat(previewWidth) / CGFloat(previewHeight)
    }

    private var encodedAspect: CGFloat {
        guard encodedHeight > 0 else { return 1 }
        return CGFloat(encodedWidth) / CGFloat(encodedHeight)
    }

    private var aspectsDiffer: Bool {
        abs(previewAspect - encodedAspect) > 0.01
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack {
                // Safe area guide
                if showSafeArea {
                    safeAreaOverlay(in: size)
                }

                // Crop area visualization
                if showCropArea && aspectsDiffer {
                    cropOverlay(in: size)
                }

                // Corner markers
                cornerMarkers(in: size)

                // Info badge
                infoBadge
                    .position(x: size.width / 2, y: size.height - 20)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Safe Area

    private func safeAreaOverlay(in size: CGSize) -> some View {
        let insetX = size.width * 0.05
        let insetY = size.height * 0.05
        let rect = CGRect(
            x: insetX,
            y: insetY,
            width: size.width - insetX * 2,
            height: size.height - insetY * 2
        )

        return ZStack {
            Rectangle()
                .path(in: rect)
                .stroke(
                    .yellow,
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                )

            Text("Safe Area")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.yellow.opacity(0.8))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.black.opacity(0.5), in: .rect(cornerRadius: 3))
                .position(x: rect.midX, y: rect.minY - 8)
        }
    }

    // MARK: - Crop Area

    private func cropOverlay(in size: CGSize) -> some View {
        ZStack {
            if encodedAspect > previewAspect {
                // Encoded is wider → bars on top and bottom
                let encodedHeightInPreview = size.width / encodedAspect
                let barHeight = (size.height - encodedHeightInPreview) / 2

                if barHeight > 0 {
                    // Top bar
                    Rectangle()
                        .fill(.red.opacity(0.3))
                        .frame(width: size.width, height: barHeight)
                        .position(x: size.width / 2, y: barHeight / 2)

                    // Bottom bar
                    Rectangle()
                        .fill(.red.opacity(0.3))
                        .frame(width: size.width, height: barHeight)
                        .position(x: size.width / 2, y: size.height - barHeight / 2)

                    Text("Crop Area")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.red.opacity(0.9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.5), in: .rect(cornerRadius: 3))
                        .position(x: size.width / 2, y: barHeight / 2)
                }
            } else {
                // Encoded is taller → bars on left and right
                let encodedWidthInPreview = size.height * encodedAspect
                let barWidth = (size.width - encodedWidthInPreview) / 2

                if barWidth > 0 {
                    // Left bar
                    Rectangle()
                        .fill(.red.opacity(0.3))
                        .frame(width: barWidth, height: size.height)
                        .position(x: barWidth / 2, y: size.height / 2)

                    // Right bar
                    Rectangle()
                        .fill(.red.opacity(0.3))
                        .frame(width: barWidth, height: size.height)
                        .position(x: size.width - barWidth / 2, y: size.height / 2)

                    Text("Crop Area")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.red.opacity(0.9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.5), in: .rect(cornerRadius: 3))
                        .position(x: barWidth / 2, y: size.height / 2)
                }
            }
        }
    }

    // MARK: - Corner Markers

    private func cornerMarkers(in size: CGSize) -> some View {
        let markerLength: CGFloat = 16
        let markerColor: Color = .yellow.opacity(0.7)

        return ZStack {
            // Top-left
            cornerMark(at: .zero, dx: 1, dy: 1, length: markerLength, color: markerColor)

            // Top-right
            cornerMark(at: CGPoint(x: size.width, y: 0), dx: -1, dy: 1, length: markerLength, color: markerColor)

            // Bottom-left
            cornerMark(at: CGPoint(x: 0, y: size.height), dx: 1, dy: -1, length: markerLength, color: markerColor)

            // Bottom-right
            cornerMark(at: CGPoint(x: size.width, y: size.height), dx: -1, dy: -1, length: markerLength, color: markerColor)

            // Dimension labels
            Text("\(previewWidth)")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.yellow.opacity(0.7))
                .position(x: size.width / 2, y: 10)

            Text("\(previewHeight)")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.yellow.opacity(0.7))
                .rotationEffect(.degrees(-90))
                .position(x: 10, y: size.height / 2)
        }
    }

    private func cornerMark(at point: CGPoint, dx: CGFloat, dy: CGFloat, length: CGFloat, color: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: point.x, y: point.y + dy * length))
            path.addLine(to: point)
            path.addLine(to: CGPoint(x: point.x + dx * length, y: point.y))
        }
        .stroke(color, lineWidth: 1.5)
    }

    // MARK: - Info Badge

    private var infoBadge: some View {
        HStack(spacing: 4) {
            Text("Preview:")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
            Text("\(previewWidth)×\(previewHeight)")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.yellow)
            Text("→")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
            Text("Encoded:")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
            Text("\(encodedWidth)×\(encodedHeight)")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.7), in: Capsule())
    }
}
