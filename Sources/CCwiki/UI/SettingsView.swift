import SwiftUI

/// ⌘, — the escape hatches.
///
/// There is very little here on purpose: CCwiki discovers everything it needs
/// and the clone lives at a fixed path. What this window exists for is the
/// three cases where discovery is wrong or the state is broken — a tool in an
/// unusual place, an unauthenticated `gh`, and a clone or index worth throwing
/// away. Every row says what CCwiki currently believes, so the window doubles
/// as the answer to "why isn't this working".
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            toolsTab
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
            storageTab
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 420)
    }

    // MARK: Tools

    private var toolsTab: some View {
        Form {
            Section {
                ForEach(ToolLocator.Tool.allCases, id: \.self) { tool in
                    toolRow(tool)
                }
            } header: {
                Text("Command-line tools")
            } footer: {
                Text("A Finder-launched app inherits a minimal PATH, so CCwiki also "
                    + "searches Homebrew's directories and ~/.local/bin, then asks a login "
                    + "shell. Override one only if it lives somewhere unusual.")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
            }

            Section("GitHub") {
                LabeledContent("Authentication") {
                    HStack(spacing: Theme.small) {
                        if model.isGitHubAuthenticated {
                            Label("Signed in", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(Theme.Fonts.row)
                        } else {
                            Label("Not signed in", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(Theme.Fonts.row)
                        }
                        Button("Re-check") { model.recheckGitHubAuth() }
                            .controlSize(.small)
                    }
                }
                if !model.isGitHubAuthenticated {
                    Text("Run `gh auth login` in a terminal, then re-check. Ingestion jobs "
                        + "need an account that can push a branch to the wiki.")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Push credentials") {
                    Text(model.canPushToRemote
                        ? "Configured on CCwiki's clone"
                        : "Missing — jobs are blocked")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(model.canPushToRemote
                            ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func toolRow(_ tool: ToolLocator.Tool) -> some View {
        LabeledContent(tool.rawValue) {
            HStack(spacing: Theme.small) {
                if let path = model.tools.path(for: tool) {
                    Text(path)
                        .font(Theme.Fonts.log)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                        .help(path)
                } else {
                    Label("Not found", systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(tool.requiredForReading ? Color.red : Color.orange)
                }
                Spacer(minLength: Theme.small)
                if model.toolOverrides[tool] != nil {
                    Button("Reset") { model.setToolOverride(nil, for: tool) }
                        .controlSize(.small)
                }
                Button("Locate…") { locate(tool) }
                    .controlSize(.small)
            }
        }
    }

    private func locate(_ tool: ToolLocator.Tool) {
        let panel = NSOpenPanel()
        panel.title = "Locate \(tool.rawValue)"
        panel.message = "CCwiki needs \(tool.rawValue) for \(tool.purpose)."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setToolOverride(url.path(percentEncoded: false), for: tool)
    }

    // MARK: Storage

    private var storageTab: some View {
        Form {
            Section("The wiki") {
                LabeledContent("Clone") {
                    pathRow(model.paths.clone)
                }
                LabeledContent("Revision") {
                    Text(model.headRevision.map { String($0.prefix(12)) } ?? "—")
                        .font(Theme.Fonts.log)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Pages") {
                    Text(model.index.map { "\($0.pages.count)" } ?? "—")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack {
                    Spacer()
                    Button("Sync Now") { model.sync() }
                        .disabled(model.syncState.isRunning)
                }
            }

            Section {
                LabeledContent("PDF library") { pathRow(model.paths.library) }
                LabeledContent("Worktrees") { pathRow(model.paths.worktrees) }
                LabeledContent("Job transcripts") { pathRow(model.paths.logs) }
                LabeledContent("Search index") {
                    HStack(spacing: Theme.small) {
                        Text(model.searchIndexSize)
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: Theme.small)
                        Button("Rebuild") { model.rebuildSearchIndex() }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Working files")
            } footer: {
                Text("The search index is derived and safe to delete at any time. "
                    + "PDFs are kept outside the clone deliberately — they are job inputs "
                    + "and never enter the repository.")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func pathRow(_ url: URL) -> some View {
        HStack(spacing: Theme.small) {
            Text(url.path(percentEncoded: false)
                .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(Theme.Fonts.log)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer(minLength: Theme.small)
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .controlSize(.small)
        }
    }

    // MARK: About

    private var aboutTab: some View {
        Form {
            Section("CCwiki") {
                LabeledContent("Version", value: Bundle.main.shortVersion)
                LabeledContent("Wiki", value: "axhoover/cryptology.city")
            }
            Section {
                LabeledContent("LaTeX macros") {
                    Text(model.macros.isEmpty
                        ? "unavailable" : "\(model.macros.macros.count) parsed from macros.ts")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(model.macros.isEmpty
                            ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                }
                if let manifest = model.vendorManifest {
                    Text(manifest)
                        .font(Theme.Fonts.log)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Offline rendering")
            } footer: {
                Text("Regenerate with ./scripts/vendor-web.sh. The app makes no network "
                    + "requests to render a page.")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

extension Bundle {
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
}
