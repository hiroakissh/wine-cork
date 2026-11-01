import SwiftUI
import UIKit

struct BottlePreviewView: View {
    let displayName: String
    let bottleImageData: Data?

    var body: some View {
        Group {
            if let image = bottleImageData.flatMap(UIImage.init(data:)) {
                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .shadow(color: .black.opacity(0.16), radius: 14, y: 8)
                        .accessibilityLabel("\(displayName)のボトル画像")
                }
            } else {
                ContentUnavailableView(
                    "ボトル画像がありません",
                    systemImage: "wineglass",
                    description: Text("ボトル写真を登録すると、切り抜いた画像をここに表示できます。")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
        .navigationTitle("ボトル")
        .navigationBarTitleDisplayMode(.inline)
    }
}
