import Foundation

@main
struct TranscriptChunkerSelfTest {
    static func main() {
        // 空文字は空の配列
        expect(TranscriptChunker.chunks(of: "").isEmpty, "空文字はチャンクなし")

        // 短い複数行は行ごとに分かれ、元の文字列へ戻せる
        let lines = "自分：こんにちは\n相手：よろしくお願いします"
        let lineChunks = TranscriptChunker.chunks(of: lines)
        expect(lineChunks.map(\.text) == ["自分：こんにちは", "相手：よろしくお願いします"], "行ごとに分かれる")
        expect(lineChunks.map(\.startsParagraph) == [true, true], "各行が段落の先頭")
        expect(TranscriptChunker.reconstruct(lineChunks) == lines, "行の分割を元へ戻せる")

        // 改行のない長い日本語は文の切れ目で分かれ、上限を超えない
        let sentence = String(repeating: "あ", count: 30) + "。"
        let longJapanese = String(repeating: sentence, count: 100)
        let japaneseChunks = TranscriptChunker.chunks(of: longJapanese, targetLength: 100, maxLength: 200)
        expect(japaneseChunks.count > 1, "長い日本語は複数に分かれる")
        expect(japaneseChunks.allSatisfy { $0.text.count <= 200 }, "日本語の各チャンクは上限以下")
        expect(japaneseChunks.dropLast().allSatisfy { $0.text.hasSuffix("。") }, "日本語は句点で切れる")
        expect(japaneseChunks.first?.startsParagraph == true, "最初のチャンクは段落の先頭")
        expect(japaneseChunks.dropFirst().allSatisfy { !$0.startsParagraph }, "続きのチャンクは段落の先頭ではない")
        expect(TranscriptChunker.reconstruct(japaneseChunks) == longJapanese, "日本語の分割を元へ戻せる")

        // 英語は文末の空白の後で切れ、次のチャンクが空白で始まらない
        let longEnglish = String(repeating: "This is a sentence. ", count: 50)
        let englishChunks = TranscriptChunker.chunks(of: longEnglish, targetLength: 60, maxLength: 120)
        expect(englishChunks.count > 1, "長い英語は複数に分かれる")
        expect(englishChunks.allSatisfy { !$0.text.hasPrefix(" ") }, "英語のチャンクは空白で始まらない")
        expect(TranscriptChunker.reconstruct(englishChunks) == longEnglish, "英語の分割を元へ戻せる")

        // 文の切れ目がなければ空白で、空白もなければ上限で切る
        let words = String(repeating: "word ", count: 100)
        let wordChunks = TranscriptChunker.chunks(of: words, targetLength: 20, maxLength: 40)
        expect(wordChunks.allSatisfy { $0.text.count <= 40 }, "単語列の各チャンクは上限以下")
        expect(wordChunks.dropLast().allSatisfy { $0.text.hasSuffix(" ") }, "単語の途中で切らない")
        expect(TranscriptChunker.reconstruct(wordChunks) == words, "単語列の分割を元へ戻せる")

        let noBreak = String(repeating: "あ", count: 1_000)
        let noBreakChunks = TranscriptChunker.chunks(of: noBreak, targetLength: 100, maxLength: 200)
        expect(noBreakChunks.allSatisfy { $0.text.count <= 200 }, "切れ目なしでも上限以下")
        expect(TranscriptChunker.reconstruct(noBreakChunks) == noBreak, "切れ目なしの分割を元へ戻せる")

        // 空行と末尾の改行も保つ
        let blank = "一行目\n\n三行目\n"
        expect(TranscriptChunker.reconstruct(TranscriptChunker.chunks(of: blank)) == blank, "空行を保つ")

        // 末尾だけが変わっても、それより前のチャンクは変わらない（表示の差分を小さく保つ）
        let base = String(repeating: sentence, count: 20)
        let before = TranscriptChunker.chunks(of: base + "途中", targetLength: 100, maxLength: 200)
        let after = TranscriptChunker.chunks(of: base + "途中の発話が伸びた", targetLength: 100, maxLength: 200)
        expect(Array(before.dropLast().map(\.text)) == Array(after.prefix(before.count - 1).map(\.text)), "前のチャンクは安定")

        print("TranscriptChunkerSelfTest passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            fatalError("失敗: \(message)")
        }
    }
}
