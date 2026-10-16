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
        // Reader first: most people who open this never run an ingestion
        // job, and the window used to open on a list of command-line tools.
        TabView {
            readingTab
                .tabItem { Label("Reading", systemImage: "book") }
            storageTab
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            // Jobs, not Ingestion: corrections run here too
            // (plans/corrections.md §11.1).
            toolsTab
                .tabItem { Label("Jobs", systemImage: "hammer") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        // Tall enough for the Reading tab's four sections and their footers
        // without scrolling, so "Hide stub pages" is never below the fold.
        .frame(width: 560, height: 480)
    }

    // MARK: Tools

    /// Until gh and the clone have answered, after discovery or Re-check,
    /// both answers read false; they are not shown as answers meanwhile.
    private var isCheckingGitHub: Bool {
        model.isDiscoveringTools || model.isCheckingGitHub
    }

    private var toolsTab: some View {
        Form {
            Section {
                ForEach(ToolLocator.Tool.allCases, id: \.self) { tool in
                    toolRow(tool)
                }
            } header: {
                Text("Command-line tools")
            } footer: {
                Text("Ingestion and corrections need these; opening an issue needs only gh. "
                    + "Reading needs none of them. CCwiki searches Homebrew's directories and "
                    + "~/.local/bin, then asks a login shell. Override one only if it lives "
                    + "somewhere unusual.")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
            }

            Section("GitHub") {
                LabeledContent("Authentication") {
                    HStack(spacing: Theme.small) {
                        if isCheckingGitHub {
                            Label("Checking…", systemImage: "hourglass")
                                .foregroundStyle(.secondary)
                                .font(Theme.Fonts.row)
                        } else if model.isGitHubAuthenticated {
                            Label("Signed in", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(Theme.Fonts.row)
                        } else if model.isGitHubUnreachable {
                            // Not knowing is not a fault (design-system §4b):
                            // the glyph tertiary, like the status bar's.
                            Label {
                                Text("Offline")
                            } icon: {
                                Image(systemName: "wifi.slash").foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(.secondary)
                            .font(Theme.Fonts.row)
                        } else {
                            Label("Not signed in", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(Theme.Fonts.row)
                        }
                        Button("Re-check") { model.recheckGitHubAuth() }
                            .controlSize(.small)
                            .disabled(isCheckingGitHub)
                    }
                }
                if !isCheckingGitHub, model.isGitHubUnreachable {
                    Text("GitHub could not be reached, so gh could not say whether it is signed "
                        + "in. CCwiki asks again when you come back to it.")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                } else if !isCheckingGitHub, !model.isGitHubAuthenticated {
                    Text("Run `gh auth login` in a terminal, then re-check. Jobs need an "
                        + "account that can push a branch to the wiki.")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Push credentials") {
                    if isCheckingGitHub {
                        Text("Checking…")
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(model.canPushToRemote
                            ? "Configured on CCwiki's clone"
                            : "Missing — jobs are blocked")
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(model.canPushToRemote
                                ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    }
                }
            }

            Section {
                Picker("Model", selection: Binding(
                    get: { model.correctionModel },
                    set: { model.correctionModel = $0 })) {
                    Text("Sonnet").tag("sonnet")
                    Text("Haiku").tag("haiku")
                    Text("Opus").tag("opus")
                    Text("The CLI's default").tag("")
                }
            } header: {
                Text("Corrections")
            } footer: {
                Text("The model an agent drafts a described correction with. Ingestion "
                    + "always uses the claude CLI's default.")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
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
                } else if tool == .git, model.needsDeveloperTools {
                    Label("Needs Apple's Command Line Tools", systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Color.orange)
                        .help("/usr/bin/git is only a stub until the Command Line Tools are "
                            + "installed. Reading works without it; ingestion jobs do not.")
                } else if model.isDiscoveringTools {
                    Label("Looking…", systemImage: "hourglass")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Not found", systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Color.orange)
                }
                Spacer(minLength: Theme.small)
                if tool == .git, model.needsDeveloperTools {
                    Button("Install…") { model.installDeveloperTools() }
                        .controlSize(.small)
                }
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

    private var readingTab: some View {
        Form {
            Section {
                Toggle("Check for wiki updates at launch", isOn: Binding(
                    get: { model.syncsAtLaunch },
                    set: { model.syncsAtLaunch = $0 }))
            } header: {
                Text("Staying current")
            } footer: {
                Text("A fast-forward of the clone when CCwiki opens. Reading never waits "
                    + "on it, and offline it is a quiet note in the status bar. ⌘R at any "
                    + "time does the same.")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show link previews on hover", isOn: Binding(
                    get: { model.showsLinkPreviews },
                    set: { model.showsLinkPreviews = $0 }))
            } header: {
                Text("Link previews")
            } footer: {
                Text("A card with the target's title and first paragraph, or a reduction's "
                    + "statement and how it holds. Hover over a link for half a second.")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show wiki maintenance notices", isOn: Binding(
                    get: { model.showsMaintenanceNotices },
                    set: { model.showsMaintenanceNotices = $0 }))
            } header: {
                Text("Reading")
            } footer: {
                Text("The banner counting links on a page that go nowhere. Useful when "
                    + "editing the wiki; noise when reading it. Broken links are styled "
                    + "either way.")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hide stub pages", isOn: Binding(
                    get: { model.hidesStubs },
                    set: { model.hidesStubs = $0 }))
                if model.hiddenStubCount > 0 {
                    LabeledContent("Currently hidden") {
                        Text("\(model.hiddenStubCount) pages")
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Sidebar and listings")
            } footer: {
                Text("A stub is a page with little on it yet — half the Primitives are "
                    + "stubs today. Hide them to read; show them to find work. Links, ⌘O "
                    + "and search always reach every page either way.")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var storageTab: some View {
        Form {
            Section("The wiki") {
                LabeledContent("Copy") {
                    pathRow(model.paths.clone)
                }
                LabeledContent("Kind") {
                    Text(storeDescription)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
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
                    // A job that is not finished, a review included, keeps
                    // its worktree in the clone's `.git` (corrections §4.3).
                    Button("Reset Clone…") { confirmResetClone() }
                        .disabled(model.syncState.isRunning || model.unfinishedJobCount > 0)
                        .help(resetCloneHelp)
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
                        Button("Rebuild") { model.rebuildLibrary() }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Working files")
            } footer: {
                Text("The search index is derived and safe to delete at any time; Rebuild "
                    + "reads every page again and rebuilds it. "
                    + "PDFs, the ones you drop for ingestion and the papers you open, are kept "
                    + "outside the clone and never enter the repository.")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Work still running can only be waited for; a review can be published
    /// or discarded (corrections §4.3).
    private var resetCloneHelp: String {
        if model.jobs.contains(where: { $0.state.isCancellable || $0.state.isActive }) {
            return "Not while a job is running: its worktree belongs to the clone"
        }
        switch model.unfinishedJobCount {
        case 0: return "Delete the clone and download the wiki again"
        case 1: return "Publish or discard the job in Jobs first."
        case let count: return "Publish or discard the \(count) jobs in Jobs first."
        }
    }

    private var storeDescription: String {
        switch model.paths.wikiStore {
        case .git: "git clone — updates fast-forward; jobs can run"
        case .snapshot: "snapshot — downloaded without git; reading only"
        case .none: "not downloaded yet"
        }
    }

    private func confirmResetClone() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the clone and download the wiki again?"
        alert.informativeText = "About 35 MB. Nothing of yours is in it — CCwiki never writes "
            + "there. Worktrees kept from earlier jobs stay on disk but are no longer "
            + "tracked. Use this when a sync reports that the clone has diverged or an "
            + "interrupted download left it broken."
        alert.addButton(withTitle: "Reset and Download")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.resetClone()
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
            // "CCwiki Dev" in a build from source, as the menus say.
            Section((Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "CCwiki") {
                LabeledContent("Version") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Bundle.main.shortVersion)
                            .textSelection(.enabled)
                        Text(isDevelopmentBuild
                            ? "Development build \(Bundle.main.buildNumber) — not a release"
                            : "Build \(Bundle.main.buildNumber)")
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                locationRow
                LabeledContent("Wiki", value: "axhoover/cryptology.city")
            }
            Section {
                // Off and disabled in CCwiki Dev, which never checks: showing
                // the stored value would say it does.
                Toggle("Check for updates daily", isOn: Binding(
                    get: { BuildIdentity.isRelease && model.checksForUpdates },
                    set: { model.checksForUpdates = $0 }))
                    .disabled(!BuildIdentity.isRelease)
                Toggle("Install them automatically", isOn: Binding(
                    get: { BuildIdentity.isRelease && model.installsUpdatesAutomatically },
                    set: { model.installsUpdatesAutomatically = $0 }))
                    .disabled(!model.checksForUpdates || !model.canInstallUpdates)
                LabeledContent("Status") {
                    HStack(spacing: Theme.small) {
                        updateStatus
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: Theme.small)
                        Button("Check Now") { model.checkForUpdates() }
                            .controlSize(.small)
                            .disabled(model.isCheckingForUpdates || model.isInstallingUpdate)
                    }
                }
                if let installed = model.installedUpdate {
                    HStack {
                        Spacer()
                        Button("Relaunch to Update to \(installed.version)") {
                            model.relaunchToUpdate()
                        }
                    }
                } else if let update = model.availableUpdate {
                    HStack {
                        Spacer()
                        Button("Open Release Page") { NSWorkspace.shared.open(update.url) }
                        if model.canInstallUpdates, update.isInstallable {
                            Button("Install CCwiki \(update.version)…") { model.checkForUpdates() }
                                .disabled(model.isInstallingUpdate || model.activeJobCount > 0)
                        }
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(updatesFooter)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
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

    /// Which copy of CCwiki this is, by folder and by path: the first thing
    /// to know when the Dock or Spotlight seems to start an old version.
    private var locationRow: some View {
        let bundle = Bundle.main.bundleURL
        return LabeledContent("Location") {
            HStack(spacing: Theme.small) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(InstallationCheck.displayLocation(bundle))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(InstallationCheck.abbreviatedPath(bundle))
                        .font(Theme.Fonts.log)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                .help(InstallationCheck.path(of: bundle))
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([bundle])
                }
                .controlSize(.small)
            }
        }
    }
}

extension SettingsView {
    /// CCwiki Dev, or a release-id bundle with a development version (a build
    /// from source older than the channels). Neither checks for updates.
    fileprivate var isDevelopmentBuild: Bool {
        !BuildIdentity.isRelease || UpdateChecker.isDevelopmentVersion(Bundle.main.shortVersion)
    }

    fileprivate var updatesFooter: String {
        if !BuildIdentity.isRelease {
            return "CCwiki Dev is built from source and never checks for updates. Its "
                + "settings and wiki are its own, apart from CCwiki's."
        }
        if model.canInstallUpdates {
            return "One request a day to GitHub's releases API. An update is downloaded, "
                + "its Ed25519 signature checked against the key built into this app, "
                + "and the app replaced in place; the old copy is deleted. CCwiki never "
                + "relaunches on its own."
        }
        return "One request a day to GitHub's releases API. This build has no release "
            + "key, so it can only tell you about an update and open its page."
    }

    fileprivate var updateStatus: Text {
        if let progress = model.updateInstallProgress {
            return Text(progress)
        }
        if let installed = model.installedUpdate {
            return Text("CCwiki \(installed.version) is installed — relaunch to use it")
        }
        if let update = model.availableUpdate {
            return Text("CCwiki \(update.version) is available")
        }
        if isDevelopmentBuild {
            return Text("Development build — not checked")
        }
        if let last = model.lastUpdateCheck {
            return Text("Up to date as of ") + Text(last, format: .relative(presentation: .named))
        }
        return Text("Not checked yet")
    }
}

extension Bundle {
    /// `CFBundleVersion`: `build.sh` stamps the build time in UTC,
    /// `yyyyMMddHHmm`, which is what tells two builds of one version apart.
    var buildNumber: String {
        (object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
    }

    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
}
