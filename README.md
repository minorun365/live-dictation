# 文字起こしちゃん

日本語の会議を文字起こし・要約するmacOSアプリです。マイクの音声と、ZoomやGoogle MeetなどMacから再生される相手の音声を一緒に収録し、日本語モードではどちらの発言かを分けて記録します。英語を日本語へ翻訳するモードも備えています。Appleの音声認識・翻訳・生成モデルを使い、録音とログはMac内だけに保存します。

## 動作環境

macOS 26.4以降のApple Silicon Mac。要約にApple Intelligenceを使います。

## インストール

1. [Releases](https://github.com/minorun365/live-dictation/releases/latest)から`live-dictation-v1.4.2-macos-arm64.zip`をダウンロードします。
2. ZIPを展開し、`文字起こしちゃん.app`を「アプリケーション」フォルダへ移動します。
3. 一度起動したあと、macOSの「システム設定」→「プライバシーとセキュリティ」→「このまま開く」を選びます。
4. 起動後、マイクと画面収録の利用を許可します。再起動を求められたら、アプリを開き直します。

この配布版はAppleの公証を行っていないため、初回のみ手順3が必要です（[Appleの案内](https://support.apple.com/ja-jp/102445)）。GitHubの「Code」から取得できるZIPはソースコードであり、アプリ本体ではありません。

## 使い方

上部でモードを選び、「録音を開始」を押します。左の履歴から、過去の会議の全文と要約を読み返せます。

| モード | 想定する場面 | 表示されるもの |
|---|---|---|
| 日本語 | 日本語のWeb会議 | 話者を分けた文字起こしと要約 |
| 英語 | 英語のWeb会議 | 英語の文字起こし、日本語訳、要約 |
| 対面 | 同じ部屋で交わす会話 | 文字起こしと要約 |

対面モードは全員の声が1本のマイクへ入るため、話者は分けません。画面の記録も行いません。

ウィンドウを閉じてもアプリはメニューバーに残り、会議の検知を続けます。アイコンから状態の確認、録音の開始と停止、ウィンドウの再表示ができます。待機中は眠っている絵、録音中はメモを取る絵になります。「対面会議を開始」を選ぶと、ウィンドウを開かずに対面モードで録音を始められます（このときウィンドウで選んでいるモードは変わらないので、次のWeb会議は日本語モードのまま自動で始まります）。終了は⌘Qです。

日本語モードは行頭に「自分：」「相手：」を付けます。マイクとMacの再生音をそれぞれ別の音声認識にかけているだけで、声を聞き分けてはいません。そのためスピーカーで相手の声を鳴らすとマイクにも入り、同じ発言が自分の側にも記録されます。ヘッドホンの利用をおすすめします。

### 自動で録音が始まる条件

会議アプリがマイクを使い始めると録音を開始し、そのアプリがマイクを離してから1分で停止します。

- 対象はZoom、Microsoft Teams、Webex、Slackのハドル、Discord
- ブラウザーのGoogle Meetなどは、マイクと再生の両方を使っているときだけ会議とみなします
- 音声入力アプリやmacOSの音声認識では始まりません
- 「手動で録音開始」で自分から始めた録音は、会議アプリの状態では停止しません。止め忘れに備えて3時間で自動停止します

## 保存されるもの

`~/Library/Application Support/LiveTranslator/Sessions/` の下に、セッションごとのフォルダを作ります。

- 録音音声（日本語モードは自分と相手を別ファイルに分けます）
- Markdownの文字起こしと要約
- 録音中のメインディスプレイを1秒ごとに撮った `screenshots/`

`screenshots/timeline.md` には画面が変化した時点をまとめてあり、Claude Codeなどからそのまま読み込めます。外部サーバーへ送信するコードは含みません。録音対象者や主催者の許可を得たうえで使用してください。

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
