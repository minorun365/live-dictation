import Foundation

/// 文字起こし全文を表示用の短いかたまりへ分ける。
///
/// 全文をひとつの `Text` に入れると、更新のたびに全文の字詰めをやり直すため、
/// 録音が長くなるほどメインスレッドを占有する。かたまりに分けて `LazyVStack` に並べれば、
/// 画面に見えている分だけを組めば済む。
struct TranscriptChunk: Equatable {
    let text: String
    /// 元の文字列で改行の直後（または先頭）から始まるかどうか。
    let startsParagraph: Bool
}

enum TranscriptChunker {
    private static let sentenceEnds: Set<Character> = ["。", "！", "？", "．"]
    private static let latinSentenceEnds: Set<Character> = [".", "!", "?"]

    /// - Parameters:
    ///   - targetLength: この文字数を超えたら、次の文の切れ目で分ける。
    ///   - maxLength: 文の切れ目がなくても、この文字数を超えないように分ける。
    static func chunks(
        of text: String,
        targetLength: Int = 300,
        maxLength: Int = 600
    ) -> [TranscriptChunk] {
        guard !text.isEmpty else { return [] }

        var result: [TranscriptChunk] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let pieces = split(
                Array(paragraph),
                targetLength: targetLength,
                maxLength: maxLength
            )
            for (index, piece) in pieces.enumerated() {
                result.append(TranscriptChunk(text: piece, startsParagraph: index == 0))
            }
        }
        return result
    }

    static func reconstruct(_ chunks: [TranscriptChunk]) -> String {
        var text = ""
        for (index, chunk) in chunks.enumerated() {
            if chunk.startsParagraph, index > 0 {
                text += "\n"
            }
            text += chunk.text
        }
        return text
    }

    private static func split(
        _ characters: [Character],
        targetLength: Int,
        maxLength: Int
    ) -> [String] {
        guard !characters.isEmpty else { return [""] }

        var pieces: [String] = []
        var start = 0
        var lastSpaceEnd: Int?

        var index = 0
        while index < characters.count {
            let character = characters[index]
            let end = index + 1
            let length = end - start

            if character == " " {
                lastSpaceEnd = end
            }

            let endsSentence = sentenceEnds.contains(character)
                || (character == " " && index > start && latinSentenceEnds.contains(characters[index - 1]))

            if length >= targetLength, endsSentence {
                pieces.append(String(characters[start..<end]))
                start = end
                lastSpaceEnd = nil
            } else if length >= maxLength {
                let cut = lastSpaceEnd.flatMap { $0 > start ? $0 : nil } ?? end
                pieces.append(String(characters[start..<cut]))
                start = cut
                lastSpaceEnd = nil
                if cut < end {
                    // 空白で切った後ろの文字は、次のかたまりとして数え直す
                    index = cut
                    continue
                }
            }
            index += 1
        }

        if start < characters.count {
            pieces.append(String(characters[start...]))
        }
        return pieces
    }
}
