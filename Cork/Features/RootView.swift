import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct RootView: View {
    @ObservedObject var store: CellarStore

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            TabView {
                CellarView(store: store)
                    .tabItem { Label("Cellar", systemImage: "cabinet") }
                ScanView(store: store)
                    .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
                TasteProfileView(store: store)
                    .tabItem { Label("Taste Profile", systemImage: "chart.bar.xaxis") }
                SettingsView(store: store)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .tint(Color.accentColor)
        }
        .alert("エラー", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("閉じる", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

struct CellarView: View {
    @ObservedObject var store: CellarStore
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if store.entries.isEmpty && !store.isLoading {
                    ContentUnavailableView {
                        Label("Cellarは空です", systemImage: "wineglass")
                    } description: {
                        Text("写真または手入力で、最初の1本を登録しましょう。")
                    } actions: {
                        Button("ワインを登録") { showingAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(store.entries) { entry in
                            NavigationLink(value: entry) {
                                CellarRow(store: store, entry: entry)
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { store.entries[$0].id }.forEach(store.delete)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Cellar")
            .navigationDestination(for: CellarEntry.self) { entry in
                WineDetailView(store: store, entry: entry)
            }
            .searchable(text: $store.searchText, prompt: "名称、産地、品種を検索")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("状態", selection: Binding(get: { store.lifecycleFilter ?? .owned }, set: { newValue in store.lifecycleFilter = newValue; store.refresh() })) {
                            ForEach(BottleLifecycleState.allCases) { state in
                                Text(state.displayName).tag(state)
                            }
                        }
                        Button("すべて") { store.lifecycleFilter = nil; store.refresh() }
                        Picker("タイプ", selection: Binding(get: { store.wineTypeFilter ?? .other }, set: { newValue in store.wineTypeFilter = newValue; store.refresh() })) {
                            ForEach(WineType.allCases) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        Button("タイプをすべて") { store.wineTypeFilter = nil; store.refresh() }
                        Divider()
                        Picker("並び替え", selection: $store.sort) {
                            ForEach(CellarSort.allCases) { sort in
                                Text(sort.displayName).tag(sort)
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("ワインを登録")
                }
            }
            .onChange(of: store.searchText) { _, _ in store.refresh() }
            .onChange(of: store.sort) { _, _ in store.refresh() }
            .refreshable { store.refresh() }
            .sheet(isPresented: $showingAdd) {
                AddWineView(store: store)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

struct CellarRow: View {
    @ObservedObject var store: CellarStore
    let entry: CellarEntry
    @State private var imageData: Data?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.12))
                if let image = imageData.flatMap(UIImage.init(data:)) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                } else {
                    Image(systemName: "wineglass")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 54, height: 78)

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.displayName)
                    .font(.headline)
                    .lineLimit(2)
                if let producer = entry.producer, !producer.isEmpty {
                    Text(producer).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Label(entry.lifecycleState.displayName, systemImage: entry.lifecycleState.systemImage)
                    if let vintage = entry.vintage { Text(String(vintage)) }
                    if let rating = entry.ratingSummary { Text("★ \(rating, specifier: "%.1f")") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .task {
            if let thumbnailAssetID = entry.thumbnailAssetID,
               let storedData = try? store.repository.loadImageData(for: thumbnailAssetID) {
                imageData = BottleImageNormalizer().normalizeForDisplay(data: storedData) ?? storedData
            } else {
                let fallbackAssetID = entry.labelImageAssetID ?? entry.sourceImageAssetID
                imageData = fallbackAssetID.flatMap { try? store.repository.loadImageData(for: $0) } ?? nil
            }
        }
    }
}

struct ScanView: View {
    @ObservedObject var store: CellarStore
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.accentColor)
                Text("ボトルをスキャン")
                    .font(.title2.bold())
                Text("写真を選択して、ラベル情報を確認しながらCellarへ登録します。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("スキャンを開始") { showingAdd = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Scan")
            .sheet(isPresented: $showingAdd) {
                AddWineView(store: store)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

struct TasteProfileView: View {
    @ObservedObject var store: CellarStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.largeTitle)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading) {
                            Text("Taste Profile").font(.title3.bold())
                            Text("テイスティング \(store.profile.tastingCount)件")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !store.profile.hasEnoughData {
                        Text("3件以上記録すると、味覚傾向を表示します。")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("平均スコア") {
                    ProfileMetric(title: "酸味", value: store.profile.averageAcidity)
                    ProfileMetric(title: "甘味", value: store.profile.averageSweetness)
                    ProfileMetric(title: "タンニン", value: store.profile.averageTannin)
                    ProfileMetric(title: "ボディ", value: store.profile.averageBody)
                }
                Section("ばらつき（分散）") {
                    ProfileMetric(title: "酸味", value: store.profile.varianceAcidity)
                    ProfileMetric(title: "甘味", value: store.profile.varianceSweetness)
                    ProfileMetric(title: "タンニン", value: store.profile.varianceTannin)
                    ProfileMetric(title: "ボディ", value: store.profile.varianceBody)
                }
                if !store.profile.favoriteTags.isEmpty {
                    Section("よく登場するタグ") {
                        Text(store.profile.favoriteTags.joined(separator: "  ·  "))
                    }
                }
                if !store.profile.pairingCategories.isEmpty {
                    Section("料理カテゴリ別の相性") {
                        ForEach(store.profile.pairingCategories) { summary in
                            HStack {
                                Text(summary.category)
                                Spacer()
                                Text("★ \(summary.averageScore, specifier: "%.1f")")
                                    .foregroundStyle(.secondary)
                                Text("\(summary.count)件")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Taste Profile")
            .onAppear { store.refresh() }
        }
    }
}

private struct ProfileMetric: View {
    let title: String
    let value: Double?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let value {
                Text("\(value, specifier: "%.1f") / 5")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: CellarStore
    @State private var exportDocument: CorkArchiveDocument?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var transferMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("プライバシー") {
                    Label("データはこの端末に保存されます", systemImage: "lock.shield")
                    Label("ネットワーク接続は必要ありません", systemImage: "wifi.slash")
                }
                Section("アプリ") {
                    LabeledContent("バージョン", value: "v1")
                    LabeledContent("ストレージ", value: "端末内")
                }
                Section("データ移行") {
                    Button {
                        prepareExport()
                    } label: {
                        Label("バックアップを書き出す", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        isImporting = true
                    } label: {
                        Label("バックアップを読み込む", systemImage: "square.and.arrow.down")
                    }
                    Text("ワイン情報、テイスティング、ペアリング、保存済み画像をJSONにまとめます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentTypes: [.json],
            defaultFilename: "Cork-Backup"
        ) { result in
            if case .failure = result {
                transferMessage = "バックアップを書き出せませんでした。"
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else {
                if case .failure = result { transferMessage = "バックアップを読み込めませんでした。" }
                return
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let imported = try store.importArchive(data: data)
                transferMessage = "\(imported.bottlesInserted)本のボトルを読み込みました。"
            } catch {
                transferMessage = error.localizedDescription
            }
        }
        .alert("データ移行", isPresented: Binding(get: { transferMessage != nil }, set: { if !$0 { transferMessage = nil } })) {
            Button("閉じる", role: .cancel) { transferMessage = nil }
        } message: {
            Text(transferMessage ?? "")
        }
    }

    private func prepareExport() {
        do {
            exportDocument = CorkArchiveDocument(data: try store.exportArchiveData())
            isExporting = true
        } catch {
            transferMessage = "バックアップを書き出せませんでした。"
        }
    }
}
