import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showFolderPicker = false
    @AppStorage("startAtEnd") private var startAtEnd = true
    @AppStorage("timestampLines") private var timestampLines = false
    @AppStorage("markupMode") private var markupMode = false

    var body: some View {
        content
            .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    model.folderPicked(url)
                }
            }
            .task { model.launchIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .launching:
            Color.clear

        case .needsFolder(let message):
            folderPrompt(message)

        case .loading(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .editing:
            editor

        case .error(let message):
            errorView(message)
        }
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            PlainTextEditor(text: model.noteText,
                            generation: model.noteGeneration,
                            onTextChange: { model.editorChangedText($0) },
                            startAtEnd: startAtEnd,
                            timestampNewLines: timestampLines,
                            markupMode: markupMode,
                            autoFocus: model.editorNeedsInitialFocus,
                            onAutoFocused: { model.editorNeedsInitialFocus = false })
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Text(model.noteTitle)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .lineLimit(1)

            if model.usedFallbackTemplate {
                Text("built-in template")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if model.saveFailed {
                Text("not saved")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.red, in: Capsule())
            }

            // Square checkbox: live markup rendering (still editable; the
            // caret line reveals its raw markdown)
            Button {
                markupMode.toggle()
            } label: {
                Image(systemName: "book")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(markupMode ? Color.white : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(markupMode ? Color.accentColor : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(markupMode ? Color.accentColor : Color.secondary.opacity(0.5),
                                      lineWidth: 1.5))
            }
            .accessibilityLabel("Markup mode")
            .accessibilityValue(markupMode ? "on" : "off")

            // Square checkbox: stamp each new line with -[HH:MM]
            Button {
                timestampLines.toggle()
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(timestampLines ? Color.white : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(timestampLines ? Color.accentColor : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(timestampLines ? Color.accentColor : Color.secondary.opacity(0.5),
                                      lineWidth: 1.5))
            }
            .accessibilityLabel("Timestamp new lines")
            .accessibilityValue(timestampLines ? "on" : "off")

            Menu {
                Toggle("Open with cursor at end", isOn: $startAtEnd)
                Button("Reload from disk") { model.retry() }
                Button("Change vault folder…") { showFolderPicker = true }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 30)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
    }

    // MARK: - First run / errors

    private func folderPrompt(_ message: String?) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Text("DailyNote")
                .font(.system(.title2, design: .monospaced).weight(.bold))
            Text("Pick your vault folder once — the one\nholding your daily notes (e.g. Browse ▸ Obsidian ▸ your vault).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Button("Choose Vault Folder") { showFolderPicker = true }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") { model.retry() }
                .buttonStyle(.borderedProminent)
            Button("Change vault folder…") { showFolderPicker = true }
                .font(.footnote)
            Spacer()
        }
        .padding()
    }
}
