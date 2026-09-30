# 文字起こしちゃん

日本語の会議を文字起こし・要約するmacOSアプリです。マイクの音声と、ZoomやGoogle MeetなどMacから再生される相手の音声を一緒に収録し、日本語モードではどちらの発言かを分けて記録します。英語を日本語へ翻訳するモードも備えています。Appleの音声認識・翻訳・生成モデルを使い、録音とログはMac内だけに保存します。

## 動作環境

macOS 26.4以降のApple Silicon Mac。要約にApple Intelligenceを使います。

## インストール

1. [Releases](https://github.com/minorun365/live-dictation/releases/latest)から`live-dictation-v1.4.4-macos-arm64.zip`をダウンロードします。
2. ZIPを展開し、`文字起こしちゃん.app`を「アプリケーション」フォルダへ移動します。
3. 一度起動したあと、macOSの「システム設定」→「プライバシーとセキュリティ」→「このまま開く」を選びます。
4. 起動後、マイクと画面収録の利用を許可します。再起動を求められたら、アプリを開き直します。

この配布版はAppleの公証を行っていないため、初回のみ手順3が必要です（[Appleの案内](https://support.apple.com/ja-jp/102445)）。GitHubの「Code」から取得できるZIPはソースコードであり、アプリ本体ではありません。

## 使い方

上部でモードを選び、「録音を開始」を押します。Web会議が始まると自動で録音も始まります。左の履歴から、過去の会議の全文と要約を読み返せます。

| モード | 想定する場面 | 表示されるもの |
|---|---|---|
| 日本語 | 日本語のWeb会議 | 話者を分けた文字起こしと要約 |
| 英語 | 英語のWeb会議 | 英語の文字起こし、日本語訳、要約 |
| 対面 | 同じ部屋で交わす会話 | 文字起こしと要約 |

日本語モードで話者を分けるには、ヘッドホンを使ってください。スピーカーで相手の声を鳴らすと、マイクにも入って自分の発言として記録されます。

録音とログは `~/Library/Application Support/LiveTranslator/Sessions/` に保存され、外部サーバーへは送りません。録音対象者や主催者の許可を得たうえで使用してください。

自動録音の条件、対面会議のリマインド、保存されるファイルなどの詳細は [動作の詳細](docs/behavior.md) にまとめています。

## ソースからビルド

macOS 26.4 SDKとSwift 6.2以降が必要です。

```bash
./scripts/build-app.sh
open dist/文字起こしちゃん.app
```

配布用ZIPは`./scripts/package-release.sh`で作成できます。

## License

Source code is licensed under the [MIT License](LICENSE).

The application icon uses an illustration from いらすとや
and is subject to the [いらすとや terms of use](https://www.irasutoya.com/p/terms.html).
It is not licensed under the MIT License.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for details.
