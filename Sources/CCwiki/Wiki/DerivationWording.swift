import Foundation

/// The words CCwiki uses for a derived claim, in one place.
///
/// The explorer and the inspector both say what the engine found, and the
/// honesty of the feature rests on their saying it the same way: a chain of
/// two or more reductions is CCwiki's composition and is drawn `⇒*` with
/// "Derived by CCwiki from N recorded reductions"; one recorded step is the
/// wiki's own claim and reads "Recorded in the wiki"; and no derivation is
/// never a separation. The rules are plans/derivations.md §7, with the lead's
/// resolution of relations-explorer.md §6.7 for the one-step case. Every
/// sentence a reader sees about a derivation is built here or from these
/// pieces, so a review of the wording is a review of this file.
enum DerivationWording {

    // MARK: Arrows

    /// "Derivable": the transitive-closure star a cryptographer reads as
    /// derivable, never as a recorded `⇒`.
    static let derivedArrow = "⇒*"
    static let derivedBackArrow = "⇐*"
    /// One recorded step, stated by the wiki itself.
    static let recordedArrow = "⇒"
    /// "By this step", on a proof row.
    static let byStep = "⇐"
    static let conjunction = "∧"
    /// What a forward or backward question leaves open.
    static let anything = "…"

    // MARK: Counts

    /// "1 step", "3 steps". A step is a layer of the shortest proof: the
    /// depth, which is the distance the engine minimises.
    static func steps(_ count: Int) -> String {
        count == 1 ? "1 step" : "\(count) steps"
    }

    /// "Derived by CCwiki from 3 recorded reductions". Only ever said of a
    /// chain of two or more steps; one step is recorded, not derived.
    static func derivedBy(_ relationCount: Int) -> String {
        "Derived by CCwiki from \(relationCount) recorded reduction\(relationCount == 1 ? "" : "s")"
    }

    /// The verdict's provenance line: "Derived by CCwiki from 4 recorded
    /// reductions · 4 steps".
    static func provenance(relationCount: Int, depth: Int) -> String {
        derivedBy(relationCount) + " · " + steps(depth)
    }

    // MARK: Chain class (R6)

    /// The chain class in §7's words. `unstatedSteps` is how many steps of
    /// the shown proof do not state a class, which is what makes a chain
    /// `unstated`.
    static func chainClass(_ chain: Derivation.ChainClass, unstatedSteps: Int) -> String {
        switch chain {
        case .fullyBlackBox:
            "Fully black-box: every step is"
        case .relativizing:
            "Relativizing: every step relativizes"
        case .free:
            "An implication; no black-box claim"
        case .unstated:
            unstatedSteps == 1
                ? "Class unstated: 1 step does not state its"
                : "Class unstated: \(unstatedSteps) steps do not state theirs"
        }
    }

    /// The short form a row's meta line uses: "fully black-box",
    /// "relativizing", "free", "unstated".
    static func chainClassShort(_ chain: Derivation.ChainClass) -> String {
        switch chain {
        case .fullyBlackBox: "fully black-box"
        case .relativizing: "relativizing"
        case .free: "free"
        case .unstated: "unstated"
        }
    }

    /// R6's stronger chain: "A fully black-box derivation exists in 3 steps".
    /// `free` is stronger than `unstated` only in that every step states a
    /// class, so it says that rather than claim a kind of reduction.
    static func strongerChain(_ chain: Derivation.ChainClass, depth: Int) -> String {
        switch chain {
        case .fullyBlackBox:
            "A fully black-box derivation exists in \(steps(depth))"
        case .relativizing:
            "A relativizing derivation exists in \(steps(depth))"
        case .free, .unstated:
            "A derivation whose every step states its class exists in \(steps(depth))"
        }
    }

    // MARK: Models (R4)

    /// A model as the site names it. A stub's effective model is `unknown`,
    /// which reads "stub" (R3): its class and model are not evidence, and
    /// calling it a model would say they are.
    static func modelName(_ model: String) -> String {
        model == Derivation.unknownModel ? "stub" : RelationVocabulary.modelName(model)
    }

    /// What VoiceOver reads for a model tag: "uses the random oracle model".
    static func modelAccessibility(_ model: String) -> String {
        model == Derivation.unknownModel ? "uses a stub reduction" : "uses the \(modelName(model))"
    }

    /// The idealised models a fact holds in, as the verdict's title: a
    /// model-scoped result reads "Holds in the random oracle model", never
    /// a bare "holds" (§7). `nil` when nothing idealised is used.
    static func modelScope(_ models: Set<String>) -> String? {
        let idealised = models.filter { Derivation.idealisedModels.contains($0) }
            .sorted(by: Derivation.precedes)
        if !idealised.isEmpty {
            return "Holds in the " + list(idealised.map(modelName))
        }
        if models.contains(Derivation.unknownModel) {
            return "Holds only through a stub reduction"
        }
        return nil
    }

    /// The same scope as a line under a recorded result, which keeps its
    /// own title: "Holds in the random oracle model only." The stub form
    /// already says "only", so it is not said twice.
    static func modelScopeLine(_ models: Set<String>) -> String? {
        guard let scope = modelScope(models) else { return nil }
        let idealised = models.contains { Derivation.idealisedModels.contains($0) }
        return idealised ? scope + " only." : scope + "."
    }

    /// The default models, as the explorer's Models row reads them.
    static let defaultModels = "Standard, quantum and CRS"

    /// The models a no-derivation sentence is about, following the toggle.
    static func modelPhrase(includesIdealisedModels: Bool) -> String {
        includesIdealisedModels
            ? "in any model the wiki records, idealised ones included"
            : "in the standard, quantum or CRS models"
    }

    /// The toggle, in §7's words. It is part of the question, and it is not
    /// remembered across launches.
    static let toggleTitle = "Include idealised models"
    static let toggleHelp = "The random oracle, generic group and algebraic group models, and the "
        + "non-standard model. A result through one of them holds only inside that model, and is tagged."
    static let includeIdealisedModels = "Include Idealised Models"

    /// R4's words for a model given as a start with the toggle off.
    static func modelStart(_ model: String) -> String {
        "The \(modelName(model)) is a model, not an assumption. What the wiki proves in it "
            + "appears with idealised models included."
    }

    // MARK: Fixed text

    /// Under a derivation of two or more steps.
    static let derivedFooter = "Each step is a result the wiki records. The chain is CCwiki's "
        + "composition: the wiki does not state it."
    /// Under a one-step answer, which is the wiki's own claim.
    static let recordedFooter = "This is a result the wiki records."
    /// Under everything-from and everything-to.
    static let listFooter = "Derived by CCwiki from the reductions the wiki records. Something "
        + "missing here is not evidence that it does not follow."
    /// Under an empty everything-from, which has no footer: an empty list is
    /// no more evidence than a short one.
    static let nothingDerivedCaveat = "The wiki's record is incomplete, so this is not evidence "
        + "that nothing follows."
    /// Under an empty everything-to, likewise.
    static let noSourcesCaveat = "The wiki's record is incomplete, so this is not evidence that "
        + "nothing derives it."
    /// R10's footer under no derivation: fixed, never collapsible, and the
    /// engine's own text, so the two cannot drift.
    static var noPathFooter: String { Derivation.NoPathAnswer.footer }

    static let recordedTitle = "Recorded in the wiki"
    static let derivableTitle = "Derivable"
    static let noDerivationTitle = "No derivation found"

    static let backwardTitle = "Everything the wiki's reductions derive this from"
    static let backwardHelp = "Derived by CCwiki. The wiki's record is incomplete."
    static let pairsTitle = "Together with one other"
    static let pairsExplanation = "Pairs the recorded reductions use together. Either may suffice "
        + "on its own; the record does not say."
    static let hintsTitle = "Related by the page, not by a recorded reduction"
    static let completionsTitle = "Becomes derivable if you also assume"
    static let barrierHelp = "A barrier rules out reductions of a class. It bites a chain only "
        + "if the chain's class implies it."
    static let derivedBarrierHelp = "Barriers CCwiki derives from recorded ones: each composes "
        + "the recorded barrier with side reductions of its class. Derived by CCwiki."

    /// R2, wherever a complexity class is asked about.
    static let complexityClassSentence = "Complexity classes are related by containment, not "
        + "derived. Their page's Relations tab lists what contains them."
    static let complexityClassTitle = "Complexity Classes Are Not Derived"

    /// The rules of derivations.md §2, in plain words, for the footer's ⓘ.
    static let rules: [String] = [
        "Implications are used, and equivalences in both directions.",
        "Inclusions, heuristic candidates and steps touching a complexity class are never used.",
        "By default the standard model, the quantum setting and the CRS model are on. With "
            + "idealised models included, the random oracle, generic group, algebraic group and "
            + "non-standard models are too, and every step that uses one is tagged.",
        "Fully black-box: every step is. Relativizing: every step relativizes. An implication: "
            + "every step states a class, with no black-box claim. Class unstated: some step "
            + "does not state its class.",
        "A step that need not carry over is not applied inside an idealised model: only a "
            + "relativizing step composes after one.",
        // R13, as the maintainer decided it (derivations.md §0 item 4): an
        // unmet precondition is refused, never chained with a warning.
        "A step whose Statement needs more of its hypothesis than the wiki's page defines is "
            + "used only when that hypothesis is one you gave, and the derivation then says "
            + "“assuming …”, or when the step that gives the hypothesis states the stronger "
            + "notion. Otherwise CCwiki leaves the step out; it never uses it with a caveat.",
    ]

    /// The help of a no-derivation answer's Refused steps.
    static let refusedHelp = "Steps the wiki records on the way that CCwiki does not chain here, "
        + "and why. A step that needs more of its hypothesis than the step before it states is "
        + "left out, not used with a caveat."

    // MARK: The inspector (relations-explorer.md §3)

    static let inspectorCaption = "Derived by CCwiki from the recorded reductions above."
    static let impliesTitle = "Derived: implies"
    static let impliedByTitle = "Derived: implied by"
    static let impliesHelp = "What this implies through two or more recorded reductions chained "
        + "together. Derived by CCwiki; the wiki does not state these chains. Standard, quantum "
        + "and CRS models only; the Relations Explorer can include the others. Click a row for "
        + "its proof. " + leftOutChain
    static let impliedByHelp = "Objects that each imply this through two or more recorded "
        + "reductions chained together, derived by CCwiki from what the wiki records, which is "
        + "not everything known. Combinations of several objects are in the Relations Explorer. "
        + leftOutChain
    static let combinations = "Combinations of several objects…"

    /// R13 in the inspector, which lists facts and so has no row for a step
    /// it left out: the explorer has one.
    private static let leftOutChain = "A chain is left out when one of its steps needs more of a "
        + "hypothesis than the step before it states; ask the Relations Explorer about the pair "
        + "to see the step."

    // MARK: Adjustments (relations-followups.md §2.5)
    //
    // What CCwiki applies that `relations.json` does not record, beside the
    // wiki's own text. These sentences say what CCwiki did and what the wiki
    // says, never that the wiki is wrong; quotes and notions are the wiki's
    // words and are not held to that.

    static let adjustmentsTitle = "Adjustments"
    static let adjustmentsHelp = "relations.json leaves out some things the wiki's pages state: a "
        + "condition a step needs, a weaker result a step gives, which direction of an "
        + "equivalence its class covers, that an assumption is broken, or that an object is a "
        + "setting rather than an assumption. CCwiki reads each from the page, quoted here, and "
        + "applies it."

    /// A row's help. Its second sentence vouches for the quotes, so it goes
    /// when one of them is no longer on its page.
    static func adjustmentHelp(quotesFound: Bool) -> String {
        let applied = "CCwiki applies this because relations.json does not record it."
        return quotesFound ? applied + " The quoted text is the wiki's own." : applied
    }

    /// In place of a quote the page no longer has. The bundled curation stays
    /// as reviewed while the clone moves on daily, so the app says which
    /// review it still applies. `commit` is the reviewed wiki commit.
    static func unverifiedQuote(pageTitle: String, commit: String?) -> String {
        let reviewed = commit.map { " at wiki \($0.prefix(7))" } ?? ""
        return "No longer on \(pageTitle) as quoted; CCwiki still applies this as reviewed\(reviewed)."
    }

    /// A precondition a producer on the proof establishes: "OT ⇒ MPC (Kil88)
    /// needs OT secure against malicious parties. cPIR ⇒ OT (DMO00)
    /// establishes it."
    static func establishedBy(step: String, notion: String, producer: String) -> String {
        "\(step) needs \(notion). \(producer) establishes it."
    }

    /// A step refused on the way that would have concluded an object on the
    /// proof, as BM84 would have given DDH ⇒ PRG.
    static func notUsedHere(step: String, notion: String, hypothesis: String,
                            producer: String) -> String {
        "Not used here: \(step) needs \(notion), and the \(hypothesis) here comes from \(producer)."
    }

    /// A step that takes a weaker result for its hypothesis, as its Statement
    /// allows.
    static func accepted(consumer: String, producer: String, notion: String) -> String {
        "\(consumer) accepts what \(producer) gives: \(notion)."
    }

    /// The direction of an equivalence whose class the record does not cover.
    static func unstatedDirection(step: String) -> String {
        "\(step) is used with its class unstated: the record's class holds for the other "
            + "direction only."
    }

    // MARK: Lists

    /// "A and B", "A, B and C".
    static func list(_ items: [String], and word: String = "and") -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default:
            return items.dropLast().joined(separator: ", ") + " \(word) " + (items.last ?? "")
        }
    }

    /// A conjunction of objects, as one claim: `OWF ∧ KEM`.
    static func conjoined(_ labels: [String]) -> String {
        labels.joined(separator: " \(conjunction) ")
    }
}
