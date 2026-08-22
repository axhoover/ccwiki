import SwiftUI

/// One job: its outcome banner, its pre-flight findings, and its live
/// transcript.
struct JobDetailView: View {
    @Environment(AppModel.self) private var model
    let job: IngestJob

    @State private var followsTail = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
        }
        .navigationTitle(job.submission.displayName)
        .navigationSubtitle(job.state.label)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if case .opened(let url) = job.state {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open PR", systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !job.state.isTerminal {
                    Button("Cancel", role: .destructive) { job.cancel() }
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.small) {
            HStack(spacing: Theme.small) {
                JobStateIcon(state: job.state)
                Text(job.state.label)
                    .font(Theme.Fonts.documentTitle)
                Spacer(minLength: Theme.small)
                if let duration = job.duration {
                    Text(Duration.seconds(duration).formatted(
                        .units(allowed: [.minutes, .seconds], width: .narrow)))
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let cost = job.outcome?.costUSD {
                    Text(cost, format: .currency(code: "USD"))
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .help("Model cost for this job")
                }
            }

            outcomeBanner

            HStack(spacing: Theme.medium) {
                metadata("Branch", job.branch)
                if let source = job.submission.source {
                    metadata(source.label, source.canonicalURL)
                }
                if let pdf = job.submission.localPDF {
                    metadata("PDF", pdf.lastPathComponent)
                }
            }

            if !job.preflight.isEmpty { preflightList }
        }
        .padding(Theme.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    @ViewBuilder
    private var outcomeBanner: some View {
        switch job.state {
        case .opened(let url):
            banner(.green, "checkmark.circle.fill",
                   "A draft pull request is open. CCwiki never marks one ready for review.") {
                Link(url.absoluteString, destination: url)
                    .font(Theme.Fonts.meta)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .aborted(let reason):
            banner(.orange, "hand.raised.fill",
                   "The agent declined the job rather than guess. That is a good outcome.") {
                Text(reason)
                    .font(Theme.Fonts.log)
                    .textSelection(.enabled)
                    .lineLimit(8)
            }
        case .failed(let message):
            banner(.red, "xmark.octagon.fill", message) {
                if FileManager.default.fileExists(
                    atPath: job.worktree.path(percentEncoded: false)) {
                    Button("Reveal Worktree in Terminal") {
                        model.openInTerminal(job.worktree)
                    }
                    .buttonStyle(.link)
                    .font(Theme.Fonts.meta)
                }
            }
        default:
            EmptyView()
        }
    }

    private func banner<Content: View>(
        _ tint: Color, _ symbol: String, _ message: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.small) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: Theme.tight) {
                Text(message).font(Theme.Fonts.row)
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.medium)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 8))
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        HStack(spacing: Theme.tight) {
            Text(label)
                .font(Theme.Fonts.meta)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var preflightList: some View {
        VStack(alignment: .leading, spacing: Theme.tight) {
            ForEach(job.preflight) { finding in
                HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
                    Image(systemName: finding.symbolName)
                        .font(.caption)
                        .foregroundStyle(finding.level == .info
                            ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    Text(finding.title)
                        .font(Theme.Fonts.meta)
                    Text(finding.detail)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: Transcript

    /// The agent's work, one event per row.
    ///
    /// `claude --output-format stream-json` gives structure, so this is a
    /// readable log — "▸ Bash  npm run lint" — rather than a wall of JSON. The
    /// raw stream is on disk regardless.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(job.log) { entry in
                        row(entry).id(entry.id)
                    }
                    // A zero-height anchor is a more reliable scroll target
                    // than the last row, which changes identity as it arrives.
                    Color.clear.frame(height: 1).id(Self.tailAnchor)
                }
                .padding(Theme.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .onChange(of: job.log.count) { _, _ in
                guard followsTail else { return }
                // A hop, so the new row has been laid out before we scroll to
                // the anchor beneath it — otherwise the newest line lands
                // half-clipped behind the tail bar.
                Task { @MainActor in
                    proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { tailBar }
        }
    }

    private static let tailAnchor = "ccwiki.transcript.tail"

    private var tailBar: some View {
        HStack {
            Toggle("Follow", isOn: $followsTail)
                .toggleStyle(.checkbox)
                .font(Theme.Fonts.meta)
            Spacer()
            if let outcome = job.outcome {
                Text("\(outcome.turns) turns")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Text("\(job.log.count) events")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.medium)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func row(_ entry: JobLogEntry) -> some View {
        switch entry.role {
        case .system:
            logLine(entry.text, font: Theme.Fonts.log, color: .secondary)
        case .assistant:
            Text(entry.text)
                .font(Theme.Fonts.row)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
        case .tool(let name):
            HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
                Text(name)
                    .font(Theme.Fonts.badge)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: .rect(cornerRadius: 3))
                Text(entry.text)
                    .font(Theme.Fonts.log)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .toolResult(let isError):
            logLine(entry.text, font: Theme.Fonts.log,
                    color: isError ? .red : .secondary)
                .padding(.leading, Theme.large)
        case .stderr:
            logLine(entry.text, font: Theme.Fonts.log, color: .secondary)
        case .error:
            logLine(entry.text, font: Theme.Fonts.log, color: .red)
        }
    }

    private func logLine(_ text: String, font: Font, color: Color) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
