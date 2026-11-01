# Cork sync v1

JSONはcamelCase、日時はタイムゾーン付きISO 8601、IDはUUIDです。サーバーはUUIDを小文字に正規化します。認証済みトークンのissuerとsubから所有者を特定し、本文のユーザーIDは受け付けません。

## 操作

`POST /v1/operations` に `{ operationID, bottleID, baseVersion, action }` を送ります。

| action.kind | 内容 | version |
| --- | --- | --- |
| create | `bottle` に個別ボトル全体 | 0。既存ID・削除済みIDは拒否 |
| import | 固定スナップショットの `bottle` | 0。同一内容の既存IDは既存の結果を返す。異なる内容は競合 |
| patch | `patch: { storageLocation?, note?, remainingPercent? }` | 直前に確認した値 |
| state | `state`, `eventID`, 任意の`occurredAt` | 直前に確認した値 |
| tasting | ID付きの`tasting` | 直前に確認した値 |
| pairing | ID付きの`pairing` | 直前に確認した値 |
| delete | 追加フィールドなし | 直前に確認した値 |

成功は `{ bottleID, version, bottle, cursor }` です。削除時のbottleはnullです。operationIDの再送は同じ内容で行い、version確認より前に保存済みの結果を返します。内容が変われば`OPERATION_ID_REUSED`です。カーソルはセラー内の確定順、versionはそのボトルを最後に更新したログ位置です。

`GET /v1/bottles/:id` は同じ形式です。HTTP 409の`VERSION_CONFLICT`には存在する場合`current`を付けます。削除済みIDでは`current.bottle`がnullです。HTTP 400は`VALIDATION_ERROR`、401は`AUTH_REQUIRED`、403は`FORBIDDEN`、404は`NOT_FOUND`です。

## 差分

`GET /v1/changes?after=0&limit=50` は `{ changes: [成功と同じ形式], nextCursor, until, hasMore }` を返します。後続ページに同じuntilを指定します。差分・確定済み状態・nextCursorを同時に永続化してから次へ進みます。操作送信の成功だけで取得用カーソルを進めてはいけません。他端末の変更が途中に存在するためです。

`POST /v1/ack` の `{ cursor }` は適用・永続化済みのカーソルだけを報告します。`GET /v1/sync-status` はrevision、deviceCursor、deviceSyncedAtを返します。初期版の端末同期時点は最後の端末報告です。

## 個別ボトル

正確なスキーマは `server/cork-service/src/contracts.ts` のbottleSchemaです。ワイン情報と個別ボトルを1つの集約として同期し、tastings・pairings・eventsはID付き配列にします。

- 必須: id、wineID、cellarID、name、wineType、lifecycleState、bottleShape、createdAt、updatedAt、tastings、pairings、events。
- 任意: producer、region、country、grapeVarieties、vintage、volumeML、alcoholPercent、storageLocation、acquiredAt、openedAt、finishedAt、remainingPercent、note。
- 任意の単値は省略時null。patchは省略で維持、明示nullで消去。
- 画像・購入価格・OCR情報・端末ファイル参照は同期しません。DTOの未知フィールドは拒否します。
- テイスティング: id、tastedAt、rating、acidity、sweetness、tannin、body、alcohol、finish、aromaTags、palateTags、note、servingTemperatureCelsius、openedHoursBeforeTasting。
- ペアリング: id、tastingID、dishName、dishCategory、score、note。
- 状態履歴: id、fromState、toState、occurredAt、note。

1ユーザーの変更をDB行ロックで直列化し、対象データ・ログ・確定位置・再送結果を同じトランザクションで保存します。履歴・操作結果・削除記録は初期版で自動削除しません。
