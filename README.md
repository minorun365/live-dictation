# 文字起こしちゃん

日本語の会議を文字起こし・要約するmacOSアプリです。マイクの音声と、ZoomやGoogle MeetなどMacから再生される相手の音声を一緒に収録し、日本語モードではどちらの発言かを分けて記録します。英語を日本語へ翻訳するモードも備えています。Appleの音声認識・翻訳・生成モデルを使い、録音とログはMac内だけに保存します。

## 動作環境

- macOS 26.4以降
- Apple Silicon Mac
- 要約にはApple Intelligenceを使用します
- 初回のモデル取得にインターネット接続が必要になる場合があります

## インストール

1. [Releases](https://github.com/minorun365/live-dictation/releases/latest)から`live-dictation-v1.3.0-macos-arm64.zip`をダウンロードします。
2. ZIPを展開し、`文字起こしちゃん.app`を「アプリケーション」フォルダへ移動します。
3. 一度起動したあと、macOSの「システム設定」→「プライバシーとセキュリティ」→「このまま開く」を選びます。
4. 起動後、マイクと画面収録の利用を許可します。画面収録の許可後にmacOSから再起動を求められた場合は、アプリを開き直します。

この配布版はAppleの公証を行っていないため、初回のみ手順3が必要です。詳しくは[Appleの案内](https://support.apple.com/ja-jp/102445)を参照してください。GitHubの「Code」から取得できるZIPはソースコードであり、アプリ本体ではありません。

## 使い方

上部でモードを選び、「録音を開始」を押します。左の履歴には会議ごとの短いタイトルが新しい順に並び、選ぶと保存済みの全文と要約を読み返せます。

| モード | 想定する場面 | 表示されるもの |
|---|---|---|
| 日本語 | 日本語のWeb会議 | 話者を分けた文字起こしと要約 |
| 英語 | 英語のWeb会議 | 英語の文字起こし、日本語訳、要約 |
| 対面 | 同じ部屋で交わす会話 | 文字起こしと要約 |

対面モードは全員の声が1本のマイクへ入るため、話者は分けません。画面の記録も行いません。

### 自動で録音が始まる条件

会議アプリがマイクを使い始めると録音を開始し、そのアプリがマイクを離してから1分で停止します。

- 対象はZoom、Microsoft Teams、Webex、Slackのハドル、Discord
- ブラウザーのGoogle Meetなどは、マイクと再生の両方を使っているときだけ会議とみなします
- 音声入力アプリやmacOSの音声認識では始まりません
- 「録音を開始」で自分から始めた録音は、自動では停止しません

### メニューバー

ウィンドウを閉じてもアプリはメニューバーに残り、会議の検知を続けます。録音中もウィンドウを閉じられます。アイコンから、いまの状態の確認、録音の開始と停止、ウィンドウの再表示ができます。終了は⌘Qか、メニューの「文字起こしちゃんを終了」です。

Macを再起動しても検知を続けたい場合は、システム設定の「一般」→「ログイン項目と機能拡張」へ文字起こしちゃんを追加してください。

### 話者の分け方

日本語モードは行頭に「自分：」「相手：」を付け、発言者が変わったところで改行します。マイクとMacの再生音をそれぞれ別の音声認識にかけているだけで、声を聞き分けてはいません。そのためスピーカーで相手の声を鳴らすとマイクにも入り、同じ発言が自分の側にも記録されます。ヘッドホンの利用をおすすめします。

## 保存されるもの

`~/Library/Application Support/LiveTranslator/Sessions/` の下に、セッションごとのフォルダを作ります。

- 録音音声。日本語モードは自分の声を `audio-self.m4a`、相手の声を `audio-others.m4a` へ分けて保存します（英語モードは `audio.m4a` の1本）。AACで1分あたり約0.4MBです
- Markdownの文字起こしと、直近5分の要約
- 時刻付きのイベントログ
- 録音中のメインディスプレイを1秒ごとに撮った `screenshots/`

`screenshots/timeline.md` には、画面が変化した時点と30秒ごとの代表画像を時系列でまとめます。Claude Codeなどからそのまま読み込めます。

外部サーバーへ送信するコードは含みません。録音対象者や主催者の許可を得たうえで使用してください。

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
