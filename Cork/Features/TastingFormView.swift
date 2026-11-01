import SwiftUI

struct TastingFormView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (TastingDraft) -> Void
    @State private var rating = 0
    @State private var acidity = 3
    @State private var sweetness = 3
    @State private var tannin = 3
    @State private var bodyScore = 3
    @State private var aromaTags = ""
    @State private var palateTags = ""
    @State private var note = ""
    @State private var tastedAt = Date.now

    var body: some View {
        NavigationStack {
            Form {
                Section("評価") {
                    Stepper("総合評価: \(rating == 0 ? "未入力" : "\(rating) / 5")", value: $rating, in: 0...5)
                    ScoreStepper(title: "酸味", value: $acidity)
                    ScoreStepper(title: "甘味", value: $sweetness)
                    ScoreStepper(title: "タンニン", value: $tannin)
                    ScoreStepper(title: "ボディ", value: $bodyScore)
                }
                .listRowBackground(Color("CellarSurface"))
                Section("記録") {
                    DatePicker("飲用日時", selection: $tastedAt)
                    TextField("香りタグ（カンマ区切り）", text: $aromaTags)
                    TextField("味わいタグ（カンマ区切り）", text: $palateTags)
                    TextField("ノート", text: $note, axis: .vertical).lineLimit(4...10)
                }
                .listRowBackground(Color("CellarSurface"))
            }
            .scrollContentBackground(.hidden)
            .background(Color("CellarBackground"))
            .tint(Color.accentColor)
            .navigationTitle("テイスティング")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(TastingDraft(
                            rating: rating == 0 ? nil : rating,
                            acidity: acidity,
                            sweetness: sweetness,
                            tannin: tannin,
                            body: bodyScore,
                            alcohol: nil,
                            finish: nil,
                            aromaTags: parseTags(aromaTags),
                            palateTags: parseTags(palateTags),
                            note: note.nilIfBlank,
                            tastedAt: tastedAt,
                            servingTemperatureCelsius: nil,
                            openedHoursBeforeTasting: nil
                        ))
                        dismiss()
                    }
                }
            }
        }
        .presentationBackground(Color("CellarBackground"))
    }

    private func parseTags(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

private struct ScoreStepper: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        Stepper("\(title): \(value) / 5", value: $value, in: 0...5)
    }
}

struct PairingFormView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (PairingDraft) -> Void
    @State private var dishName = ""
    @State private var category = ""
    @State private var score = 3
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("料理名", text: $dishName)
                    TextField("カテゴリ", text: $category)
                    Stepper("相性: \(score) / 5", value: $score, in: 1...5)
                    TextField("メモ", text: $note, axis: .vertical).lineLimit(3...8)
                }
                .listRowBackground(Color("CellarSurface"))
            }
            .scrollContentBackground(.hidden)
            .background(Color("CellarBackground"))
            .tint(Color.accentColor)
            .navigationTitle("料理ペアリング")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard !dishName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        onSave(PairingDraft(dishName: dishName, dishCategory: category.nilIfBlank, score: score, note: note.nilIfBlank))
                        dismiss()
                    }
                    .disabled(dishName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationBackground(Color("CellarBackground"))
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
