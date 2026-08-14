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
        HStack(spacing: 0) {
            SessionSidebar(model: model)
                .frame(width: 250)

            Divider()

            mainContent
        }
        .translationTask(translationConfiguration) { session in
            await model.runTranslationLoop(with: session)
        }
        // Closing the window no longer stops the recording. A meeting can run long after
        // the window is out of the way, and the app stays alive in the menu bar, so
        // stopping here would cut recordings short. Quitting still stops it.
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(model.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()

                Picker(
                    "文字起こしモード",
                    selection: Binding(
                        get: { model.selectedMode },
                        set: { model.selectMode($0) }
                    )
                ) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
                .disabled(model.isRecording)

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
                .tint(model.isRecording ? .gray : .accentColor)
                .accessibilityLabel(model.isRecording ? "録音を停止" : "録音を開始")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
    }
}

@available(macOS 26.4, *)
private struct SessionSidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("セッション")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    SidebarButton(
                        title: "現在の文字起こし",
                        subtitle: model.isRecording ? "録音中" : nil,
                        systemImage: "waveform",
                        isSelected: model.selectedSessionID == nil
                    ) {
                        model.showCurrentSession()
                    }

                    if !model.sessionHistory.isEmpty {
                        Text("履歴")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                    }

                    ForEach(model.sessionHistory) { item in
                        SidebarButton(
                            title: item.title,
                            subtitle: "\(item.displayDate)・\(item.mode.label)",
                            systemImage: "text.document",
                            isSelected: model.selectedSessionID == item.id
                        ) {
                            model.selectSession(item)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SidebarButton: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@available(macOS 26.4, *)
struct TranscriptHistory: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            if model.displayedMode == .englishTranslation {
                TranscriptPane(title: "English", text: model.displayedEnglishText)
            }
            TranscriptPane(
                title: model.displayedMode == .japanese ? "日本語文字起こし" : "日本語",
                text: model.displayedJapaneseText
            )
            TranscriptPane(title: "直近5分の要約", text: model.displayedSummaryText)
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
