import SwiftUI
import UIKit
import VisionKit

/// Uses Apple's standard subject-lift interaction so a person can long-press
/// the bottle instead of relying only on automatic segmentation.
struct VisionSubjectPickerView: UIViewControllerRepresentable {
    let image: UIImage
    let onSelect: @MainActor (CGRect, UIImage?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeUIViewController(context: Context) -> SubjectPickerViewController {
        SubjectPickerViewController(image: image, coordinator: context.coordinator)
    }

    func updateUIViewController(_ uiViewController: SubjectPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, ImageAnalysisInteractionDelegate {
        let onSelect: @MainActor (CGRect, UIImage?) -> Void
        weak var imageView: UIImageView?

        init(onSelect: @escaping @MainActor (CGRect, UIImage?) -> Void) {
            self.onSelect = onSelect
        }

        func interaction(_ interaction: ImageAnalysisInteraction, highlightSelectedItemsDidChange highlighted: Bool) {
            guard highlighted,
                  let subject = interaction.highlightedSubjects.first,
                  imageView != nil else { return }
            Task { @MainActor in
                let liftedImage = try? await interaction.image(for: [subject])
                select(subject: subject, image: liftedImage)
            }
        }

        func select(subject: ImageAnalysisInteraction.Subject, image: UIImage? = nil) {
            guard let imageView, !imageView.bounds.isEmpty else { return }
            let subjectBounds = subject.bounds
            guard !subjectBounds.isEmpty else { return }

            let imageRect = aspectFitRect(imageSize: imageView.image?.size ?? .zero, in: imageView.bounds.size)
            let normalized = CGRect(
                x: min(1, max(0, (subjectBounds.minX - imageRect.minX) / imageRect.width)),
                y: min(1, max(0, (subjectBounds.minY - imageRect.minY) / imageRect.height)),
                width: min(1, max(0, subjectBounds.width / imageRect.width)),
                height: min(1, max(0, subjectBounds.height / imageRect.height))
            )

            onSelect(normalized, image)
        }

        private func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
            guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
            let scale = min(container.width / imageSize.width, container.height / imageSize.height)
            let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
        }
    }
}

@MainActor
final class SubjectPickerViewController: UIViewController {
    private let image: UIImage
    private let coordinator: VisionSubjectPickerView.Coordinator
    private let imageView = UIImageView()

    init(image: UIImage, coordinator: VisionSubjectPickerView.Coordinator) {
        self.image = image
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let interaction = ImageAnalysisInteraction()
        interaction.preferredInteractionTypes = .imageSubject
        interaction.delegate = coordinator
        imageView.addInteraction(interaction)
        coordinator.imageView = imageView

        guard ImageAnalyzer.isSupported else { return }
        Task { @MainActor in
            let configuration = ImageAnalyzer.Configuration([.visualLookUp, .text])
            if let analysis = try? await ImageAnalyzer().analyze(image, configuration: configuration) {
                interaction.analysis = analysis
                let subjects = await interaction.subjects
                if let candidate = subjects.max(by: { lhs, rhs in
                    let lhsAspect = lhs.bounds.height / max(lhs.bounds.width, 1)
                    let rhsAspect = rhs.bounds.height / max(rhs.bounds.width, 1)
                    let lhsScore = lhs.bounds.height * (0.7 + min(1.5, lhsAspect))
                    let rhsScore = rhs.bounds.height * (0.7 + min(1.5, rhsAspect))
                    return lhsScore < rhsScore
                }) {
                    interaction.highlightedSubjects = [candidate]
                    let liftedImage = try? await interaction.image(for: [candidate])
                    coordinator.select(subject: candidate, image: liftedImage)
                }
            }
        }
    }
}
