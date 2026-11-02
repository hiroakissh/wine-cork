import SwiftUI

struct StorageRecoveryView: View {
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("データを開けませんでした", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("保存済みデータを保護するため、編集と同期を停止しています。空き容量を確認して再試行してください。保存済みデータは削除されません。")
        } actions: {
            Button("再試行", action: retry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("storage.retry")
        }
    }
}
