import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PrizmXScripts
import PrizmXServices

/// Lightweight script runtime manager: runs bundled system scripts and user
/// `.js` scripts (imported locally or from URL) with no built-in code editor.
struct ScriptsPane: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    @State private var search = ""
    @State private var selectedID: ScriptRecord.ID?
    @State private var configuring: ScriptRecord?
    @State private var isURLImportPresented = false
    @State private var showOutputDrawer = false
    @State private var errorMessage: String?

    private static let sdkDocsURL = URL(string: "https://github.com/PrizmX/PrizmX/blob/main/docs/script-sdk.md")!

    var body: some View {
        let rows = displayScripts
        VStack(spacing: 0) {
            Group {
                if rows.isEmpty {
                    ConsoleEmptyState(
                        title: "No Matching Scripts",
                        systemImage: SidebarItem.scripts.systemImage,
                        description: "No scripts match this filter."
                    )
                } else {
                    Table(rows, selection: $selectedID) {
                        TableColumn("") { (script: ScriptRecord) in
                            let isEnabled = store.isEnabled(script)
                            let isSelected = selectedID == script.id
                            Image(systemName: scriptIcon(for: script))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(
                                    isSelected
                                        ? (isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                        : (isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.5)))
                                )
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .width(24)

                        TableColumn("Name") { (script: ScriptRecord) in
                            let isEnabled = store.isEnabled(script)
                            HStack(spacing: 6) {
                                Text(script.name)
                                    .fontWeight(isEnabled ? .semibold : .regular)
                                    .foregroundStyle(isEnabled ? .primary : .secondary)
                                if script.isBuiltIn {
                                    Text("System")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.14), in: Capsule())
                                }
                            }
                        }

                        TableColumn("Type") { script in
                            Text(script.kind.title)
                                .foregroundStyle(script.kind.requiresMITM ? .secondary : .primary)
                        }
                        .width(120)

                        TableColumn("Match") { script in
                            Text(script.kind.showsMatch ? displayMatch(script.pattern) : "—")
                                .font(.body.monospaced())
                                .foregroundStyle(script.pattern.isEmpty ? .tertiary : .primary)
                        }

                        TableColumn("Status") { script in
                            statusCell(for: script)
                        }
                        .width(165)
                    }
                    .tableStyle(.inset)
                    .contextMenu(forSelectionType: ScriptRecord.ID.self) { ids in
                        if let id = ids.first, let script = allScripts.first(where: { $0.id == id }) {
                            Button("Test") { runScript(script) }
                                .disabled(scheduler.runningIDs.contains(script.id))
                            Button(store.isEnabled(script) ? "Disable" : "Enable") {
                                if script.isBuiltIn {
                                    store.setBuiltInEnabled(!store.isEnabled(script), id: script.id)
                                } else {
                                    store.setEnabled(!script.enabled, id: script.id)
                                }
                            }
                            if !script.isBuiltIn {
                                Divider()
                                Button("Configure…") { configuring = script }
                                Button("Open in Default Editor") { openInEditor(script) }
                                Button("Show in Finder") { revealInFinder(script) }
                                if script.sourceURL != nil {
                                    Button("Update from URL") {
                                        Task { await refreshRemote(id: script.id) }
                                    }
                                }
                                Divider()
                                Button("Delete", role: .destructive) { delete(id: id) }
                            }
                        }
                    } primaryAction: { ids in
                        if let id = ids.first, let script = allScripts.first(where: { $0.id == id }) {
                            if script.isBuiltIn {
                                runScript(script)
                            } else {
                                openInEditor(script)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showOutputDrawer, let summary = activeRunSummary {
                Divider()
                outputDrawer(summary)
            }
        }
        .navigationTitle("Scripts - \(rows.count)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                IconControlGroup {
                    Menu {
                        Button("Import .js File…") { importLocalFile() }
                        Button("Install from URL…") { isURLImportPresented = true }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .menuIndicator(.hidden)
                    .help("Import script")

                    Button("Delete", systemImage: "minus") {
                        delete(id: selectedID)
                    }
                    .disabled(selectedScript == nil || selectedScript?.isBuiltIn == true)
                    .help("Delete selected user script")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("SDK Docs", systemImage: "book") {
                    openURL(Self.sdkDocsURL)
                }
                .labelStyle(.iconOnly)
                .help("Open PrizmX Script SDK documentation")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(text: $search, prompt: "Search scripts")
            }
        }
        .hiddenWindowToolbarBackground()
        .sheet(item: $configuring) { script in
            ScriptConfigSheet(initial: script) { saved in
                upsert(saved)
            }
        }
        .sheet(isPresented: $isURLImportPresented) {
            ScriptURLImportSheet { installed in
                selectedID = installed.id
            }
        }
        .sheet(isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            ConfirmSheet(
                title: "Error",
                message: errorMessage ?? "",
                showsCancel: false,
                onDone: { errorMessage = nil }
            )
        }
    }

    private var store: ScriptStore { appModel.scripts }


    private var scheduler: ScriptScheduler { appModel.scriptScheduler }

    private var allScripts: [ScriptRecord] {
        ScriptStore.builtInScripts + store.scripts
    }

    private var selectedScript: ScriptRecord? {
        guard let selectedID else { return nil }
        return allScripts.first { $0.id == selectedID }
    }

    private var activeRunSummary: ScriptRunSummary? {
        if let selectedID, let summary = scheduler.lastRunByID[selectedID] {
            return summary
        }
        return scheduler.lastRunByID.values.max(by: { $0.ranAt < $1.ranAt })
    }

    private var displayScripts: [ScriptRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allScripts }
        return allScripts.filter { script in
            script.name.localizedCaseInsensitiveContains(query)
                || script.kind.title.localizedCaseInsensitiveContains(query)
                || script.pattern.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private func statusCell(for script: ScriptRecord) -> some View {
        if scheduler.runningIDs.contains(script.id) {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Running…").foregroundStyle(.secondary)
            }
        } else if script.kind.requiresMITM {
            Text("Requires MITM")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let run = scheduler.lastRunByID[script.id] {
            HStack(spacing: 5) {
                Circle()
                    .fill(run.succeeded ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(run.succeeded ? "\(run.durationMs)ms · \(run.ranAt.formatted(.relative(presentation: .named)))" : "Failed")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(run.succeeded ? Color.secondary : Color.red)
                    .lineLimit(1)
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func outputDrawer(_ summary: ScriptRunSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(summary.succeeded ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Text(summary.scriptName)
                    .font(.subheadline.weight(.semibold))
                Text("[\(summary.trigger)] · \(summary.durationMs)ms · \(summary.ranAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Hide") { showOutputDrawer = false }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            ScrollView {
                Text(formatOutput(summary))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(summary.succeeded ? Color.primary : Color.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 112)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func formatOutput(_ summary: ScriptRunSummary) -> String {
        if let error = summary.errorMessage {
            return "error: \(error)"
        }
        var lines = ["result: \(summary.resultText)"]
        if !summary.logs.isEmpty {
            lines.append("logs:")
            lines.append(contentsOf: summary.logs.map { "  \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    private func scriptIcon(for script: ScriptRecord) -> String {
        if script.sourceURL != nil { return "link.circle" }
        if script.isBuiltIn { return "flask" }
        return "doc.text"
    }

    private func displayMatch(_ pattern: String) -> String {
        pattern.isEmpty ? "—" : pattern
    }

    private func runScript(_ script: ScriptRecord) {
        selectedID = script.id
        showOutputDrawer = true
        Task {
            _ = await scheduler.runNow(script, trigger: "test")
        }
    }

    private func importLocalFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.javaScript, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let installed = try store.importFile(from: url)
            selectedID = installed.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openInEditor(_ script: ScriptRecord) {
        do {
            let fileURL = try store.ensureSourceFile(for: script)
            openTextFileInDefaultEditor(fileURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revealInFinder(_ script: ScriptRecord) {
        do {
            let fileURL = try store.ensureSourceFile(for: script)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshRemote(id: UUID) async {
        do {
            try await store.refresh(id: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func upsert(_ script: ScriptRecord) {
        do {
            try store.upsert(script)
            selectedID = script.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(id: ScriptRecord.ID?) {
        guard let id,
              let target = allScripts.first(where: { $0.id == id }),
              !target.isBuiltIn
        else { return }
        do {
            try store.remove(id: id)
            if selectedID == id { selectedID = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Lightweight metadata-only configuration sheet (no built-in code editor).
private struct ScriptConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    var initial: ScriptRecord
    var onSave: (ScriptRecord) -> Void

    @State private var name: String
    @State private var enabled: Bool
    @State private var kind: ScriptRecord.Kind
    @State private var pattern: String
    @State private var argument: String
    @State private var timeout: Double

    init(initial: ScriptRecord, onSave: @escaping (ScriptRecord) -> Void) {
        self.initial = initial
        self.onSave = onSave
        _name = State(initialValue: initial.name)
        _enabled = State(initialValue: initial.enabled)
        _kind = State(initialValue: initial.kind)
        _pattern = State(initialValue: initial.pattern)
        _argument = State(initialValue: initial.argument)
        _timeout = State(initialValue: initial.timeout)
    }

    private var cronValidationError: String? {
        guard kind == .cron else { return nil }
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Cron expression is required (e.g. */30 * * * *)." }
        do {
            _ = try CronSchedule.parse(trimmed)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && timeout > 0
            && cronValidationError == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Configure Script")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                Form {
                    TextField("Name", text: $name, prompt: Text("Script name"))
                    Picker("Type", selection: $kind) {
                        ForEach(ScriptRecord.Kind.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    if kind.requiresMITM {
                        Text("HTTP request/response hooks require MITM (planned for PrizmX Pro).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if kind.showsMatch {
                        TextField(kind.matchPrompt, text: $pattern)
                            .font(.body.monospaced())
                        if let cronValidationError {
                            Text(cronValidationError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    TextField("Argument", text: $argument, prompt: Text("Optional $argument"))
                    TextField("Timeout (s)", value: $timeout, format: .number)
                    Toggle("Enabled", isOn: $enabled)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
            SheetActionBar(
                doneTitle: "Save",
                doneEnabled: canSave,
                onDone: save
            ) {
                Button("Cancel", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(minWidth: 520)
    }

    private func save() {
        var next = initial
        next.name = name
        next.enabled = enabled
        next.kind = kind
        next.pattern = pattern
        next.argument = argument
        next.timeout = timeout
        onSave(next)
        dismiss()
    }
}

private struct ScriptURLImportSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    var onInstalled: (ScriptRecord) -> Void

    @State private var name = ""
    @State private var urlString = ""
    @State private var kind: ScriptRecord.Kind = .script
    @State private var pattern = ""
    @State private var argument = ""
    @State private var isInstalling = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Install Script from URL")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                Form {
                    TextField("Script URL", text: $urlString, prompt: Text(verbatim: "https://example.com/script.js"))
                        .textContentType(.URL)
                    TextField("Name", text: $name, prompt: Text("Optional"))
                    Picker("Type", selection: $kind) {
                        ForEach(ScriptRecord.Kind.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    if kind.showsMatch {
                        TextField(kind.matchPrompt, text: $pattern)
                            .font(.body.monospaced())
                    }
                    TextField("Argument", text: $argument, prompt: Text("Optional $argument"))
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                if let errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
            }
            SheetActionBar(
                doneTitle: isInstalling ? "Installing…" : "Install",
                doneEnabled: !isInstalling && URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) != nil,
                onDone: install
            ) {
                Button("Cancel", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(minWidth: 520)
    }

    private func install() {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            errorText = "Enter a valid URL."
            return
        }
        if kind == .cron, !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                _ = try CronSchedule.parse(pattern)
            } catch {
                errorText = error.localizedDescription
                return
            }
        }
        isInstalling = true
        errorText = nil
        Task {
            defer { isInstalling = false }
            do {
                let installed = try await appModel.scripts.installFromURL(
                    url,
                    name: name,
                    kind: kind,
                    pattern: pattern,
                    argument: argument
                )
                onInstalled(installed)
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

#Preview("Scripts") {
    ScriptsPane()
        .environment(AppModel.preview)
        .frame(width: 720, height: 480)
}
