import SwiftUI
import Translation

@available(macOS 26.4, *)
struct ContentView: View {
    @ObservedObject var model: AppModel

    private let translationConfiguration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "ja")
    )

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle()
                    .fill(model.isRecording ? Color.red : Color.secondary.opacity(0.45))
                    .frame(width: 9, height: 9)

                Text(model.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("保存先を開く") {
                    model.openSessionsFolder()
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("保存先を開く")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            Divider()

            TranscriptHistory(model: model)
                .padding(18)

            Divider()

            HStack {
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }

                Spacer()

                Button {
                    Task {
                        await model.toggleRecording()
                    }
                } label: {
                    Label(
                        model.isRecording ? "停止" : "録音を開始",
                        systemImage: model.isRecording ? "stop.fill" : "mic.fill"
                    )
                    .frame(minWidth: 112)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(model.isRecording ? .red : .accentColor)
                .accessibilityLabel(model.isRecording ? "録音を停止" : "録音を開始")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
        .translationTask(translationConfiguration) { session in
            await model.runTranslationLoop(with: session)
        }
        .onDisappear {
            model.stopRecordingIfNeeded()
        }
    }
}

@available(macOS 26.4, *)
struct TranscriptHistory: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            TranscriptPane(title: "English", text: model.englishText)
            TranscriptPane(title: "日本語", text: model.japaneseText)
            TranscriptPane(title: "直近5分の要約", text: model.summaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TranscriptPane: View {
    let title: String
    let text: String

    @State private var followsLatest = true

    private let bottomID = "transcript-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(text)
                            .font(.system(size: 19))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    .padding(16)
                }
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    guard newPhase == .idle else { return }
                    guard oldPhase == .tracking || oldPhase == .interacting || oldPhase == .decelerating else {
                        return
                    }
                    followsLatest = context.geometry.visibleRect.maxY >= context.geometry.contentSize.height - 32
                }
                .onChange(of: text) { _, _ in
                    guard followsLatest else { return }
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
