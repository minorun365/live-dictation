# 文字起こしくん

日本語の会議を文字起こし・要約するmacOSアプリです。英語を日本語へ翻訳するモードも備えています。Appleの音声認識・翻訳・生成モデルを使い、録音とログはMac内だけに保存します。

## 動作環境

- macOS 26.4以降
- Apple Silicon Mac
- 要約にはApple Intelligenceを使用します
- 初回のモデル取得にインターネット接続が必要になる場合があります

## インストール

1. [Releases](https://github.com/minorun365/live-dictation/releases/latest)から`live-dictation-v1.2.1-macos-arm64.zip`をダウンロードします。
2. ZIPを展開し、`文字起こしくん.app`を「アプリケーション」フォルダへ移動します。
3. 一度起動したあと、macOSの「システム設定」→「プライバシーとセキュリティ」→「このまま開く」を選びます。
4. 起動後、マイクと画面収録の利用を許可します。画面収録の許可後にmacOSから再起動を求められた場合は、アプリを開き直します。

この配布版はAppleの公証を行っていないため、初回のみ手順3が必要です。詳しくは[Appleの案内](https://support.apple.com/ja-jp/102445)を参照してください。GitHubの「Code」から取得できるZIPはソースコードであり、アプリ本体ではありません。

## 使い方

上部でモードを選び、「録音を開始」を押します。日本語モードは日本語文字起こしと要約、英語モードは英語文字起こし・日本語訳・要約を表示します。左の履歴には、会議全体から生成した短い日本語タイトルが新しい順に並びます。履歴を選ぶと、保存済みの全文と要約を読み返せます。

保存先：`~/Library/Application Support/LiveTranslator/Sessions/`

セッションごとに録音音声、Markdownの文字起こし、直近5分の要約、時刻付きイベント、録音中の画面を保存します。録音開始と同時にメインディスプレイ全体を自動取得し、1秒ごとのJPEG画像として `screenshots/` に記録します。画面取得に失敗した場合も、音声録音と文字起こしは継続します。

`screenshots/timeline.md` には、画面が変化した時点と30秒ごとの代表画像だけを時系列でまとめます。全画像の撮影時刻は `screenshots/index.jsonl`、代表画像の一覧は `screenshots/representatives.jsonl` で確認できます。MarkdownはClaude Codeなどからそのまま読み込めます。外部サーバーへ送信するコードは含みません。録音対象者や主催者の許可を得たうえで使用してください。

## ソースからビルド

macOS 26.4 SDKとSwift 6.2以降が必要です。

```bash
./scripts/build-app.sh
open dist/文字起こしくん.app
```

配布用ZIPは`./scripts/package-release.sh`で作成できます。

## License

[MIT License](LICENSE)
