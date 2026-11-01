import PhotosUI
import SwiftUI
import UIKit
import AVFoundation

struct AddWineView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CellarStore

    @State private var name = ""
    @State private var producer = ""
    @State private var region = ""
    @State private var country = ""
    @State private var grapes = ""
    @State private var vintage = ""
    @State private var volumeML = "750"
    @State private var alcohol = ""
    @State private var storageLocation = ""
    @State private var purchasePrice = ""
    @State private var note = ""
    @State private var wineType: WineType = .red
    @State private var bottleShape: BottleShape = .generic
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedLabelPhoto: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var previewImage: UIImage?
    @State private var showingCamera = false
    @State private var cameraMessage: String?
    @State private var isLoadingPhoto = false
    @State private var isLoadingLabelPhoto = false
    @State private var isProcessingImage = false
    @State private var isRecognizing = false
    @State private var recognizedText = ""
    @State private var recognizedResult: OCRResult?
    @State private var bottleCutoutImageData: Data?
    @State private var imageProcessingToken = UUID()
    @State private var photoLoadToken = UUID()
    @State private var labelPhotoLoadToken = UUID()
    @State private var showingSubjectPicker = false
    @State private var labelImageData: Data?
    @State private var bottleQuadrilateral = Quadrilateral(
        topLeft: CGPoint(x: 0.08, y: 0.04),
        topRight: CGPoint(x: 0.92, y: 0.04),
        bottomLeft: CGPoint(x: 0.08, y: 0.96),
        bottomRight: CGPoint(x: 0.92, y: 0.96)
    )
    @State private var labelQuadrilateral = Quadrilateral(
        topLeft: CGPoint(x: 0.18, y: 0.32),
        topRight: CGPoint(x: 0.82, y: 0.32),
        bottomLeft: CGPoint(x: 0.18, y: 0.54),
        bottomRight: CGPoint(x: 0.82, y: 0.54)
    )
    @State private var correctionTarget: CorrectionTarget?
    @State private var segmentationMessage: String?
    @State private var shapeMessage: String?
    @State private var pendingSubjectBounds: CGRect?
    @State private var pendingSubjectImageData: Data?
    @State private var pendingSubjectFeatures: BottleShapeFeatures?
    @State private var bottleCutoutIsSubjectLifted = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        ContentUnavailableView("写真は任意です", systemImage: "photo", description: Text("ボトル写真を保存すると、後からラベルを確認できます。"))
                    }
                    HStack {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("写真を選択", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.bordered)
                        Button { requestCameraAccess() } label: {
                            Label("カメラ", systemImage: "camera")
                        }
                        .buttonStyle(.bordered)
                    }
                    if imageData != nil {
                        if isProcessingImage {
                            ProgressView("画像を解析中…")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let bottleCutoutImageData,
                           let bottleImage = UIImage(data: bottleCutoutImageData) {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("抽出されたボトル", systemImage: "wand.and.stars")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(uiImage: bottleImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity, maxHeight: 180)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        HStack {
                            Button("ボトル範囲") { correctionTarget = .bottle }
                            Button("ラベル範囲") { correctionTarget = .label }
                        }
                        .buttonStyle(.bordered)
                        Button {
                            pendingSubjectBounds = nil
                            pendingSubjectImageData = nil
                            pendingSubjectFeatures = nil
                            showingSubjectPicker = true
                        } label: {
                            Label("標準APIで被写体を選択", systemImage: "hand.tap")
                        }
                        .buttonStyle(.bordered)
                        if let segmentationMessage {
                            Text(segmentationMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            recognizeText()
                        } label: {
                            if isRecognizing {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("ラベル文字を読み取る", systemImage: "text.viewfinder")
                            }
                        }
                        .disabled(isRecognizing)
                        if !recognizedText.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("認識候補").font(.caption).foregroundStyle(.secondary)
                                Text(recognizedText)
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                        HStack {
                            PhotosPicker(selection: $selectedLabelPhoto, matching: .images) {
                                Label("ラベル画像を手動選択", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                            .buttonStyle(.bordered)
                            if isLoadingLabelPhoto {
                                ProgressView().controlSize(.small)
                            } else if labelImageData != nil {
                                Label("設定済み", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("ラベルを検出できない場合は、ラベル画像を別途選択できます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("ボトル写真")
                }

                Section("基本情報") {
                    TextField("銘柄名（必須）", text: $name)
                    TextField("生産者", text: $producer)
                    TextField("産地", text: $region)
                    TextField("国", text: $country)
                    TextField("品種（カンマ区切り）", text: $grapes)
                    TextField("ヴィンテージ", text: $vintage)
                        .keyboardType(.numberPad)
                    Picker("ワインタイプ", selection: $wineType) {
                        ForEach(WineType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    HStack {
                        TextField("容量", text: $volumeML)
                            .keyboardType(.numberPad)
                        Text("mL").foregroundStyle(.secondary)
                        TextField("アルコール", text: $alcohol)
                            .keyboardType(.decimalPad)
                        Text("%").foregroundStyle(.secondary)
                    }
                }

                Section("ボトル") {
                    Picker("形状", selection: $bottleShape) {
                        ForEach(BottleShape.allCases) { shape in
                            Text(shape.displayName).tag(shape)
                        }
                    }
                    if let shapeMessage {
                        Text(shapeMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField("保管場所", text: $storageLocation)
                    TextField("購入価格（任意）", text: $purchasePrice)
                        .keyboardType(.decimalPad)
                    TextField("メモ", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("ワインを登録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoadingPhoto || isProcessingImage)
                }
            }
            .onChange(of: selectedPhoto) { _, newItem in
                let loadToken = UUID()
                photoLoadToken = loadToken
                guard let newItem else {
                    isLoadingPhoto = false
                    return
                }
                isLoadingPhoto = true
                Task {
                    let data = try? await newItem.loadTransferable(type: Data.self).flatMap { ImageNormalizer().normalize(data: $0) }
                    await MainActor.run {
                        guard loadToken == photoLoadToken else { return }
                        isLoadingPhoto = false
                        prepareImage(data: data)
                    }
                }
            }
            .onChange(of: selectedLabelPhoto) { _, newItem in
                let loadToken = UUID()
                labelPhotoLoadToken = loadToken
                guard let newItem else {
                    isLoadingLabelPhoto = false
                    return
                }
                isLoadingLabelPhoto = true
                Task {
                    let data = try? await newItem.loadTransferable(type: Data.self).flatMap { ImageNormalizer().normalize(data: $0) }
                    await MainActor.run {
                        guard loadToken == labelPhotoLoadToken else { return }
                        isLoadingLabelPhoto = false
                        labelImageData = data
                        segmentationMessage = data == nil ? "ラベル画像を読み込めませんでした。" : "手動選択したラベル画像を保存します。"
                    }
                }
            }
            .alert("カメラを使用できません", isPresented: Binding(get: { cameraMessage != nil }, set: { if !$0 { cameraMessage = nil } })) {
                Button("閉じる", role: .cancel) { cameraMessage = nil }
            } message: {
                Text(cameraMessage ?? "写真ライブラリからボトル画像を選択してください。")
            }
            .sheet(isPresented: $showingCamera) {
                CameraPicker(
                    onImage: { image in
                        guard let normalizedData = ImageNormalizer().normalize(image: image) else {
                            showingCamera = false
                            cameraMessage = "撮影画像を読み込めませんでした。もう一度撮影するか、写真ライブラリを利用してください。"
                            return
                        }
                        prepareImage(data: normalizedData)
                        showingCamera = false
                    },
                    onFailure: { message in
                        showingCamera = false
                        cameraMessage = message
                    },
                    onCancel: {
                        showingCamera = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(item: $correctionTarget) { target in
                if let previewImage {
                    QuadEditorView(
                        image: previewImage,
                        title: target.title,
                        quadrilateral: target == .bottle ? bottleQuadrilateral : labelQuadrilateral
                    ) { corrected in
                        switch target {
                        case .bottle:
                            bottleQuadrilateral = corrected
                            let correctedBounds = boundingRect(from: corrected)
                            if let croppedCutout = cropBottleCutout(to: correctedBounds) {
                                bottleCutoutImageData = croppedCutout
                                bottleCutoutIsSubjectLifted = false
                                if let features = UIImage(data: croppedCutout)?.cgImage.flatMap(BottleShapeFeatureExtractor.extract) {
                                    applyShapeCandidate(from: features)
                                }
                            }
                            segmentationMessage = "ボトル範囲を更新しました。"
                        case .label:
                            labelQuadrilateral = corrected
                            labelImageData = makeLabelTexture(from: previewImage, quadrilateral: corrected)
                            segmentationMessage = labelImageData == nil ? "ラベル画像を作成できませんでした。" : "ラベル範囲を補正しました。"
                        }
                    }
                } else {
                    Color.clear
                }
            }
            .sheet(isPresented: $showingSubjectPicker) {
                NavigationStack {
                    if let previewImage {
                        VisionSubjectPickerView(image: previewImage) { bounds, subjectImage in
                            pendingSubjectBounds = bounds
                            pendingSubjectImageData = subjectImage?.pngData()
                            pendingSubjectFeatures = subjectImage?.cgImage.flatMap(BottleShapeFeatureExtractor.extract)
                            segmentationMessage = "ボトル候補を選択しました。「適用」で範囲を反映します。別の対象なら長押ししてください。"
                        }
                        .ignoresSafeArea(edges: .bottom)
                    } else {
                        ContentUnavailableView("画像がありません", systemImage: "photo")
                    }
                    Text("ボトル候補は自動選択されます。別の対象を使う場合は長押ししてください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
                .navigationTitle("被写体を選択")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") {
                            pendingSubjectBounds = nil
                            pendingSubjectImageData = nil
                            pendingSubjectFeatures = nil
                            showingSubjectPicker = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("適用") {
                            guard let pendingSubjectBounds else { return }
                            bottleQuadrilateral = quadrilateral(from: pendingSubjectBounds)
                            if let pendingSubjectImageData {
                                bottleCutoutImageData = pendingSubjectImageData
                                bottleCutoutIsSubjectLifted = true
                            } else if !bottleCutoutIsSubjectLifted,
                               let croppedCutout = cropBottleCutout(to: pendingSubjectBounds) {
                                bottleCutoutImageData = croppedCutout
                            }
                            if let pendingSubjectFeatures {
                                applyShapeCandidate(from: pendingSubjectFeatures)
                            }
                            segmentationMessage = "標準APIで選択したボトル被写体範囲を適用しました。"
                            self.pendingSubjectBounds = nil
                            self.pendingSubjectImageData = nil
                            self.pendingSubjectFeatures = nil
                            showingSubjectPicker = false
                        }
                        .disabled(pendingSubjectBounds == nil)
                    }
                }
            }
        }
    }

    private func save() {
        let grapeVarieties = grapes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let wine = WineDraft(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            producer: producer.nilIfBlank,
            region: region.nilIfBlank,
            country: country.nilIfBlank,
            grapeVarieties: grapeVarieties,
            vintage: Int(vintage),
            wineType: wineType,
            volumeML: Int(volumeML),
            alcoholPercent: Double(alcohol),
            ocrRawText: recognizedResult?.rawText,
            ocrObservationsData: recognizedResult?.observationsArchiveData
        )
        let bottle = BottleDraft(
            storageLocation: storageLocation.nilIfBlank,
            purchasePrice: Double(purchasePrice),
            bottleShape: bottleShape,
            note: note.nilIfBlank
        )
        let generatedLabelData = labelImageData ?? previewImage.flatMap { makeLabelTexture(from: $0, quadrilateral: labelQuadrilateral) }
        let didSave = store.create(
            wine: wine,
            bottle: bottle,
            imageData: imageData,
            labelImageData: generatedLabelData,
            bottleCutoutImageData: bottleCutoutImageData
        )
        if didSave {
            dismiss()
        }
    }

    private func recognizeText() {
        guard let cgImage = previewImage?.cgImage else { return }
        isRecognizing = true
        Task { @MainActor in
            do {
                let result = try await VisionTextRecognizer().recognize(image: cgImage)
                recognizedResult = result
                recognizedText = result.rawText
                applyOCRCandidate(RuleBasedOCRMetadataParser().parse(result))
            } catch {
                recognizedResult = nil
                recognizedText = "文字を認識できませんでした。"
            }
            isRecognizing = false
        }
    }

    private func requestCameraAccess() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraMessage = "この端末ではカメラを利用できません。写真ライブラリを利用してください。"
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showingCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        showingCamera = true
                    } else {
                        cameraMessage = "カメラの使用が許可されていません。写真ライブラリを利用できます。"
                    }
                }
            }
        case .denied, .restricted:
            cameraMessage = "カメラの使用が許可されていません。写真ライブラリを利用できます。"
        @unknown default:
            cameraMessage = "カメラを利用できません。写真ライブラリを利用してください。"
        }
    }

    private func prepareImage(data: Data?) {
        let processingToken = UUID()
        imageProcessingToken = processingToken
        imageData = data
        previewImage = data.flatMap(UIImage.init(data:))
        labelImageData = nil
        bottleCutoutImageData = nil
        bottleCutoutIsSubjectLifted = false
        pendingSubjectBounds = nil
        pendingSubjectImageData = nil
        pendingSubjectFeatures = nil
        recognizedText = ""
        recognizedResult = nil
        segmentationMessage = nil
        shapeMessage = nil
        bottleQuadrilateral = Quadrilateral(
            topLeft: CGPoint(x: 0.08, y: 0.04),
            topRight: CGPoint(x: 0.92, y: 0.04),
            bottomLeft: CGPoint(x: 0.08, y: 0.96),
            bottomRight: CGPoint(x: 0.92, y: 0.96)
        )
        labelQuadrilateral = Quadrilateral(
            topLeft: CGPoint(x: 0.18, y: 0.32),
            topRight: CGPoint(x: 0.82, y: 0.32),
            bottomLeft: CGPoint(x: 0.18, y: 0.54),
            bottomRight: CGPoint(x: 0.82, y: 0.54)
        )

        guard let cgImage = previewImage?.cgImage else {
            isProcessingImage = false
            segmentationMessage = data == nil ? "画像を読み込めませんでした。もう一度選択してください。" : "画像を解析できませんでした。別の画像を選択してください。"
            return
        }
        isProcessingImage = true
        Task { @MainActor in
            defer {
                if processingToken == imageProcessingToken {
                    isProcessingImage = false
                }
            }
            do {
                let result = try await VisionBottleSegmenter().segment(image: cgImage)
                guard processingToken == imageProcessingToken else { return }
                bottleCutoutImageData = result.isolatedImageData
                bottleQuadrilateral = quadrilateral(from: result.boundingBox)
                if let detectedLabel = try? VisionLabelDetector().detect(image: cgImage) {
                    labelQuadrilateral = detectedLabel
                }
                let extractedFeatures = result.shapeFeatures ?? BottleShapeFeatures(
                    aspectRatio: result.boundingBox.height / max(result.boundingBox.width, 0.01),
                    shoulderHeight: 0.2,
                    neckLength: 0.3,
                    bodyWidthPosition: 0.5,
                    sparklingLikelihood: 0
                )
                applyShapeCandidate(from: BottleShapeFeatures(
                    aspectRatio: extractedFeatures.aspectRatio,
                    shoulderHeight: extractedFeatures.shoulderHeight,
                    neckLength: extractedFeatures.neckLength,
                    bodyWidthPosition: extractedFeatures.bodyWidthPosition,
                    sparklingLikelihood: wineType == .sparkling ? 1 : 0
                ))
                segmentationMessage = result.confidence < 0.4
                    ? "認識信頼度が低いため、ボトル／ラベル範囲を確認してください。"
                    : "ボトルとラベルの候補を抽出しました。必要なら範囲を補正してください。"
            } catch {
                guard processingToken == imageProcessingToken else { return }
                segmentationMessage = "ボトル範囲を自動抽出できませんでした。手動で指定してください。"
            }
        }
    }

    private func applyOCRCandidate(_ candidate: OCRMetadataCandidate) {
        if name.nilIfBlank == nil, let probableName = candidate.probableName {
            name = probableName
        }
        if producer.nilIfBlank == nil, let probableProducer = candidate.probableProducer {
            producer = probableProducer
        }
        if region.nilIfBlank == nil, let probableRegion = candidate.probableRegion {
            region = probableRegion
        }
        if country.nilIfBlank == nil, let probableCountry = candidate.probableCountry {
            country = probableCountry
        }
        if vintage.nilIfBlank == nil, let vintage = candidate.vintage {
            self.vintage = String(vintage)
        }
        if (Int(volumeML) == nil || volumeML == "750"), let volumeML = candidate.volumeML {
            self.volumeML = String(volumeML)
        }
        if alcohol.nilIfBlank == nil, let alcohol = candidate.alcoholPercent {
            self.alcohol = alcohol.formatted(.number.precision(.fractionLength(1)))
        }
        if grapes.nilIfBlank == nil, !candidate.grapeVarieties.isEmpty {
            grapes = candidate.grapeVarieties.joined(separator: ", ")
        }
        if let wineType = candidate.wineType {
            self.wineType = wineType
        }
    }

    private func applyShapeCandidate(from features: BottleShapeFeatures?) {
        guard let features else {
            shapeMessage = "ボトル輪郭を取得できないため、形状を手動で選択してください。"
            return
        }
        if let candidate = RuleBasedBottleShapeClassifier().classify(features: features).first,
           candidate.shape != .generic,
           candidate.confidence >= 0.35 {
            bottleShape = candidate.shape
            shapeMessage = "ボトル輪郭からの形状候補: \(candidate.shape.displayName)（手動変更できます）"
        } else {
            shapeMessage = "形状候補の信頼度が低いため、手動で選択してください。"
        }
    }

    private func quadrilateral(from rect: CGRect) -> Quadrilateral {
        let minX = min(1, max(0, rect.minX))
        let maxX = min(1, max(0, rect.maxX))
        let minY = min(1, max(0, rect.minY))
        let maxY = min(1, max(0, rect.maxY))
        return Quadrilateral(
            topLeft: CGPoint(x: minX, y: minY),
            topRight: CGPoint(x: maxX, y: minY),
            bottomLeft: CGPoint(x: minX, y: maxY),
            bottomRight: CGPoint(x: maxX, y: maxY)
        )
    }

    private func boundingRect(from quadrilateral: Quadrilateral) -> CGRect {
        let points = [quadrilateral.topLeft, quadrilateral.topRight, quadrilateral.bottomLeft, quadrilateral.bottomRight]
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 1
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func makeLabelTexture(from image: UIImage, quadrilateral: Quadrilateral) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        guard let corrected = try? LabelPerspectiveCorrector().correct(image: input, quadrilateral: quadrilateral),
              let correctedCGImage = CIContext().createCGImage(corrected, from: corrected.extent) else { return nil }
        return UIImage(cgImage: correctedCGImage).jpegData(compressionQuality: 0.9)
    }

    private func cropBottleCutout(to normalizedRect: CGRect) -> Data? {
        guard let currentData = bottleCutoutImageData,
              let image = UIImage(data: currentData),
              let cgImage = image.cgImage else { return nil }
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let clamped = normalizedRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isEmpty else { return nil }
        // VisionKit bounds use a top-left normalized coordinate system, while
        // CGImage cropping uses a bottom-left origin.
        let cropRect = CGRect(
            x: clamped.minX * imageWidth,
            y: (1 - clamped.maxY) * imageHeight,
            width: clamped.width * imageWidth,
            height: clamped.height * imageHeight
        ).integral.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        guard let cropped = cgImage.cropping(to: cropRect), cropRect.width > 1, cropRect.height > 1 else { return nil }
        return UIImage(cgImage: cropped).pngData()
    }
}

private enum CorrectionTarget: String, Identifiable {
    case bottle
    case label

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottle: "ボトル範囲を補正"
        case .label: "ラベル範囲を補正"
        }
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: @MainActor (UIImage) -> Void
    let onFailure: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage, onFailure: onFailure, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: @MainActor (UIImage) -> Void
        let onFailure: @MainActor (String) -> Void
        let onCancel: @MainActor () -> Void

        init(
            onImage: @escaping @MainActor (UIImage) -> Void,
            onFailure: @escaping @MainActor (String) -> Void,
            onCancel: @escaping @MainActor () -> Void
        ) {
            self.onImage = onImage
            self.onFailure = onFailure
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = (info[.originalImage] as? UIImage) ?? (info[.editedImage] as? UIImage) {
                onImage(image)
            } else {
                onFailure("撮影画像を取得できませんでした。もう一度撮影するか、写真ライブラリを利用してください。")
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
