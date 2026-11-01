# Cork

端末内でワインボトルを管理するSwiftUIアプリです。iOS/iPadOS 26以上を対象に、SwiftDataへCellarEntryを保存します。

## 起動

XcodeGenがインストールされている環境では、次の順でプロジェクトを生成して開きます。

```sh
xcodegen generate
open Cork.xcodeproj
```

実機でカメラを使う場合は、XcodeのSigning設定で開発チームを指定してください。

## 現在の実装範囲

- Cellar一覧、検索、状態フィルタ、並び替え
- 写真ライブラリ／カメラからの画像入力と端末内保存
- 手入力によるワイン登録・編集・削除
- Vision OCR候補表示・基本項目反映・認識結果保存、画像正規化
- OCR候補からの基本項目反映、ボトル範囲／ラベル四隅の手動補正
- VisionKit標準の被写体選択（長押し）によるボトル範囲補正
- Visionの高解像度インスタンスマスクからボトル輪郭を抽出し、形状分類へ利用
- ラベル検出に失敗した場合のラベル画像手動選択とカメラ権限拒否時の代替導線
- ボトル形状分類ロジックと6種のテンプレートID
- スキャン時の形状候補自動反映（低信頼時は手動選択）
- 写真から抽出したボトルの正規化プレビュー
- Owned / Opened / Finishedの状態管理と履歴
- テイスティング、料理ペアリング、Taste Profile集計
- SwiftDataのV1スキーマとローカルメディア管理
- SettingsからのJSONバックアップ書き出し／読み込み（画像データを含む）
- 抽出ボトルの透明余白・傾き・表示高さ・下端位置の統一
- Cellar一覧と詳細画面でのアスペクト比を保ったボトル表示
- Cellar一覧のライフサイクル／ワインタイプフィルタ
- Cellar一覧の保存済みボトル切り抜き／ラベル／原画像サムネイル
- WWDC23のVisionKit被写体リフトとVisionインスタンスマスクを使ったボトル輪郭の抽出・保存

Foundation Models、Precision Scan、Discover / Recommendation、専用USDZ資産は後続フェーズです。

## 検証

```sh
xcodebuild -project Cork.xcodeproj -scheme Cork \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  CODE_SIGNING_ALLOWED=NO test
```
