import SwiftUI
import UIKit

struct QuadEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let image: UIImage
    let title: String
    let onApply: (Quadrilateral) -> Void

    @State private var quadrilateral: Quadrilateral

    init(image: UIImage, title: String, quadrilateral: Quadrilateral, onApply: @escaping (Quadrilateral) -> Void) {
        self.image = image
        self.title = title
        self.onApply = onApply
        _quadrilateral = State(initialValue: quadrilateral)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("四隅をドラッグして範囲を調整")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                GeometryReader { proxy in
                    let imageRect = aspectFitRect(imageSize: image.size, in: proxy.size)
                    ZStack {
                        Color.black.opacity(0.92)
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: imageRect.width, height: imageRect.height)
                            .position(x: imageRect.midX, y: imageRect.midY)

                        Path { path in
                            let points = [
                                point(for: .topLeft, in: imageRect),
                                point(for: .topRight, in: imageRect),
                                point(for: .bottomRight, in: imageRect),
                                point(for: .bottomLeft, in: imageRect)
                            ]
                            guard let first = points.first else { return }
                            path.move(to: first)
                            points.dropFirst().forEach { path.addLine(to: $0) }
                            path.closeSubpath()
                        }
                        .fill(Color.accentColor.opacity(0.16))
                        .overlay {
                            Path { path in
                                let points = [
                                    point(for: .topLeft, in: imageRect),
                                    point(for: .topRight, in: imageRect),
                                    point(for: .bottomRight, in: imageRect),
                                    point(for: .bottomLeft, in: imageRect)
                                ]
                                guard let first = points.first else { return }
                                path.move(to: first)
                                points.dropFirst().forEach { path.addLine(to: $0) }
                                path.closeSubpath()
                            }
                            .stroke(Color.accentColor, lineWidth: 2)
                        }

                        ForEach(Corner.allCases) { corner in
                            Circle()
                                .fill(.white)
                                .overlay(Circle().stroke(Color.accentColor, lineWidth: 3))
                                .frame(width: 30, height: 30)
                                .position(point(for: corner, in: imageRect))
                                .shadow(radius: 3)
                                .accessibilityLabel("\(corner.displayName)の角")
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            update(corner, location: value.location, in: imageRect)
                                        }
                                )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .frame(maxHeight: 520)
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("適用") {
                        onApply(quadrilateral)
                        dismiss()
                    }
                    .disabled(!quadrilateral.isValid)
                }
            }
        }
    }

    private enum Corner: Int, CaseIterable, Identifiable {
        case topLeft
        case topRight
        case bottomRight
        case bottomLeft

        var id: Int { rawValue }

        var displayName: String {
            switch self {
            case .topLeft: "左上"
            case .topRight: "右上"
            case .bottomRight: "右下"
            case .bottomLeft: "左下"
            }
        }
    }

    private func point(for corner: Corner, in rect: CGRect) -> CGPoint {
        let normalized: CGPoint
        switch corner {
        case .topLeft: normalized = quadrilateral.topLeft
        case .topRight: normalized = quadrilateral.topRight
        case .bottomRight: normalized = quadrilateral.bottomRight
        case .bottomLeft: normalized = quadrilateral.bottomLeft
        }
        return CGPoint(x: rect.minX + normalized.x * rect.width, y: rect.minY + normalized.y * rect.height)
    }

    private func update(_ corner: Corner, location: CGPoint, in rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        let normalized = CGPoint(
            x: min(1, max(0, (location.x - rect.minX) / rect.width)),
            y: min(1, max(0, (location.y - rect.minY) / rect.height))
        )
        var updated = quadrilateral
        switch corner {
        case .topLeft: updated.topLeft = normalized
        case .topRight: updated.topRight = normalized
        case .bottomRight: updated.bottomRight = normalized
        case .bottomLeft: updated.bottomLeft = normalized
        }
        quadrilateral = updated
    }

    private func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }
}
