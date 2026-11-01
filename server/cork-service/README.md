# Cork MCP / sync service

ChatGPTとCork iOSから同じワインデータを操作するTypeScriptサーバーです。OpenAI推論APIは呼び出さないため、OpenAI APIキーは使いません。

## ローカル起動

Node.js 22以上（CIは24）、PostgreSQL 17、OAuth認証基盤が必要です。

```sh
cd server/cork-service
npm ci
docker compose up -d
cp .env.example .env
# .envのCORK_ISSUERを認証基盤のissuerに変更
npm run dev
```

起動時にDBスキーマを作成します。既存DBの破棄やデータ初期化は行いません。開発時のHTTPはlocalhost/127.0.0.1に限り、公開時はCORK_PUBLIC_URLを実際のHTTPS originへ変更してください。リバースプロキシは元のHostヘッダーを保持します。

## 認証基盤の設定

認証基盤の契約やアカウント作成・公開デプロイはこのリポジトリでは行いません。既存または新規のOAuth基盤で次を設定してください。

1. OIDC discovery、JWKS、Authorization Code + PKCE S256、resource/audienceに対応。
2. `cellar:read` と `cellar:write` のscopeを許可。
3. resource/audienceを `CORK_PUBLIC_URL + /mcp` に一致させる。
4. ChatGPTのCIMD・DCRまたは事前登録クライアントを設定。認証管理画面に表示される正確なリダイレクトURIを登録。
5. iOS用のpublic clientを登録し、リダイレクトURIを `cork://oauth/callback` に設定。refresh tokenとトークン失効の運用を設定。

サーバーはRS256/ES256署名、issuer、audience、有効期限、sub、iat、scopeを検証します。トークンを持たない接続を許可する開発バイパスはありません。ChatGPTの認可を止める場合はChatGPTの接続解除と認証基盤のgrant失効を行ってください。iOSの同期停止だけでは他クライアントの認可は失効しません。

## ChatGPTに追加

1. サーバーをHTTPSで公開し、`/.well-known/oauth-protected-resource` が参照できることを確認。
2. ChatGPTのPluginsからカスタムMCPを追加し、`https://公開ホスト/mcp` とOAuth認証を指定。
3. Corkをインストールし、同じCorkアカウントで認可。
4. 新しい会話で `@Cork` を選び、「未開栓の赤ワインを見せて」などで確認。

利用できるアカウント・ワークスペース・画面には制約があるため、実アカウントでの確認が必要です。一般向けディレクトリ公開は別途審査が必要です。

## 検証

```sh
npm run check
npm test
npm run build
```

ローカルのDBテストはPGliteを使います。実PostgreSQLでは `TEST_DATABASE_URL` を指定して同じテストを実行すると、別コネクションでのロック・並行更新も検証します。GitHub ActionsはPostgreSQL 17を起動してこの経路を実行します。JWT署名検証、HTTP認可、SDKのMCPクライアントからのツール選択と再送もテストします。

APIの契約は [sync-v1.md](../../contracts/sync-v1.md) を参照してください。ログにトークンやワインの本文を出力せず、DB・バックアップ・TLSの運用はホスティング環境で設定します。
