import SwiftUI

/// Open an Issue About This Page (route c): the exact text sent to GitHub,
/// with the footer CCwiki adds shown beneath it (plans/corrections.md §8.2).
///
/// The sheet is the preview, the review and the result: the Body editor
/// holds exactly the text sent, and once gh answers, the sheet says which
/// issue it opened. Nothing is recorded locally. It reads only the model,
/// so the editor's and the review's GitHub banners can show it on their own
/// windows too (§8).
struct IssueSheet: View {
    let request: CorrectionSheetRequest

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var title = ""
    @State private var text = ""
    @State private var hasProposed = false
    /// One per sheet: the hidden marker a retry searches GitHub for.
    @State private var marker = UUID().uuidString
    @State private var login: String?
    /// The local paths that must not be sent, read once when the sheet opens.
    @State private var privatePaths: [String] = []
    @State private var phase: Phase = .editing
    @FocusState private var focus: IssueField?

    private enum Phase: Equatable {
        case editing
        case sending
        case failed(String)
        case opened(URL)
    }

    private var target: CorrectionTarget { request.target }
    private var repository: String { model.publishTarget.repository }
    private var isPassage: Bool { target.quote != nil && target.lines != nil }

    private var blockers: [String] { model.correctionBlockers(.issue, target: target) }

    /// GitHub has to be reachable and gh signed in; push rights do not
    /// matter for an issue.
    private var gitHubReason: String? {
        switch model.jobCenter.gitHubAccess {
        case .offline?: "Offline. The text is kept; open the issue when you are connected."
        case .notSignedIn?: GitHubAccess.notSignedIn.banner
        default: nil
        }
    }

    /// A local path or a token in what would be sent (§6.4).
    private var privateFindings: [String] {
        PrivateText.findings(in: title + "\n" + text, privatePaths: privatePaths)
    }

    private var canSend: Bool {
        phase != .sending && !model.isDiscoveringTools && blockers.isEmpty && gitHubReason == nil
            && privateFindings.isEmpty
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if case .opened(let url) = phase {
                opened(url)
            } else {
                form
            }
        }
        .padding(Theme.section)
        .frame(width: Theme.sheetWidth)
        .onAppear(perform: propose)
        .task { login = await model.githubLogin() }
    }

    // MARK: The form

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.large) {
            VStack(alignment: .leading, spacing: Theme.tight) {
                Text(isPassage ? "Open an Issue About This Passage"
                               : "Open an Issue About This Page")
                    .font(.title2.weight(.semibold))
                Text("For when something is wrong and you are not sure what it should say. "
                    + "No branch, no pull request.")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notice = request.notice {
                CorrectionNotice(text: notice)
            }

            VStack(alignment: .leading, spacing: Theme.tight) {
                Text("Title")
                    .font(Theme.Fonts.sectionHeader)
                    .foregroundStyle(.secondary)
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .focused($focus, equals: .title)
            }

            VStack(alignment: .leading, spacing: Theme.tight) {
                Text("Body")
                    .font(Theme.Fonts.sectionHeader)
                    .foregroundStyle(.secondary)
                IssueBodyEditor(text: $text, focus: $focus)
                    .font(Theme.Fonts.code)
                    .frame(height: 210)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                    .overlay(alignment: .bottom) {
                        // A red rule under the field while it holds a path
                        // or a token. Always there, so nothing moves.
                        Rectangle()
                            .fill(.red)
                            .frame(height: 2)
                            .opacity(privateFindings.isEmpty ? 0 : 1)
                    }
                if let found = privateFindings.first {
                    Label("This contains a local path or a token: \(found)",
                          systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } else {
                    Text("CCwiki adds: \(addedFooter)")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            if let job = model.jobCenter.jobs(touching: target.pagePath).first {
                ExistingJobNote(job: job)
            }

            if model.isDiscoveringTools {
                Label("Looking for gh…", systemImage: "hourglass")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
            } else if !blockers.isEmpty {
                CorrectionBlockerList(title: "Before an issue can be opened", blockers: blockers)
            } else if let gitHubReason {
                Label(gitHubReason, systemImage: "exclamationmark.triangle")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            if case .failed(let message) = phase {
                Label(message, systemImage: "xmark.octagon")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            HStack(spacing: Theme.small) {
                Text(destination)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.small)
                if phase == .sending {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Open Issue") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
            }
        }
    }

    /// "Opens an issue on axhoover/cryptology.city as @login", and in a Dev
    /// build "· from CCwiki Dev", before anything is sent (§10).
    private var destination: String {
        var line = "Opens an issue on \(repository)"
        if let login { line += " as @\(login)" }
        if model.publishTarget.isDevBuild { line += " · from CCwiki Dev" }
        return line
    }

    /// The footer's visible line, as it will be sent; the hidden marker is
    /// not shown.
    private var addedFooter: String {
        let visible = IssueComposer.visibleFooter(model.issueFooter(marker: marker))
        if !visible.isEmpty { return visible }
        return "Opened with CCwiki \(model.appVersion)"
            + (model.publishTarget.isDevBuild ? " · from CCwiki Dev" : "")
    }

    // MARK: The result

    private func opened(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: Theme.large) {
            VStack(alignment: .leading, spacing: Theme.tight) {
                Text(IssueComposer.issueNumber(in: url).map { "Issue #\($0) opened." }
                     ?? "Issue opened.")
                    .font(.title2.weight(.semibold))
                Text(url.absoluteString)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Open in Browser") { openURL(url) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Actions

    /// The proposed title and body, once: a sheet shown again keeps what
    /// was typed.
    private func propose() {
        guard !hasProposed else { return }
        hasProposed = true
        privatePaths = model.jobCenter.environment().privatePaths
        title = IssueComposer.proposedTitle(for: target)
        let slug = model.index?.pages[target.pagePath]?.slug
            ?? QuartzSlug.slugifyFilePath(target.pagePath)
        text = IssueComposer.body(
            for: target, siteURL: AppModel.siteURL(slug: slug), repository: repository)
        focus = .body
    }

    private func send() {
        guard canSend else { return }
        phase = .sending
        let draft = IssueDraft(target: target, marker: marker, title: title, body: text)
        Task {
            switch await model.openIssue(draft) {
            case .success(let url): phase = .opened(url)
            case .failure(let error): phase = .failed(error.message)
            }
        }
    }
}

/// Which of the issue sheet's fields has the keyboard.
private enum IssueField: Hashable {
    case title, body
}

/// The issue's body. From macOS 15 the cursor starts at the end, in the
/// empty paragraph IssueComposer leaves for what the reader has to say; on
/// macOS 14 a TextEditor cannot be given a selection.
private struct IssueBodyEditor: View {
    @Binding var text: String
    var focus: FocusState<IssueField?>.Binding

    var body: some View {
        if #available(macOS 15.0, *) {
            CursorAtEndEditor(text: $text, focus: focus)
        } else {
            TextEditor(text: $text)
                .focused(focus, equals: .body)
                .accessibilityLabel("Body")
        }
    }
}

@available(macOS 15.0, *)
private struct CursorAtEndEditor: View {
    @Binding var text: String
    var focus: FocusState<IssueField?>.Binding
    @State private var selection: TextSelection?

    var body: some View {
        TextEditor(text: $text, selection: $selection)
            .focused(focus, equals: .body)
            .accessibilityLabel("Body")
            .onChange(of: text, initial: true) { _, proposed in
                // The proposed text arrives once; after that the selection
                // is the reader's.
                if selection == nil, !proposed.isEmpty {
                    selection = TextSelection(insertionPoint: proposed.endIndex)
                }
            }
    }
}
