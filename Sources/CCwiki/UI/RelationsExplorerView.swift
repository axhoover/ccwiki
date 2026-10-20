import SwiftUI
// `AccessibilityNotification` lives in the Accessibility framework, which
// SwiftUI does not re-export.
import Accessibility

/// The Relations Explorer: does A imply B? (relations-explorer.md §2)
///
/// Four bands, top to bottom: the question (From, To, Models) on the bar
/// material; the verdict, fixed, so a long proof never scrolls the answer
/// away; the body, one `List`; and the footer, which is always there under
/// an answer and is never collapsible. Typing in From or To replaces the
/// body with suggestions, palette-style, the shape ⌘S and ⇧⌘R already have.
///
/// The view decides nothing about what is true or how to say it:
/// `ExplorerResult` does, off the main actor, from the engine's answer. The
/// previous answer stays up until the next one lands, so there is no flash
/// between keystrokes.
///
/// It publishes no `focusedSceneValue(\.appModel, …)`, so ⌘S, ⌘O and ⌘P
/// are disabled while it is key, as they are in Jobs: printing the reader
/// from a window that is not showing it would surprise.
struct RelationsExplorerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var result = ExplorerResult.empty
    @State private var isComputing = false
    @State private var showsProgress = false
    @State private var matcher = RelationObjectMatcher.empty

    // The fields.
    @State private var fromText = ""
    @State private var toText = ""
    /// The field typed in last, so a click on a suggestion knows where it
    /// goes even if the click took the focus.
    @State private var editingField: ExplorerField = .from
    @State private var highlightedID: String?
    /// Esc once hides the suggestions; Esc again clears the typed text.
    @State private var suggestionsDismissed = false
    /// A token picked by a click or by ⌫, which a further ⌫ removes.
    @State private var selectedToken: String?
    @FocusState private var focus: ExplorerField?

    // The answer. Ephemeral by design (SWIFTUI-RULES §3.3).
    @State private var selection: Set<String> = []
    @State private var collapsed: Set<String> = []
    @State private var showsStronger = false
    @State private var showsRules = false

    var body: some View {
        content
            .frame(minWidth: Theme.explorerMinWidth, minHeight: Theme.explorerMinHeight)
            .navigationTitle("Relations Explorer")
            .navigationSubtitle(model.explorerQuery.statement(labels: model.relationLabels) ?? "")
            .toolbar { toolbar }
            .task(id: TaskKey(query: model.explorerQuery, generation: model.libraryGeneration)) {
                await recompute()
            }
            .task(id: isComputing) { await revealProgressLater() }
            .onChange(of: model.libraryGeneration, initial: true) { rebuildMatcher() }
            .onChange(of: fromText) { _, text in textChanged(text, in: .from) }
            .onChange(of: toText) { _, text in textChanged(text, in: .to) }
            .onChange(of: focus) { _, field in
                if let field { editingField = field }
            }
            .focusedSceneValue(\.proofCopyAction, proofCopyAction)
            .onAppear { focus = .from }
            // One of Recent's two moments: the window closing.
            .onDisappear { model.rememberExplorerQuery() }
    }

    /// The answer is recomputed for every question, and after every sync.
    private struct TaskKey: Hashable {
        let query: ExplorerQuery
        let generation: Int
    }

    // MARK: Resting states

    @ViewBuilder
    private var content: some View {
        if let diagnostic = model.relations.diagnostic {
            ContentUnavailableView {
                Label("Relationships Unavailable", systemImage: "arrow.triangle.branch")
            } description: {
                Text(diagnostic.message)
            } actions: {
                if case .fileMissing = diagnostic {
                    Button("Sync Now") { model.sync() }
                        .disabled(model.syncState.isRunning)
                }
            }
        } else if model.libraryGeneration == 0 {
            ContentUnavailableView {
                Label {
                    Text("Loading the Wiki")
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .task { await openReaderIfAlone() }
        } else if model.derivation.manifest.isEmpty && !model.relations.isEmpty {
            // `Derivation(manifest:)` keeps an empty manifest exactly when
            // the bundled curation is missing: chaining without its
            // corrections would prove claims the cited theorems do not. A
            // manifest that merely has nothing to chain is not this.
            ContentUnavailableView(
                "Derivations Unavailable", systemImage: "arrow.triangle.branch",
                description: Text("This copy of CCwiki is missing its reviewed corrections, "
                    + "so it does not chain reductions. The Relations inspector still shows "
                    + "what the wiki records."))
        } else {
            VStack(spacing: 0) {
                questionBand
                Divider()
                if showsSuggestions {
                    suggestionPane
                } else {
                    answerPane
                }
            }
        }
    }

    // MARK: The question

    /// From, To and Models, labels trailing as in Mail's compose header.
    private var questionBand: some View {
        @Bindable var model = model
        let query = model.explorerQuery

        return Grid(alignment: .leading, horizontalSpacing: Theme.small, verticalSpacing: Theme.small) {
            GridRow(alignment: .top) {
                fieldLabel("From")
                ObjectTokenField(
                    field: .from, tokens: tokens(query.from), text: $fromText,
                    placeholder: query.from.isEmpty ? "Add an assumption or primitive" : "and…",
                    accessibilityName: "From, all of:", isConjunction: true,
                    selectedTokenID: selectedToken, focus: $focus,
                    onSelect: { select($0, in: .from) }, onRemove: { remove($0, from: .from) })
            }
            GridRow(alignment: .top) {
                fieldLabel("To")
                // To takes one object, so typing into a filled To replaces
                // its token; the placeholder says so rather than claim the
                // question is open.
                ObjectTokenField(
                    field: .to, tokens: tokens(query.to.map { [$0] } ?? []), text: $toText,
                    placeholder: query.to == nil ? "Anything: show everything derivable" : "Replace…",
                    accessibilityName: "To", isConjunction: false,
                    selectedTokenID: selectedToken, focus: $focus,
                    onSelect: { select($0, in: .to) }, onRemove: { remove($0, from: .to) })
            }
            GridRow(alignment: .firstTextBaseline) {
                Text("Models")
                    .font(Theme.Fonts.row)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                HStack(alignment: .firstTextBaseline, spacing: Theme.medium) {
                    Text(DerivationWording.defaultModels)
                        .font(Theme.Fonts.row)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Toggle(DerivationWording.toggleTitle,
                           isOn: $model.explorerQuery.includesIdealisedModels)
                        .toggleStyle(.checkbox)
                        .help(DerivationWording.toggleHelp)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Theme.large)
        .padding(.vertical, Theme.medium)
        .background(.bar)
        .onSubmit { _ = commitHighlighted() }
        .onKeyPress(.downArrow) { moveHighlight(1) }
        .onKeyPress(.upArrow) { moveHighlight(-1) }
        .onKeyPress(.tab) { showsSuggestions && commitHighlighted() ? .handled : .ignored }
        .onKeyPress(.escape) { escape() }
        .onKeyPress(.delete) { deleteBackward() }
    }

    /// Aligned with the first line of a field's tokens.
    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(Theme.Fonts.row)
            .foregroundStyle(.secondary)
            .padding(.top, Theme.tokenFieldPadding + Theme.tokenPaddingVertical)
            .gridColumnAlignment(.trailing)
    }

    private func tokens(_ ids: [String]) -> [ObjectTokenField.Token] {
        ids.map { (id) -> ObjectTokenField.Token in
            let object = model.relations.object(id)
            return ObjectTokenField.Token(
                id: id, label: model.relationLabels.label(id),
                isVariant: object?.isVariant ?? false, isStale: object == nil)
        }
    }

    private var chosenIDs: Set<String> {
        let query = model.explorerQuery
        return Set(query.from + (query.to.map { [$0] } ?? []))
    }

    // MARK: Editing the question

    private func select(_ id: String, in field: ExplorerField) {
        selectedToken = id
        focus = field
    }

    private func remove(_ id: String, from field: ExplorerField) {
        var query = model.explorerQuery
        switch field {
        case .from:
            query.from.removeAll { $0 == id }
        case .to:
            if query.to == id { query.to = nil }
        }
        model.explorerQuery = query
        if selectedToken == id { selectedToken = nil }
    }

    /// The highlighted suggestion becomes a token. To takes one object, so
    /// committing into a filled To replaces it.
    private func commit(_ id: String, into field: ExplorerField) {
        var query = model.explorerQuery
        switch field {
        case .from:
            query = query.adding(id)
            fromText = ""
        case .to:
            query.to = id
            toText = ""
        }
        model.explorerQuery = query
        highlightedID = nil
        suggestionsDismissed = false
        selectedToken = nil
        focus = field
    }

    /// Return, Tab or a comma with suggestions showing. True when something
    /// was committed.
    @discardableResult
    private func commitHighlighted() -> Bool {
        guard showsSuggestions, let id = currentHighlight(in: suggestions) else { return false }
        commit(id, into: focus ?? editingField)
        return true
    }

    /// A comma commits, as in Mail. Watched on the text rather than as a key,
    /// so it never reaches the field as a character.
    private func textChanged(_ text: String, in field: ExplorerField) {
        selectedToken = nil
        if text.contains(",") {
            let typed = text.replacingOccurrences(of: ",", with: "")
            let items = matcher.matches(typed, excluding: chosenIDs,
                                        limit: Theme.explorerSuggestionLimit)
            if let pick = currentHighlight(in: items) {
                commit(pick, into: field)
            } else if field == .from {
                fromText = typed
            } else {
                toText = typed
            }
            return
        }
        suggestionsDismissed = false
        highlightedID = nil
    }

    /// Esc hides the suggestions; a second Esc clears the typed text. It
    /// never closes the window.
    private func escape() -> KeyPress.Result {
        guard let field = focus else { return .ignored }
        if showsSuggestions {
            suggestionsDismissed = true
            return .handled
        }
        switch field {
        case .from where !fromText.isEmpty:
            fromText = ""
            return .handled
        case .to where !toText.isEmpty:
            toText = ""
            return .handled
        default:
            return .ignored
        }
    }

    /// ⌫ in an empty field selects its last token; a second ⌫ removes it.
    private func deleteBackward() -> KeyPress.Result {
        guard let field = focus else { return .ignored }
        let text = field == .from ? fromText : toText
        guard text.isEmpty else { return .ignored }
        let query = model.explorerQuery
        let ids = field == .from ? query.from : (query.to.map { [$0] } ?? [])
        if let selected = selectedToken, ids.contains(selected) {
            remove(selected, from: field)
            return .handled
        }
        guard let last = ids.last else { return .ignored }
        selectedToken = last
        return .handled
    }

    private func swap() {
        model.explorerQuery = model.explorerQuery.swapped()
        selectedToken = nil
    }

    /// A row's button.
    private func perform(_ command: ExplorerRow.Command) {
        var query = model.explorerQuery
        switch command {
        case .includeIdealisedModels:
            query.includesIdealisedModels = true
        case .add(let id):
            query = query.adding(id)
        case .replaceStart(let old, with: let new):
            query = query.replacingStart(old, with: new)
        case .replaceTarget(with: let new):
            query.to = new
        case .ask(let asked):
            model.explore(withToggle(asked))
            return
        }
        model.explorerQuery = query
    }

    /// A question built by the answer, with the explorer's own toggle: a
    /// click never turns it on or off.
    private func withToggle(_ query: ExplorerQuery) -> ExplorerQuery {
        var query = query
        query.includesIdealisedModels = model.explorerQuery.includesIdealisedModels
        return query
    }

    // MARK: Suggestions

    private var activeText: String {
        switch focus ?? editingField {
        case .from: fromText
        case .to: toText
        }
    }

    /// Suggestions replace the results while a field has text in it.
    private var showsSuggestions: Bool {
        focus != nil && !suggestionsDismissed
            && !activeText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A fuzzy match against every pickable object, on the main actor, so
    /// each caller computes it once and passes the items on: the pane once
    /// per evaluation, not once per row.
    private var suggestions: [RelationObjectMatcher.Item] {
        guard showsSuggestions else { return [] }
        return matcher.matches(activeText, excluding: chosenIDs, limit: Theme.explorerSuggestionLimit)
    }

    /// The highlighted row among `items`. Falls back to the first row, so
    /// Return always has a target.
    private func currentHighlight(in items: [RelationObjectMatcher.Item]) -> String? {
        highlightedID.flatMap { id in items.contains { $0.id == id } ? id : nil }
            ?? items.first?.id
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        let items = suggestions
        guard showsSuggestions, !items.isEmpty else { return .ignored }
        let current = currentHighlight(in: items)
            .flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        highlightedID = items[min(max(0, current + delta), items.count - 1)].id
        return .handled
    }

    private func announceSuggestions(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let count = ids.count
        let message = "\(count) suggestion\(count == 1 ? "" : "s")"
        AccessibilityNotification.Announcement(message).post()
    }

    /// The suggestions and their highlight, each computed once here. The
    /// count is announced as the pane appears and whenever the rows change,
    /// not on an arrow press.
    private var suggestionPane: some View {
        let items = suggestions
        let highlight = currentHighlight(in: items)
        return VStack(spacing: 0) {
            if items.isEmpty {
                if matcher.matchesOnlyComplexityClasses(activeText) {
                    ContentUnavailableView(
                        DerivationWording.complexityClassTitle, systemImage: "chart.bar",
                        description: Text(DerivationWording.complexityClassSentence))
                } else {
                    ContentUnavailableView.search(text: activeText)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                suggestionRow(item, isHighlighted: item.id == highlight)
                            }
                        }
                        .padding(.vertical, Theme.tight)
                    }
                    .onChange(of: highlight) { _, new in
                        guard let new else { return }
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
            Divider()
            HStack(spacing: Theme.medium) {
                keycap("↩", "add")
                keycap("⇥", "next field")
                keycap("esc", "dismiss")
                Spacer()
                Text("\(items.count) suggestion\(items.count == 1 ? "" : "s")")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, Theme.large)
            .padding(.vertical, Theme.small)
        }
        .onChange(of: items.map(\.id), initial: true) { _, ids in announceSuggestions(ids) }
    }

    /// Two lines: the label, then its type, its host page, or the alias that
    /// matched, as ⌘O shows it.
    private func suggestionRow(_ item: RelationObjectMatcher.Item, isHighlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.label)
                .font(Theme.Fonts.row)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail = item.detail {
                Text(detail)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, Theme.large)
        .padding(.vertical, Theme.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.selection)
                    .padding(.horizontal, Theme.small)
            }
        }
        .id(item.id)
        .contentShape(.rect)
        .onTapGesture { commit(item.id, into: focus ?? editingField) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
        // A tap gesture gives VoiceOver nothing to press; this does.
        .accessibilityAction(.default) { commit(item.id, into: focus ?? editingField) }
    }

    private func keycap(_ key: String, _ label: String) -> some View {
        HStack(spacing: Theme.tight) {
            Text(key)
                .font(Theme.Fonts.badge)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: .rect(cornerRadius: 3))
            Text(label)
                .font(Theme.Fonts.meta)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: The answer

    @ViewBuilder
    private var answerPane: some View {
        switch result.state {
        case .empty:
            ContentUnavailableView {
                Label("Ask What Follows From What", systemImage: "arrow.triangle.branch")
            } description: {
                Text("Add objects to From to see everything they derive together, or an object "
                    + "to To to see what derives it.")
            } actions: {
                if model.canExploreCurrentPage {
                    Button("Explore From This Page") {
                        if let query = model.currentPageExplorerQuery { model.explore(query) }
                    }
                }
            }
        case .unsupported(let label):
            ContentUnavailableView {
                Label(DerivationWording.complexityClassTitle, systemImage: "chart.bar")
            } description: {
                Text("\(label) is a complexity class. " + DerivationWording.complexityClassSentence)
            }
        case .nothing(let title, let description):
            ContentUnavailableView {
                Label(title, systemImage: "circle.dashed")
            } description: {
                Text(description)
            } actions: {
                if result.offersIdealisedModels {
                    Button(DerivationWording.includeIdealisedModels) {
                        perform(.includeIdealisedModels)
                    }
                }
            }
        case .answer:
            VStack(spacing: 0) {
                if let verdict = result.verdict {
                    verdictBand(verdict)
                    Divider()
                }
                ScrollViewReader { proxy in
                    resultList(proxy)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let footer = result.footer(showingStronger: showsStronger) {
                    footerBar(footer)
                }
            }
        }
    }

    // MARK: The verdict

    /// The title, statement, models, lines and footer all describe the proof
    /// shown, so Show It swaps every one of them with the proof.
    private func verdictBand(_ verdict: ExplorerResult.Verdict) -> some View {
        let title = result.verdictTitle(showingStronger: showsStronger) ?? verdict.title
        return VStack(alignment: .leading, spacing: Theme.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
                Image(systemName: verdict.symbol)
                    .foregroundStyle(symbolStyle(verdict.tone))
                    .accessibilityHidden(true)
                Text(title)
                    .font(Theme.Fonts.verdict)
                    .lineLimit(2)
                    .help(verdict.help ?? title)
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: Theme.small)
                ForEach(result.verdictModels(showingStronger: showsStronger), id: \.self) { model in
                    ModelTag(model: model)
                }
            }
            if let statement = result.verdictStatement(showingStronger: showsStronger) {
                Text(statement)
                    .font(Theme.Fonts.row)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ForEach(result.verdictLines(showingStronger: showsStronger)) { line in
                Text(line.text)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(lineStyle(line.style))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let stronger = result.stronger {
                let swapTitle: String = showsStronger ? "Show Shortest" : "Show It"
                HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
                    Text(stronger.line)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(.secondary)
                    Button(swapTitle) {
                        showsStronger.toggle()
                        selection = []
                    }
                    .buttonStyle(.link)
                    .font(Theme.Fonts.meta)
                }
            }
            if let action = verdict.action {
                Button(action.title) { perform(action.command) }
                    .controlSize(.small)
                    .padding(.top, Theme.tight)
            }
        }
        .padding(.horizontal, Theme.large)
        .padding(.vertical, Theme.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// Chained, not true: the tint, never green. No derivation is not a
    /// fault: tertiary, never red.
    private func symbolStyle(_ tone: ExplorerResult.Verdict.Tone) -> AnyShapeStyle {
        switch tone {
        case .derived: AnyShapeStyle(.tint)
        case .neutral: AnyShapeStyle(.secondary)
        case .noDerivation: AnyShapeStyle(.tertiary)
        }
    }

    private func lineStyle(_ style: ExplorerResult.Verdict.Line.Style) -> AnyShapeStyle {
        switch style {
        case .secondary: AnyShapeStyle(.secondary)
        case .muted: AnyShapeStyle(.tertiary)
        case .caution: AnyShapeStyle(Color.orange)
        }
    }

    // MARK: The list

    private func resultList(_ proxy: ScrollViewProxy) -> some View {
        let sections = result.sections(showingStronger: showsStronger)
        let actions = ExplorerRowActions(
            perform: { perform($0) },
            follow: { follow($0, proxy: proxy) })

        return List(selection: $selection) {
            ForEach(sections) { section in
                if section.title == nil && section.subtitle == nil {
                    Section {
                        sectionRows(section, actions: actions)
                    }
                } else {
                    Section {
                        sectionRows(section, actions: actions)
                    } header: {
                        ExplorerSectionHeader(section: section)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            primaryAction(ids, proxy: proxy)
        }
        .copyable(copiedStatements)
    }

    @ViewBuilder
    private func sectionRows(_ section: ExplorerSection, actions: ExplorerRowActions) -> some View {
        ForEach(section.rows) { row in
            ExplorerOutlineRow(row: row, collapsed: $collapsed, actions: actions)
        }
        if let note = section.note {
            Text(note)
                .font(Theme.Fonts.meta)
                .foregroundStyle(.tertiary)
                .listRowSeparator(.hidden)
                .selectionDisabled()
        }
    }

    /// Return and double-click.
    private func primaryAction(_ ids: Set<String>, proxy: ScrollViewProxy) {
        guard ids.count == 1, let id = ids.first,
              let row = result.row(withID: id, showingStronger: showsStronger),
              let target = row.primary
        else { return }
        follow(target, proxy: proxy)
    }

    private func follow(_ target: ExplorerRow.Target, proxy: ScrollViewProxy) {
        switch target {
        case .page(let path):
            showInReader { model.openPage(path) }
        case .section(let path, let anchor):
            showInReader { model.openPage(path, anchor: anchor) }
        case .object(let id):
            showInReader { model.openRelationObject(id) }
        case .reveal(let id):
            reveal(id, proxy: proxy)
        case .ask(let query):
            model.explore(withToggle(query))
        }
    }

    /// Pages open in the reader, and the explorer stays key, so the steps of
    /// a proof can be walked with the arrow keys and each read beside it.
    /// With no reader on screen, one is opened first.
    private func showInReader(_ open: () -> Void) {
        if model.mainWindowCount == 0 {
            openWindow(id: CCwikiApp.mainWindowID, value: ReaderWindow())
        }
        open()
    }

    /// "Shown above": select the first occurrence and scroll to it,
    /// opening whatever encloses it.
    private func reveal(_ id: String, proxy: ScrollViewProxy) {
        for ancestor in result.ancestors(of: id, showingStronger: showsStronger) {
            collapsed.remove(ancestor)
        }
        selection = [id]
        proxy.scrollTo(id, anchor: .center)
    }

    // MARK: Context menu and copying

    @ViewBuilder
    private func menu(for ids: Set<String>) -> some View {
        if ids.count == 1, let id = ids.first,
           let row = result.row(withID: id, showingStronger: showsStronger) {
            rowMenu(row)
        } else if ids.count > 1 {
            Button("Copy Statements") {
                model.copyToPasteboard(statements(for: ids).joined(separator: "\n"))
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: ExplorerRow) -> some View {
        if let page = row.page {
            Button("Open \(page.kind) “\(page.title)”") {
                showInReader { model.openPage(page.path) }
            }
        }
        if let objectID = row.objectID {
            Button("Open “\(model.relationLabels.label(objectID))”") {
                showInReader { model.openRelationObject(objectID) }
            }
        }
        if let from = row.exploreFrom, let query = model.explorerQuestion(from: from) {
            Button("Explore From Here…") { model.explore(query) }
        }
        if let ask = row.ask, ask.mode == .question,
           !withToggle(ask).isSameQuestion(as: model.explorerQuery) {
            Button("Ask About This") { model.explore(withToggle(ask)) }
        }
        if row.statement != nil || row.proof != nil {
            Divider()
        }
        if let statement = row.statement {
            Button("Copy Statement") { model.copyToPasteboard(statement) }
        }
        if let proof = row.proof {
            ProofCopyMenu { model.copyProof(proof, as: $0) }
            // Hidden rather than dimmed when there is nothing to copy, as
            // Apple's guidance asks of a context menu.
            if model.proofWriterContext.hasInlineEntries(proof.export) {
                Button("Copy BibTeX of Cited Works") { model.copyProof(proof, as: .bibtex) }
            }
        }
    }

    /// Edit → Copy Proof As: the selected rows' proof, or the answer's. None
    /// while the suggestions show, since the answer underneath is not on
    /// screen and may not match what is being typed, and none without an
    /// answer.
    private var proofCopyAction: ProofCopyAction? {
        guard !showsSuggestions, result.state == .answer,
              let copy = result.proofCopy(selection: selection, showingStronger: showsStronger)
        else { return nil }
        return ProofCopyAction(
            copy: { format in model.copyProof(copy, as: format) },
            hasInlineEntries: model.proofWriterContext.hasInlineEntries(copy.export))
    }

    /// ⌘C: the selected rows' statements, in list order.
    private var copiedStatements: [String] {
        statements(for: selection)
    }

    private func statements(for ids: Set<String>) -> [String] {
        guard !ids.isEmpty else { return [] }
        return result.rows(showingStronger: showsStronger)
            .filter { ids.contains($0.id) }
            .map { $0.statement ?? $0.title }
    }

    // MARK: The footer

    private func footerBar(_ text: String) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
                Text(text)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.small)
                if result.explainsRules(showingStronger: showsStronger) {
                    Button {
                        showsRules.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("How CCwiki derives")
                    .accessibilityLabel("How CCwiki Derives")
                    .popover(isPresented: $showsRules, arrowEdge: .top) {
                        rulesPopover
                    }
                }
            }
            .padding(.horizontal, Theme.large)
            .padding(.vertical, Theme.small)
        }
        .background(.bar)
    }

    /// The rules of derivations.md §2 in plain words. Static text, so there
    /// is no transition to worry about.
    private var rulesPopover: some View {
        VStack(alignment: .leading, spacing: Theme.small) {
            Text("How CCwiki derives")
                .font(Theme.Fonts.sectionHeader)
            ForEach(DerivationWording.rules, id: \.self) { rule in
                HStack(alignment: .firstTextBaseline, spacing: Theme.small) {
                    Text(verbatim: "•")
                        .foregroundStyle(.secondary)
                    Text(rule)
                        .font(Theme.Fonts.meta)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Theme.large)
        .frame(width: 380, alignment: .leading)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                swap()
            } label: {
                Label("Swap", systemImage: "arrow.up.arrow.down")
            }
            .disabled(!model.explorerQuery.canSwap || model.explorerQuery.mode == .empty)
            .help(swapHelp)

            Menu {
                ForEach(recents, id: \.key) { recent in
                    Button(recentTitle(recent)) { model.explore(recent) }
                }
            } label: {
                Label("Recent", systemImage: "clock.arrow.circlepath")
            }
            .disabled(recents.isEmpty)
            .help("Recent questions")
        }
    }

    /// Swap is for a single object: a conjunction cannot be a conclusion.
    private var swapHelp: String {
        model.explorerQuery.canSwap ? "Swap From and To" : "A conjunction cannot be a conclusion."
    }

    /// Up to ten earlier questions, each written as its statement; the one
    /// on screen is left out.
    private var recents: [ExplorerQuery] {
        model.explorerRecents.filter { !$0.isSameQuestion(as: model.explorerQuery) }
    }

    private func recentTitle(_ query: ExplorerQuery) -> String {
        let statement = query.statement(labels: model.relationLabels) ?? ""
        return query.includesIdealisedModels ? statement + " · with idealised models" : statement
    }

    // MARK: Computing

    /// Off the main actor: a no-derivation answer runs about a hundred
    /// closures. A superseded computation runs to completion and is
    /// discarded, which is cheaper than threading cancellation through the
    /// engine.
    private func recompute() async {
        guard model.libraryGeneration > 0 else { return }
        let query = model.explorerQuery
        let derivation = model.derivation
        let labels = model.relationLabels
        isComputing = true
        let computed = await Task.detached(priority: .userInitiated) {
            ExplorerResult.compute(query, derivation: derivation, labels: labels)
        }.value
        guard !Task.isCancelled else { return }
        isComputing = false
        // Announced when the outcome changes, not on every keystroke.
        if computed.announcement != result.announcement, let announcement = computed.announcement {
            AccessibilityNotification.Announcement(announcement).post()
        }
        result = computed
        collapsed = computed.initiallyCollapsed
        showsStronger = false
        selection = []
    }

    /// A small spinner in the verdict, only once a computation has taken
    /// longer than 150 ms, so a quick answer never flickers one.
    private func revealProgressLater() async {
        guard isComputing else {
            showsProgress = false
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, isComputing else { return }
        showsProgress = true
    }

    /// State restoration can bring this window back alone, and only a
    /// reader window's launch task loads the library: with no reader on
    /// screen after a moment, open one, so "Loading the Wiki" ends
    /// (SWIFTUI-RULES §6.5).
    private func openReaderIfAlone() async {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, model.libraryGeneration == 0, model.mainWindowCount == 0 else {
            return
        }
        openWindow(id: CCwikiApp.mainWindowID, value: ReaderWindow())
    }

    private func rebuildMatcher() {
        matcher = RelationObjectMatcher(
            manifest: model.relations, labels: model.relationLabels,
            participants: model.derivation.participants(.all))
    }
}
