# Live Translator

Macのマイクで英語を文字起こしし、リアルタイムに日本語へ翻訳・要約するmacOSアプリです。Appleの音声認識・翻訳・生成モデルを使い、録音とログはMac内だけに保存します。

## 動作環境

- macOS 26.4以降
- Apple Silicon Mac
- 要約にはApple Intelligenceを使用します
- 初回のモデル取得にインターネット接続が必要になる場合があります

## インストール

1. [Releases](https://github.com/minorun365/live-translator-macos/releases/latest)から`LiveTranslator-v1.1.0-macos-arm64.zip`をダウンロードします。
2. ZIPを展開し、`LiveTranslator.app`を「アプリケーション」フォルダへ移動します。
3. 一度起動したあと、macOSの「システム設定」→「プライバシーとセキュリティ」→「このまま開く」を選びます。
4. 起動後、マイクの利用を許可します。

この配布版はAppleの公証を行っていないため、初回のみ手順3が必要です。詳しくは[Appleの案内](https://support.apple.com/ja-jp/102445)を参照してください。GitHubの「Code」から取得できるZIPはソースコードであり、アプリ本体ではありません。

## 使い方

「録音を開始」を押すと、英語、日本語、直近5分の要約が3列で表示されます。英語と日本語は全文を表示し続け、要約は30秒ごとに更新します。上へスクロールすると過去の文章を読み返せます。「停止」を押すと録音とログが保存されます。

保存先：`~/Library/Application Support/LiveTranslator/Sessions/`

セッションごとに録音音声、文字起こし、翻訳、直近5分の要約、時刻付きイベントを保存します。外部サーバーへ送信するコードは含みません。録音対象者や主催者の許可を得たうえで使用してください。

## ソースからビルド

macOS 26.4 SDKとSwift 6.2以降が必要です。

```bash
./scripts/build-app.sh
open dist/LiveTranslator.app
```

配布用ZIPは`./scripts/package-release.sh`で作成できます。

## License

[MIT License](LICENSE)
