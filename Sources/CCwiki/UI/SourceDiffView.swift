import SwiftUI

/// The review's Source mode (plans/corrections.md §6.3): each changed file's
/// hunks as lines of source, in `Theme.Fonts.log`, with the old and new line
/// numbers in the gutter.
///
/// Removed and added lines are tinted red and green and marked by their sign,
/// so they differ by more than colour. Within a changed pair, the words that
/// changed are set in bold on a stronger tint (`WordDiff`), so a one-letter
/// fix in a long paragraph is findable. A file of more than 400 changed lines
/// (`relations.json`) waits behind Show.
///
/// The rows are built off the main actor, once per snapshot (`SourceDiff`).
struct SourceDiffView: View {
    let snapshot: ReviewSnapshot
    /// A finding to scroll to: a click in the findings strip.
    let scrollRequest: SourceDiffScroll?

    @State private var files: [SourceDiff.File] = []
    @State private var builtFor: SourceDiff.Key?
    /// Large files the reviewer chose to show.
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(files) { file in
                        Section {
                            fileBody(file)
                        } header: {
                            header(file)
                        }
                    }
                }
                .padding(.bottom, Theme.medium)
                .textSelection(.enabled)
            }
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }
                scroll(to: request, proxy: proxy)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: SourceDiff.Key(snapshot)) {
            let current = self.snapshot
            let key = SourceDiff.Key(current)
            guard builtFor != key else { return }
            let built = await Task.detached(priority: .userInitiated) {
                SourceDiff.files(for: current)
            }.value
            guard !Task.isCancelled else { return }
            files = built
            builtFor = key
            // A request that came before the rows did.
            if let scrollRequest { expandIfNeeded(for: scrollRequest) }
        }
    }

    // MARK: A file

    private func header(_ file: SourceDiff.File) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
            Text(file.path)
                .font(Theme.Fonts.log.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.path)
            if let oldPath = file.oldPath {
                Text("from \(oldPath)")
                    .font(Theme.Fonts.log)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.small)
            Text(file.statusLabel)
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
            Text(verbatim: "+\(file.added)")
                .font(Theme.Fonts.log)
                .foregroundStyle(.green)
                .accessibilityLabel("\(file.added) added")
            Text(verbatim: "\u{2212}\(file.removed)")
                .font(Theme.Fonts.log)
                .foregroundStyle(.red)
                .accessibilityLabel("\(file.removed) removed")
        }
        .padding(.horizontal, Theme.medium)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func fileBody(_ file: SourceDiff.File) -> some View {
        if file.isBinary {
            note("Binary file, not shown.", id: file.placeholderID)
        } else if file.rows.isEmpty {
            note("No lines changed.", id: file.placeholderID)
        } else if file.isLarge && !expanded.contains(file.id) {
            HStack(spacing: Theme.small) {
                Text("This file changes \(file.added + file.removed) lines.")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                Button("Show") { expanded.insert(file.id) }
                    .buttonStyle(.link)
                    .font(Theme.Fonts.meta)
            }
            .padding(.horizontal, Theme.medium)
            .padding(.vertical, Theme.small)
            .id(file.placeholderID)
        } else {
            ForEach(file.rows) { row in
                SourceDiffRow(row: row, gutterTemplate: file.gutterTemplate)
            }
        }
    }

    private func note(_ text: String, id: SourceDiff.RowID) -> some View {
        Text(text)
            .font(Theme.Fonts.meta)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.medium)
            .padding(.vertical, Theme.small)
            .id(id)
    }

    // MARK: Scrolling to a finding

    private func scroll(to request: SourceDiffScroll, proxy: ScrollViewProxy) {
        guard let file = files.first(where: { $0.path == request.path }) else { return }
        expandIfNeeded(for: request)
        let target = SourceDiff.rowID(forLines: request.lines, in: file) ?? file.placeholderID
        // A hop, so a file just expanded has its rows before the scroll.
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }

    private func expandIfNeeded(for request: SourceDiffScroll) {
        guard let file = files.first(where: { $0.path == request.path }), file.isLarge else { return }
        expanded.insert(file.id)
    }
}

/// Scroll the Source mode to a finding's lines. Each request is new, so the
/// same finding can be asked for twice.
struct SourceDiffScroll: Equatable {
    let id = UUID()
    /// Repository-relative.
    let path: String
    /// In the new text; the old one for a deleted file. Nil: the file.
    let lines: LineRange?
}

/// One line of the Source mode.
private struct SourceDiffRow: View {
    let row: SourceDiff.Row
    /// Digits wide enough for the file's largest line number, laid out
    /// unseen, so every gutter in a file lines up.
    let gutterTemplate: String

    var body: some View {
        switch row.kind {
        case .gap(let count):
            Text(verbatim: count == 1 ? "1 unchanged line" : "\(count) unchanged lines")
                .font(Theme.Fonts.meta)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .padding(.leading, Theme.medium)
                .background(Color.secondary.opacity(0.06))
        case .context, .removed, .added:
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                number(row.oldLine)
                number(row.newLine)
                Text(verbatim: sign)
                    .foregroundStyle(signStyle)
                    .frame(width: Theme.large)
                    .accessibilityHidden(true)
                Text(content)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Theme.Fonts.log)
            .padding(.vertical, 1)
            .padding(.trailing, Theme.medium)
            .background(tint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    private func number(_ line: Int?) -> some View {
        Text(verbatim: gutterTemplate)
            .opacity(0)
            .overlay(alignment: .trailing) {
                Text(verbatim: line.map(String.init) ?? "")
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, Theme.small)
            .accessibilityHidden(true)
    }

    private var sign: String {
        switch row.kind {
        case .removed: "\u{2212}"
        case .added: "+"
        default: " "
        }
    }

    private var signStyle: Color {
        switch row.kind {
        case .removed: .red
        case .added: .green
        default: .secondary
        }
    }

    /// 10% under a whole changed line (§6.3).
    private var tint: Color {
        switch row.kind {
        case .removed: Color.red.opacity(0.10)
        case .added: Color.green.opacity(0.10)
        default: .clear
        }
    }

    /// The line, its changed words in bold on a stronger tint. The
    /// attributes are SwiftUI's, named in full: AppKit has a font and a
    /// background colour of its own.
    private var content: AttributedString {
        var result = AttributedString()
        let changedTint: Color = row.kind == .removed
            ? Color.red.opacity(0.22) : Color.green.opacity(0.22)
        let bold: Font = Theme.Fonts.log.weight(.bold)
        for piece in row.pieces {
            var part = AttributedString(piece.text.isEmpty ? " " : piece.text)
            if piece.isChanged {
                part[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = bold
                part[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = changedTint
            }
            result.append(part)
        }
        if result.characters.isEmpty { result = AttributedString(" ") }
        return result
    }

    private var accessibilityText: String {
        let text = row.text.isEmpty ? "blank" : row.text
        switch row.kind {
        case .removed: return "Removed, line \(row.oldLine ?? 0): \(text)"
        case .added: return "Added, line \(row.newLine ?? 0): \(text)"
        default: return "Line \(row.newLine ?? row.oldLine ?? 0): \(text)"
        }
    }
}

// MARK: - The rows, pure

/// The Source mode's rows for a snapshot (plans/corrections.md §6.3). Pure
/// and Sendable, so it runs off the main actor: `relations.json` is 11,432
/// lines.
///
/// Each hunk is shown with up to three unchanged lines either side; a longer
/// run between two hunks is one gap row. A removed and an added line at the
/// same place in a hunk are a changed pair, compared word by word.
enum SourceDiff {

    /// Unchanged lines shown around each hunk.
    static let context = 3
    /// A file with more changed lines than this waits behind Show.
    static let collapseThreshold = 400

    /// What the rows were built from: the snapshot's digest, and its files.
    struct Key: Hashable, Sendable {
        let digest: String
        let paths: [String]

        init(_ snapshot: ReviewSnapshot) {
            digest = snapshot.digest
            paths = snapshot.files.map(\.path)
        }
    }

    struct RowID: Hashable, Sendable {
        let path: String
        /// The row's place in its file; -1 for what stands in for the rows.
        let index: Int
    }

    struct Piece: Sendable, Equatable {
        let text: String
        /// A word that differs from the other line of its pair.
        let isChanged: Bool
    }

    struct Row: Sendable, Equatable, Identifiable {
        enum Kind: Sendable, Equatable {
            case context, removed, added
            /// Unchanged lines left out.
            case gap(Int)
        }

        let id: RowID
        let kind: Kind
        /// 1-based; nil on the side the line is not on.
        let oldLine: Int?
        let newLine: Int?
        /// The line without its break. Empty for a gap.
        let text: String
        /// `text` in pieces; one unchanged piece unless the line is half of
        /// a changed pair.
        let pieces: [Piece]
    }

    struct File: Sendable, Equatable, Identifiable {
        let path: String
        let oldPath: String?
        let status: ChangedFile.Status
        let isBinary: Bool
        let added: Int
        let removed: Int
        let rows: [Row]

        var id: String { path }
        var isLarge: Bool { added + removed > SourceDiff.collapseThreshold }
        var placeholderID: RowID { RowID(path: path, index: -1) }

        /// As wide as the largest line number in the rows.
        var gutterTemplate: String {
            let largest = rows.reduce(1) { max($0, $1.oldLine ?? 0, $1.newLine ?? 0) }
            return String(repeating: "8", count: String(largest).count)
        }

        var statusLabel: String {
            switch status {
            case .added: "New"
            case .deleted: "Deleted"
            case .renamed: "Renamed"
            case .modified: "Modified"
            }
        }
    }

    static func files(for snapshot: ReviewSnapshot) -> [File] {
        snapshot.files.map { file($0) }
    }

    static func file(_ changed: ChangedFile) -> File {
        File(
            path: changed.path, oldPath: changed.oldPath, status: changed.status,
            isBinary: changed.isBinary, added: changed.addedLines,
            removed: changed.removedLines,
            rows: changed.isBinary ? [] : rows(for: changed))
    }

    /// The hunks of `file`, each with its context, and the gaps between.
    static func rows(for file: ChangedFile) -> [Row] {
        let old = lines(of: file.oldText ?? "")
        let new = lines(of: file.newText ?? "")
        let hunks = file.hunks
        guard !hunks.isEmpty else { return [] }

        var rows: [Row] = []
        func add(_ kind: Row.Kind, old oldLine: Int?, new newLine: Int?, text: String,
                 pieces: [Piece]? = nil) {
            rows.append(Row(
                id: RowID(path: file.path, index: rows.count), kind: kind,
                oldLine: oldLine.map { $0 + 1 }, newLine: newLine.map { $0 + 1 },
                text: text, pieces: pieces ?? [Piece(text: text, isChanged: false)]))
        }
        /// Unchanged lines: `count` of them, from `oldStart` and `newStart`.
        func unchanged(oldStart: Int, newStart: Int, count: Int) {
            for offset in 0..<max(count, 0) {
                let newIndex = newStart + offset
                let text = newIndex < new.count ? new[newIndex]
                    : (oldStart + offset < old.count ? old[oldStart + offset] : "")
                add(.context, old: oldStart + offset, new: newIndex, text: text)
            }
        }

        var oldEnd = 0
        var newEnd = 0
        for (position, hunk) in hunks.enumerated() {
            // The unchanged run before this hunk, which pairs line for line.
            let run = min(hunk.old.lowerBound - oldEnd, hunk.new.lowerBound - newEnd)
            if position == 0 {
                let leading = min(context, max(run, 0))
                if run - leading > 0 {
                    add(.gap(run - leading), old: nil, new: nil, text: "", pieces: [])
                }
                unchanged(
                    oldStart: hunk.old.lowerBound - leading,
                    newStart: hunk.new.lowerBound - leading, count: leading)
            } else if run <= 2 * context + 1 {
                // A gap would take as much room as the lines it hides.
                unchanged(oldStart: oldEnd, newStart: newEnd, count: run)
            } else {
                unchanged(oldStart: oldEnd, newStart: newEnd, count: context)
                add(.gap(run - 2 * context), old: nil, new: nil, text: "", pieces: [])
                unchanged(
                    oldStart: hunk.old.lowerBound - context,
                    newStart: hunk.new.lowerBound - context, count: context)
            }

            let removed = hunk.old.filter { $0 < old.count }
            let added = hunk.new.filter { $0 < new.count }
            let pairs = min(removed.count, added.count)
            var removedPieces: [[Piece]?] = Array(repeating: nil, count: removed.count)
            var addedPieces: [[Piece]?] = Array(repeating: nil, count: added.count)
            for pair in 0..<pairs {
                let split = pieces(old: old[removed[pair]], new: new[added[pair]])
                removedPieces[pair] = split.old
                addedPieces[pair] = split.new
            }
            for (offset, index) in removed.enumerated() {
                add(.removed, old: index, new: nil, text: old[index], pieces: removedPieces[offset])
            }
            for (offset, index) in added.enumerated() {
                add(.added, old: nil, new: index, text: new[index], pieces: addedPieces[offset])
            }
            oldEnd = hunk.old.upperBound
            newEnd = hunk.new.upperBound
        }

        let remaining = min(old.count - oldEnd, new.count - newEnd)
        let trailing = min(context, max(remaining, 0))
        unchanged(oldStart: oldEnd, newStart: newEnd, count: trailing)
        if remaining - trailing > 0 {
            add(.gap(remaining - trailing), old: nil, new: nil, text: "", pieces: [])
        }
        return rows
    }

    /// A changed pair, word by word. Nil for a pair with no word in common,
    /// where every word would be emphasised and none would stand out.
    static func pieces(old: String, new: String) -> (old: [Piece]?, new: [Piece]?) {
        let segments = WordDiff.segments(old: old, new: new)
        let shared = segments.contains {
            $0.kind == .same && !$0.text.allSatisfy(\.isWhitespace)
        }
        guard shared else { return (nil, nil) }
        let oldPieces = segments.compactMap { segment -> Piece? in
            segment.kind == .added ? nil : Piece(text: segment.text, isChanged: segment.kind == .removed)
        }
        let newPieces = segments.compactMap { segment -> Piece? in
            segment.kind == .removed ? nil : Piece(text: segment.text, isChanged: segment.kind == .added)
        }
        return (oldPieces, newPieces)
    }

    /// The row a finding's lines lead to: the first on its side (the new
    /// side, the old for a deleted file) inside the lines, else the nearest
    /// to them. Nil without lines, or with no row on that side.
    static func rowID(forLines lines: LineRange?, in file: File) -> RowID? {
        guard let lines else { return nil }
        let deleted = file.status == .deleted
        var nearest: (id: RowID, distance: Int)?
        for row in file.rows {
            guard let line = deleted ? row.oldLine : row.newLine else { continue }
            if lines.first <= line, line <= lines.last { return row.id }
            let distance = line < lines.first ? lines.first - line : line - lines.last
            if distance < nearest?.distance ?? .max { nearest = (row.id, distance) }
        }
        return nearest?.id
    }

    /// The text's lines as git counts them, each without its break.
    static func lines(of text: String) -> [String] {
        ReviewPayload.lines(of: text).map { line in
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: line.unicodeScalars)
            if scalars.last == "\n" { scalars.removeLast() }
            if scalars.last == "\r" { scalars.removeLast() }
            return String(scalars)
        }
    }
}
