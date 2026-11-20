import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PrizmXConfig
import PrizmXServices

/// Module catalog: Surge `.sgmodule` and Stash `.stoverride` overlays
/// applied non-destructively on top of the active profile.
struct ModulesPane: View {
    @Environment(AppModel.self) private var appModel
    @State private var search = ""
    @State private var selectedID: ModuleRecord.ID?
    @State private var inspecting: ModuleRecord?
    @State private var isURLImportPresented = false
    @State private var errorMessage: String?

    var body: some View {
        let rows = displayModules
        Group {
            if rows.isEmpty {
                ConsoleEmptyState(
                    title: "No Modules",
                    systemImage: SidebarItem.module.systemImage,
                    description: search.isEmpty
                        ? (store.lastError ?? "Import a Surge .sgmodule or Stash .stoverride to overlay rules, hosts, and DNS filters without editing your subscription.")
                        : "No modules match this filter."
                )
            } else {
                Table(rows, selection: $selectedID) {
                    TableColumn("On") { (module: ModuleRecord) in
                        Toggle("", isOn: Binding(
                            get: { module.enabled },
                            set: { enabled in
                                store.setEnabled(enabled, id: module.id)
                                appModel.didChangeModules()
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                    .width(42)

                    TableColumn("Name") { (module: ModuleRecord) in
                        HStack(spacing: 6) {
                            Text(module.name)
                                .foregroundStyle(module.enabled ? .primary : .secondary)
                            if let category = module.category, !category.isEmpty {
                                Text(category)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.14), in: Capsule())
                            }
                            if module.sourceURL != nil {
                                Image(systemName: "link")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    TableColumn("Contents") { module in
                        let parsed = store.parsed(for: module)
                        HStack(spacing: 6) {
                            Text(contentSummary(parsed))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if !parsed.skipped.isEmpty {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .help(parsed.skipped.joined(separator: "\n"))
                            }
                        }
                    }

                    TableColumn("Updated") { module in
                        if let updated = module.lastUpdated {
                            Text(updated.formatted(.relative(presentation: .named)))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                    .width(105)
                }
                .tableStyle(.inset)
                .contextMenu(forSelectionType: ModuleRecord.ID.self) { ids in
                    if let id = ids.first, let module = store.modules.first(where: { $0.id == id }) {
                        Button(module.enabled ? "Disable" : "Enable") {
                            store.setEnabled(!module.enabled, id: module.id)
                            appModel.didChangeModules()
                        }
                        Button("Inspect…") { inspecting = module }
                        Divider()
                        if module.sourceURL != nil {
                            Button("Update from URL") {
                                Task { await refreshRemote(id: module.id) }
                            }
                        }
                        Button("Open in Default Editor") { openInEditor(module) }
                        Button("Show in Finder") { revealInFinder(module) }
                        Divider()
                        Button("Delete", role: .destructive) { delete(id: id) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first {
                        inspecting = store.modules.first { $0.id == id }
                    }
                }
            }
        }
        .navigationTitle("Module \(rows.count)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                IconControlGroup {
                    Menu {
                        Button("Import Module File…") { importLocalFile() }
                        Button("Install from URL…") { isURLImportPresented = true }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .menuIndicator(.hidden)
                    .help("Add module")

                    Button("Delete", systemImage: "minus") {
                        delete(id: selectedID)
                    }
                    .disabled(selectedID == nil)
                    .help("Delete module")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Reload Files", systemImage: "arrow.clockwise") {
                    appModel.didChangeModules()
                }
                .labelStyle(.iconOnly)
                .help("Re-read module files from disk and reload active overlay")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(text: $search, prompt: "Search modules")
            }
        }
        .hiddenWindowToolbarBackground()
        .sheet(item: $inspecting) { module in
            ModuleDetailSheet(module: module) {
                appModel.didChangeModules()
            }
        }
        .sheet(isPresented: $isURLImportPresented) {
            ModuleURLImportSheet { installed in
                selectedID = installed.id
                appModel.didChangeModules()
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

    private var store: ModuleStore { appModel.modules }

    private var displayModules: [ModuleRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.modules }
        return store.modules.filter { module in
            module.name.localizedCaseInsensitiveContains(query)
                || module.summary.localizedCaseInsensitiveContains(query)
                || (module.category?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func contentSummary(_ parsed: ParsedModule) -> String {
        var parts: [String] = []
        if !parsed.rules.isEmpty { parts.append("\(parsed.rules.count) rules") }
        if !parsed.hosts.isEmpty { parts.append("\(parsed.hosts.count) hosts") }
        if !parsed.fakeIPFilters.isEmpty { parts.append("\(parsed.fakeIPFilters.count) DNS filters") }
        if parts.isEmpty {
            return parsed.skipped.isEmpty ? "Empty" : "Skipped (MITM only)"
        }
        return parts.joined(separator: " · ")
    }

    private func importLocalFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml, .plainText, .item]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let installed = try store.importFile(from: url)
            selectedID = installed.id
            appModel.didChangeModules()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshRemote(id: UUID) async {
        do {
            try await store.refresh(id: id)
            appModel.didChangeModules()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openInEditor(_ module: ModuleRecord) {
        do {
            let url = try store.ensureModuleFile(for: module)
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revealInFinder(_ module: ModuleRecord) {
        do {
            let url = try store.ensureModuleFile(for: module)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(id: ModuleRecord.ID?) {
        guard let id else { return }
        do {
            try store.remove(id: id)
            if selectedID == id { selectedID = nil }
            appModel.didChangeModules()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ModuleDetailSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let module: ModuleRecord
    var onChanged: () -> Void

    @State private var arguments: [String: String]
    @State private var saveError: String?

    init(module: ModuleRecord, onChanged: @escaping () -> Void) {
        self.module = module
        self.onChanged = onChanged
        _arguments = State(initialValue: module.argumentOverrides)
    }

    var body: some View {
        let parsed = appModel.modules.parsed(for: module)
        VStack(spacing: 0) {
            Form {
                Section("Overview") {
                    LabeledContent("Name", value: parsed.name)
                    LabeledContent("Format", value: parsed.format == .sgmodule ? "Surge (.sgmodule)" : "Stash (.stoverride)")
                    if !parsed.summary.isEmpty {
                        Text(parsed.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let url = module.sourceURL {
                        LabeledContent("Source", value: url.absoluteString)
                            .textSelection(.enabled)
                    }
                }

                if !parsed.defaultArguments.isEmpty {
                    Section("Arguments") {
                        ForEach(parsed.defaultArguments.keys.sorted(), id: \.self) { key in
                            TextField(
                                key,
                                text: Binding(
                                    get: { arguments[key] ?? parsed.defaultArguments[key] ?? "" },
                                    set: { arguments[key] = $0 }
                                ),
                                prompt: Text(parsed.defaultArguments[key] ?? "")
                            )
                        }
                    }
                }

                Section("Active Sections") {
                    LabeledContent("Rules", value: "\(parsed.rules.count)")
                    LabeledContent("Hosts", value: "\(parsed.hosts.count)")
                    LabeledContent("FakeIP Filters", value: "\(parsed.fakeIPFilters.count)")
                }

                if !parsed.skipped.isEmpty {
                    Section("Skipped (Not Applied)") {
                        ForEach(Array(parsed.skipped.enumerated()), id: \.offset) { _, line in
                            Label(line, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            SheetActionBar(
                doneTitle: parsed.defaultArguments.isEmpty ? "Done" : "Save",
                onDone: saveAndClose
            ) {
                if !parsed.defaultArguments.isEmpty {
                    Button("Cancel", action: dismiss.callAsFunction)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(width: 520, height: 480)
    }

    private func saveAndClose() {
        let parsed = appModel.modules.parsed(for: module)
        guard !parsed.defaultArguments.isEmpty else {
            dismiss()
            return
        }
        do {
            try appModel.modules.updateArguments(arguments, id: module.id)
            onChanged()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

private struct ModuleURLImportSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    var onInstalled: (ModuleRecord) -> Void

    @State private var urlString = ""
    @State private var isInstalling = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Install Module from URL")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                Form {
                    TextField("Module URL", text: $urlString, prompt: Text("https://example.com/module.sgmodule"))
                        .textContentType(.URL)
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
        isInstalling = true
        errorText = nil
        Task {
            defer { isInstalling = false }
            do {
                let installed = try await appModel.modules.installFromURL(url)
                onInstalled(installed)
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

#Preview("Modules") {
    ModulesPane()
        .environment(AppModel.preview)
        .frame(width: 720, height: 480)
}
