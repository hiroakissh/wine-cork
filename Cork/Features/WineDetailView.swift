import SwiftUI
import UIKit

struct WineDetailView: View {
    @ObservedObject var store: CellarStore
    let entry: CellarEntry
    @State private var selectedState: BottleLifecycleState
    @State private var showingTasting = false
    @State private var showingPairing = false
    @State private var showingEdit = false
    @State private var showingDeleteConfirmation = false

    init(store: CellarStore, entry: CellarEntry) {
        self.store = store
        self.entry = entry
        _selectedState = State(initialValue: entry.lifecycleState)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 88, height: 126)
                        .overlay {
                            if let image = thumbnailImageData().flatMap(UIImage.init(data:)) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .padding(6)
                            } else {
                                Image(systemName: "wineglass")
                                    .font(.largeTitle)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.displayName).font(.title3.bold())
                        if let producer = entry.producer { Text(producer).foregroundStyle(.secondary) }
                        if let vintage = entry.vintage { Text(String(vintage)).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
            }

            Section("状態") {
                Picker("ライフサイクル", selection: $selectedState) {
                    ForEach(BottleLifecycleState.allCases) { state in
                        Label(state.displayName, systemImage: state.systemImage).tag(state)
                    }
                }
                .onChange(of: selectedState) { _, state in store.changeLifecycle(for: entry.id, to: state) }
                if let location = entry.storageLocation, !location.isEmpty {
                    LabeledContent("保管場所", value: location)
                }
                if let remaining = entry.remainingPercent {
                    LabeledContent("残量", value: "\(remaining)%")
                }
            }

            Section("ワイン情報") {
                if let region = entry.region { LabeledContent("産地", value: region) }
                if let country = entry.country { LabeledContent("国", value: country) }
                if !entry.grapeVarieties.isEmpty { LabeledContent("品種", value: entry.grapeVarieties.joined(separator: ", ")) }
                LabeledContent("タイプ", value: entry.wineType.displayName)
                if let volume = entry.volumeML { LabeledContent("容量", value: "\(volume)mL") }
                if let alcohol = entry.alcoholPercent { LabeledContent("アルコール", value: alcohol.formatted(.number.precision(.fractionLength(1))) + "%") }
                LabeledContent("ボトル形状", value: entry.bottleShape.displayName)
            }

            Section("体験") {
                LabeledContent("テイスティング", value: "\(entry.tastingCount)件")
                if let rating = entry.ratingSummary { LabeledContent("平均評価", value: "★ " + rating.formatted(.number.precision(.fractionLength(1))) + " / 5") }
                if !entry.tags.isEmpty { LabeledContent("タグ", value: entry.tags.joined(separator: ", ")) }
                HStack {
                    Button("テイスティングを追加") { showingTasting = true }
                    Spacer()
                    Button("料理ペアリング") { showingPairing = true }
                }
            }

            Section("表示") {
                NavigationLink {
                    BottlePreviewView(
                        displayName: entry.displayName,
                        bottleImageData: thumbnailImageData()
                    )
                } label: {
                    Label("ボトルを表示", systemImage: "wineglass")
                }
                Text("写真から抽出したボトルを、同じ大きさと基準位置で表示します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let note = entry.note, !note.isEmpty {
                Section("メモ") { Text(note) }
            }
        }
        .navigationTitle("Wine Detail")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("編集") { showingEdit = true }
                    Divider()
                    Button("削除", role: .destructive) { showingDeleteConfirmation = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingTasting) { TastingFormView { draft in store.addTasting(to: entry.id, draft: draft) } }
        .sheet(isPresented: $showingPairing) { PairingFormView { draft in store.addPairing(to: entry.id, draft: draft) } }
        .sheet(isPresented: $showingEdit) { BottleEditView(store: store, entry: entry) }
        .confirmationDialog("このボトルを削除しますか？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("削除", role: .destructive) { store.delete(id: entry.id) }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private func thumbnailImageData() -> Data? {
        if let thumbnailAssetID = entry.thumbnailAssetID,
           let storedData = try? store.repository.loadImageData(for: thumbnailAssetID) {
            return BottleImageNormalizer().normalizeForDisplay(data: storedData) ?? storedData
        }
        guard let sourceImageAssetID = entry.sourceImageAssetID else { return nil }
        return try? store.repository.loadImageData(for: sourceImageAssetID)
    }

}

struct BottleEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CellarStore
    let entry: CellarEntry
    @State private var storageLocation: String
    @State private var remaining: String
    @State private var note: String

    init(store: CellarStore, entry: CellarEntry) {
        self.store = store
        self.entry = entry
        _storageLocation = State(initialValue: entry.storageLocation ?? "")
        _remaining = State(initialValue: entry.remainingPercent.map(String.init) ?? "")
        _note = State(initialValue: entry.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("保管場所", text: $storageLocation)
                TextField("残量（%）", text: $remaining).keyboardType(.numberPad)
                TextField("メモ", text: $note, axis: .vertical).lineLimit(3...8)
            }
            .navigationTitle("ボトルを編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.update(bottleID: entry.id, storageLocation: storageLocation, note: note, remainingPercent: Int(remaining))
                        dismiss()
                    }
                }
            }
        }
    }
}
