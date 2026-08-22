import SwiftUI
import UniformTypeIdentifiers

/// The ingestion affordance: a drop target and a paste field.
///
/// Both, not one: dropping a PDF is the natural gesture when you have the paper
/// open, and pasting a link is the natural gesture when you are reading
/// someone's announcement. The field recognizes ePrint, arXiv, DOI and ECCC
/// links and tells you which it saw, because silently accepting a URL you
/// mistyped and finding out twenty minutes later is the failure this screen
/// exists to prevent.
struct IngestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var link = ""
    @State private var notes = ""
    @State private var droppedPDF: URL?
    @State private var isTargeted = false
    @State private var dropError: String?
    @FocusState private var linkFocused: Bool

    private var parsedSource: IngestSubmission.Source? {
        IngestSubmission.Source.parse(link)
    }

    private var canSubmit: Bool {
        droppedPDF != nil || parsedSource != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.large) {
            VStack(alignment: .leading, spacing: Theme.tight) {
                Text("Ingest a Paper")
                    .font(.title2.weight(.semibold))
                Text("CityDesk runs an agent in a throwaway git worktree. It opens a "
                    + "**draft** pull request and never merges one.")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
            }

            dropTarget

            VStack(alignment: .leading, spacing: Theme.tight) {
                Text("Or paste a link")
                    .font(Theme.Fonts.sectionHeader)
                    .foregroundStyle(.secondary)
                TextField("eprint.iacr.org/2025/375, arxiv.org/abs/…, or a DOI", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .focused($linkFocused)
                    .onSubmit { if canSubmit { submit() } }
                sourceHint
            }

            VStack(alignment: .leading, spacing: Theme.tight) {
                Text("Notes for the agent (optional)")
                    .font(Theme.Fonts.sectionHeader)
                    .foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .font(Theme.Fonts.row)
                    .frame(height: 60)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                Text("For example: which primitive page you think the result belongs on.")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            HStack {
                if let dropError {
                    Label(dropError, systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Start Job") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(Theme.section)
        .frame(width: 560, height: 520)
        .onAppear {
            // A PDF dropped on the reader opens this sheet already holding it.
            if let pending = model.pendingDroppedPDF {
                droppedPDF = pending
                model.pendingDroppedPDF = nil
            }
            linkFocused = true
        }
    }

    // MARK: Drop target

    private var dropTarget: some View {
        VStack(spacing: Theme.small) {
            Image(systemName: droppedPDF == nil ? "doc.badge.plus" : "doc.fill")
                .font(.largeTitle)
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            if let droppedPDF {
                Text(droppedPDF.lastPathComponent)
                    .font(Theme.Fonts.row)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Remove") { self.droppedPDF = nil }
                    .buttonStyle(.link)
                    .font(Theme.Fonts.meta)
            } else {
                Text("Drop a PDF here")
                    .font(Theme.Fonts.row)
                    .foregroundStyle(.secondary)
                Text("Copied to your library, never into the repo.")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.section)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? AnyShapeStyle(Color.accentColor.opacity(0.08))
                                 : AnyShapeStyle(Color.clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 4]))
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .onDrop(of: [.pdf, .fileURL], isTargeted: $isTargeted) { providers in
            accept(providers)
        }
    }

    private func accept(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "pdf" else {
                Task { @MainActor in dropError = "That is not a PDF." }
                return
            }
            Task { @MainActor in
                do {
                    droppedPDF = try model.stagePDF(from: url)
                    dropError = nil
                } catch {
                    dropError = error.localizedDescription
                }
            }
        }
        return true
    }

    // MARK: Link feedback

    @ViewBuilder
    private var sourceHint: some View {
        if link.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("A canonical landing page makes a better citation than a PDF link; "
                + "CityDesk normalizes either.")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.tertiary)
        } else if let source = parsedSource {
            HStack(spacing: Theme.tight) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(source.label).font(Theme.Fonts.meta).foregroundStyle(.secondary)
                Text(source.canonicalURL)
                    .font(Theme.Fonts.log)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            Label("Not a URL or DOI CityDesk recognizes.", systemImage: "exclamationmark.triangle")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.orange)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        model.submitIngestion(
            source: parsedSource,
            pdf: droppedPDF,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
        openWindow(id: CityDeskApp.jobsWindowID)
        dismiss()
    }
}
