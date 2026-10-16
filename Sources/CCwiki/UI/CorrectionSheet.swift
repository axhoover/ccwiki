import SwiftUI

/// Describe a Correction (route b): what is wrong and what it should say,
/// for an agent to draft the smallest edit (plans/corrections.md §8.1).
///
/// A sheet on the reader window, in IngestSheet's shape: a title and one
/// secondary line, the page and passage it is about, the field, what is in
/// the way, then Cancel and Start Job. Nothing reaches GitHub from here: the
/// job stops at review, in Jobs.
struct CorrectionSheet: View {
    let request: CorrectionSheetRequest

    @Environment(AppModel.self) private var model
    /// Optional: the sheet is the reader window's, and only it can turn
    /// into the issue sheet.
    @Environment(ReaderSession.self) private var session: ReaderSession?
    @Environment(\.dismiss) private var dismiss

    @State private var problem = ""
    @FocusState private var fieldFocused: Bool

    private var target: CorrectionTarget { request.target }

    /// A "Participates in" section, written by the wiki's script from the
    /// reduction pages, which this agent cannot run; or the relation-meta
    /// line, built from this page's own frontmatter (§5.4, §8.1).
    private var isGenerated: Bool { target.region != .body }

    /// Local conditions only; the generated passage has a note of its own.
    private var blockers: [String] {
        model.correctionBlockers(.describe, target: target)
            .filter { $0 != CorrectionBlockers.generated }
            .filter { $0 != CorrectionBlockers.frontmatterLine }
    }

    private var trimmedProblem: String {
        problem.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canStart: Bool {
        !isGenerated && !model.isDiscoveringTools && blockers.isEmpty && !trimmedProblem.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.large) {
            VStack(alignment: .leading, spacing: Theme.tight) {
                Text("Describe a Correction")
                    .font(.title2.weight(.semibold))
                Text("An agent drafts the smallest edit that does what you ask. Nothing reaches "
                    + "GitHub until you approve it in Jobs.")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notice = request.notice {
                CorrectionNotice(text: notice)
            }

            CorrectionContextCard(target: target)

            if isGenerated {
                generatedNote
            } else {
                field
            }

            if let job = model.jobCenter.jobs(touching: target.pagePath).first {
                ExistingJobNote(job: job)
            }

            if !isGenerated {
                if model.isDiscoveringTools {
                    Label("Looking for the tools a job needs…", systemImage: "hourglass")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                } else if !blockers.isEmpty {
                    CorrectionBlockerList(title: "Before a job can start", blockers: blockers)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                if isGenerated {
                    Button("Open an Issue…") { openIssueInstead() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Start Job") { start() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStart)
                }
            }
        }
        .padding(Theme.section)
        .frame(width: Theme.sheetWidth)
        .onAppear { fieldFocused = !isGenerated }
    }

    // MARK: The field

    private var field: some View {
        VStack(alignment: .leading, spacing: Theme.tight) {
            Text("What is wrong, and what should it say?")
                .font(Theme.Fonts.sectionHeader)
                .foregroundStyle(.secondary)
            TextEditor(text: $problem)
                .font(Theme.Fonts.row)
                .frame(height: 96)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                .focused($fieldFocused)
                .accessibilityLabel("What is wrong, and what should it say?")
            Text(modelLine + " Change it in Settings > Jobs.")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.tertiary)
        }
    }

    /// The model the agent runs with, as Settings → Jobs names it.
    private var modelLine: String {
        switch model.correctionModel {
        case "": "Uses the claude CLI's default model."
        case "sonnet": "Uses Claude Sonnet."
        case "haiku": "Uses Claude Haiku."
        case "opus": "Uses Claude Opus."
        case let other: "Uses \(other)."
        }
    }

    /// In place of the field on a generated passage, with Open an Issue… as
    /// the default button.
    private var generatedNote: some View {
        Label {
            Text(target.region == .frontmatter
                 ? CorrectionBlockers.frontmatterLine : CorrectionBlockers.generated)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
        }
        .font(Theme.Fonts.row)
    }

    // MARK: Actions

    private func start() {
        guard canStart else { return }
        let job = model.jobCenter.startCorrection(CorrectionRequest(
            target: target, description: trimmedProblem, model: model.correctionModel))
        model.requestJobsWindow(selecting: job.id)
        dismiss()
    }

    /// The issue sheet, about the same passage, in this sheet's place.
    private func openIssueInstead() {
        guard let session else {
            dismiss()
            return
        }
        session.correctionSheet = CorrectionSheetRequest(
            .issue, target: target, notice: request.notice)
    }
}

// MARK: - Shared with the issue sheet

/// The page and passage a sheet is about: the page's title, where on it,
/// and the passage as the reader showed it, four lines at most, all of it
/// in the help tag.
struct CorrectionContextCard: View {
    let target: CorrectionTarget

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.tight) {
            Text(target.pageTitle)
                .font(Theme.Fonts.documentTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(target.summary)
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let quote = target.quote {
                Text(quote)
                    .font(Theme.Fonts.log)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .padding(.top, Theme.tight)
                    .help(quote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.medium)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}

/// A job already on the page (§7.1), with Show Job.
struct ExistingJobNote: View {
    let job: Job

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
            Image(systemName: job.kind.symbolName)
                .foregroundStyle(.secondary)
            Text("This page already has a job in Jobs. \(job.correctionNote)")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: Theme.small)
            Button("Show Job") { model.requestJobsWindow(selecting: job.id) }
                .controlSize(.small)
        }
    }
}

/// Why the sheet's button is disabled, listed as IngestSheet lists its
/// blockers, with Open Settings….
struct CorrectionBlockerList: View {
    let title: String
    let blockers: [String]

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.tight) {
            Text(title)
                .font(Theme.Fonts.sectionHeader)
                .foregroundStyle(.secondary)
            ForEach(blockers, id: \.self) { blocker in
                Label(blocker, systemImage: "exclamationmark.triangle")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Button("Open Settings…") { model.requestSettings() }
                .buttonStyle(.link)
                .font(Theme.Fonts.meta)
        }
    }
}

/// Why the target is not what was selected (§3.5).
struct CorrectionNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(Theme.Fonts.meta)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}
