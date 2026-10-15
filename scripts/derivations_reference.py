#!/usr/bin/env python3
"""Reference implementation of CCwiki's derivation engine.

The specification is plans/derivations.md; this file is its executable form.
The Swift `Derivation` type (Sources/CCwiki/Wiki/Derivation.swift) must agree
with it, and the corpus test checks that agreement against the golden file
this script writes (Tests/CCwikiTests/Fixtures/derivations-golden.json).

Python 3 standard library only. The inputs are the wiki's
`.reductions/relations.json` and CCwiki's reviewed corrections,
`Resources/derivation-curation.json` (spec section 2a).

    # what follows from a set of objects, and the proof of one of them
    derivations_reference.py RELATIONS_JSON --query "ddh => ot"
    derivations_reference.py RELATIONS_JSON --query "owf, kem => pke"
    derivations_reference.py RELATIONS_JSON --query "fac => pke" --all-models

    # everything implying an object
    derivations_reference.py RELATIONS_JSON --implied-by pke

    # closure sizes, worked examples, invariants and timings
    derivations_reference.py RELATIONS_JSON --report

    # the review's regression checks (real manifest plus synthetic patches)
    derivations_reference.py RELATIONS_JSON --selftest

    # possible dropped conjuncts: reads the clone's reduction pages
    derivations_reference.py RELATIONS_JSON --lint WIKI_ROOT

    # the golden file the Swift corpus test asserts against
    derivations_reference.py RELATIONS_JSON --golden OUT.json --wiki-commit SHA

    # is every quote the curation cites still on its page? (exit 1 if not)
    derivations_reference.py RELATIONS_JSON --check-quotes WIKI_ROOT

    # the curation review: each entry beside its quotes and its effect, against
    # a clone at the golden file's commit (`make curation-review WIKI=…`)
    derivations_reference.py RELATIONS_JSON --curation-report plans/curation-review.md
        --wiki-root WIKI_ROOT --wiki-commit SHA

    # the checks that need no manifest; `make check` runs them
    derivations_reference.py --selftest-units

Rule numbers (R1, R2, ...) refer to plans/derivations.md section 2.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import sys
import time
import unicodedata
import urllib.parse
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Policy. Each constant is a rule in plans/derivations.md section 2.
# ---------------------------------------------------------------------------

#: R4. Models whose edges are eligible by default.
DEFAULT_MODELS = frozenset({"standard", "quantum", "crs"})

#: R4. Models that are off by default. A fact derived through one of them is
#: "model-scoped": it holds inside that model only (R5).
IDEALISED_MODELS = frozenset({"rom", "generic-group", "algebraic-group", "other"})

#: R3. A stub's `model` is not evidence (docs/relations-json.md, Caveats), so
#: a stub edge carries this model instead of its recorded one.
UNKNOWN_MODEL = "unknown"

#: R4. The model pages: `MODEL_PAGES` in the wiki's
#: scripts/participates-in.mjs. These nodes, and their variants, are models,
#: not assumptions. `{rom} => X` reads "X holds in the random-oracle model".
MODEL_NODES = {"rom": "rom", "ggm": "generic-group", "agm": "algebraic-group"}

#: R6. The classes closed under composition, strongest first. A chain's class
#: is the first of these that every step's class implies (reflexively).
COMPOSABLE_CLASSES = ("fully-black-box", "relativizing", "free")

#: R5. A step applied to a model-scoped fact must relativize.
RELATIVIZING = "relativizing"

#: R5. What an `unstated` step applied to a model-scoped fact does:
#: "refuse" (the spec) or "caveat" (kept for comparison in --report).
UNSTATED_AFTER_IDEALISED = "refuse"

#: R13: what a step whose precondition is not established does. "refuse" is
#: decided (plans/derivations.md §0 item 4); "caveat" is kept for `--report`
#: only.
UNMET_PRECONDITION = "refuse"

#: R2. Node types that never take part in a derivation.
EXCLUDED_TYPES = frozenset({"complexity-class"})

#: R10. Node types offered as one-object completions.
COMPLETION_TYPES = frozenset({"primitive", "assumption"})

#: R10 and R11. Display caps.
COMPLETION_CAP = 8
IMPLIED_BY_SINGLE_CAP = 40
IMPLIED_BY_GROUP_CAP = 12

#: R12. Derived barriers: side edges are standard-model only, and every node
#: on a side chain, both endpoints included, is a primitive.
DERIVED_BARRIER_SIDE_MODEL = "standard"
DERIVED_BARRIER_NODE_TYPE = "primitive"

#: R8. The barrier class that refutes one named construction only.
FIXED_CONSTRUCTION = "fixed-construction"

#: Corpus sentinel: a reduction whose securityLoss names one of these needs a
#: `requires` entry in the curation (section 2a).
REGIME_WORDS = ("sub-exponential", "subexponential", "quasi-polynomial", "quasipolynomial")

#: R14 from the record itself (plans/relations-followups.md §4.4, ask 2): the
#: sentence a refutation the manifest records with `refutedBy` reads. The
#: engine has the manifest but no labels, so it says where the attack is
#: rather than naming the object.
RECORDED_REFUTATION_TEXT = "Its page records the attack."

CLASS_RANK = {"fully-black-box": 0, "relativizing": 1, "free": 2, "unstated": 3}
STRENGTH_RANK = {"unconditional": 0, "conditional": 1}
EFFECT_RANK = {"contradiction": 0, "complexity": 1}

REPOSITORY = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
DEFAULT_CURATION = os.path.join(REPOSITORY, "Resources", "derivation-curation.json")
#: The golden file: the review document is generated against its manifest.
GOLDEN_FIXTURE = os.path.join(REPOSITORY, "Tests", "CCwikiTests", "Fixtures", "derivations-golden.json")
#: The quote-matching cases Python and Swift are both held to (§2.6 of
#: plans/relations-followups.md).
QUOTE_CASES = os.path.join(REPOSITORY, "Tests", "CCwikiTests", "Fixtures", "quote-cases.json")
#: The wiki asks, as a document and in the wiki's review-inbox format.
WIKI_ASKS = os.path.join(REPOSITORY, "plans", "wiki-asks.md")
WIKI_ASKS_INBOX = os.path.join(REPOSITORY, "plans", "wiki-asks.inbox.json")
WIKI_REPOSITORY = "https://github.com/axhoover/cryptology.city"

FOOTER = (
    "CCwiki found no derivation from the reductions the wiki records. "
    "This is not a separation: the record is incomplete, and only the "
    "barriers listed here are results, each for the class of reduction it names."
)


def sha256_bytes(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


# ---------------------------------------------------------------------------
# The manifest
# ---------------------------------------------------------------------------


class Manifest:
    def __init__(self, data: dict, sha256: str = ""):
        if data.get("version") != 1:
            raise SystemExit(f"relations.json version {data.get('version')}; this knows 1")
        self.data = data
        self.sha256 = sha256
        self.objects = {o["id"]: o for o in data["objects"]}
        self.reductions = {r["id"]: r for r in data["reductions"]}
        self.barriers = {b["id"]: b for b in data["barriers"]}
        self.classes = data["classes"]
        self.sentinels = set(data.get("classSentinels", []))
        self.propositions = data.get("propositions", {})
        self._closure = {}
        for name in self.classes:
            seen, stack = set(), [name]
            while stack:
                for broader in self.classes.get(stack.pop(), {}).get("implies", []):
                    if broader not in seen:
                        seen.add(broader)
                        stack.append(broader)
            self._closure[name] = seen

    @classmethod
    def load(cls, path: str) -> "Manifest":
        with open(path, "rb") as f:
            raw = f.read()
        return cls(json.loads(raw), sha256_bytes(raw))

    def implies(self, narrower: str, broader: str) -> bool:
        """`narrower implies* broader`, reflexive; a sentinel implies nothing."""
        if narrower in self.sentinels or broader in self.sentinels:
            return False
        if narrower not in self.classes or broader not in self.classes:
            return False
        return narrower == broader or broader in self._closure[narrower]

    def type(self, oid: str) -> str:
        return self.objects.get(oid, {}).get("type", "")

    def title(self, oid: str) -> str:
        o = self.objects.get(oid)
        if not o:
            return oid
        if o["kind"] == "variant" and o.get("of") in self.objects:
            return f"{self.objects[o['of']]['title']} § {o['title']}"
        return o["title"]

    def model_of_node(self, oid: str) -> str | None:
        """R4: the model a model node stands for, or None."""
        if oid in MODEL_NODES:
            return MODEL_NODES[oid]
        o = self.objects.get(oid)
        if o and o["kind"] == "variant" and o.get("of") in MODEL_NODES:
            return MODEL_NODES[o["of"]]
        return None

    # -- the upstream fields (plans/relations-followups.md §4.4) ---------------
    # Asked of the wiki in plans/wiki-asks.md and read now, so a regenerated
    # relations.json takes effect the day it lands. Each reads as the Swift
    # decoder reads it: absent, null or of the wrong type costs that field its
    # default and nothing else.

    def reverse_class(self, rid: str) -> str | None:
        """Ask 1: an equivalence's class from conclusion to hypothesis, or
        None for a manifest from before the field."""
        v = self.reductions.get(rid, {}).get("reverseClass")
        return v if isinstance(v, str) else None

    def refuted_by(self, oid: str) -> list:
        """Ask 2: the reference wikilinks that refute this object or variant
        itself (never its variants), or []."""
        v = self.objects.get(oid, {}).get("refutedBy")
        return list(v) if isinstance(v, list) and all(isinstance(x, str) for x in v) else []

    def barrier_model(self, bid: str) -> str:
        """Ask 3: the model a barrier's theorem is proved in, "standard" when
        the manifest does not say."""
        v = self.barriers.get(bid, {}).get("model")
        return v if isinstance(v, str) else "standard"

    def counts(self) -> dict:
        return {
            "objects": len(self.objects),
            "reductions": len(self.reductions),
            "barriers": len(self.barriers),
        }


# ---------------------------------------------------------------------------
# The curation (section 2a): what the manifest does not record
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Requirement:
    """R13. A step's hypothesis must be a stronger notion than its node."""
    edge: str
    reverse: bool
    hypothesis: str
    notion: str
    met_by: frozenset  # reductions whose conclusion is that notion


@dataclass(frozen=True)
class Weakening:
    """R13. A step concludes a weaker notion than its node."""
    edge: str
    notion: str
    accepted_by: frozenset  # consumers whose conclusion holds from the weaker notion


class Curation:
    def __init__(self, data: dict, sha256: str = ""):
        self.data = data
        self.sha256 = sha256
        self.refuted = {e["object"]: e for e in data.get("refuted", [])}
        self.settings = {e["object"]: e for e in data.get("settings", [])}
        self.quarantine = {e["edge"]: e for e in data.get("quarantine", [])}
        self.equivalences = dict(data.get("equivalences", {}))
        self.requires = {}
        for e in data.get("requires", []):
            rev = e.get("direction", "forward") == "reverse"
            req = Requirement(e["edge"], rev, e["hypothesis"], e["notion"], frozenset(e.get("metBy", [])))
            self.requires.setdefault((e["edge"], rev), []).append(req)
        self.weakens = {e["edge"]: Weakening(e["edge"], e["notion"], frozenset(e.get("acceptedBy", [])))
                        for e in data.get("weakens", [])}

    @classmethod
    def load(cls, path: str) -> "Curation":
        with open(path, "rb") as f:
            raw = f.read()
        return cls(json.loads(raw), sha256_bytes(raw))

    @classmethod
    def empty(cls) -> "Curation":
        return cls({}, "")

    def quarantined(self, edge: str, reverse: bool):
        """R13: the quarantine entry that holds this direction of `edge` back,
        or None. An entry without `direction` quarantines the whole reduction;
        one with `direction` ("reverse", or anything else for the forward
        direction) quarantines that direction of an equivalence alone, and the
        other direction stays a step (Swift's
        `DerivationCuration.quarantineReason(_:isReverse:)`)."""
        e = self.quarantine.get(edge)
        if e is None:
            return None
        d = e.get("direction")
        return e if d is None or (d == "reverse") == reverse else None

    def adding_refutations(self, refutations: list) -> "Curation":
        """A copy whose `refuted` also holds these, each replacing the file's
        for the same object: the manifest's record wins over CCwiki's.
        Everything else, `data` and `sha256` included, is the file's, so a
        manifest refutation is never an entry (Swift's
        `DerivationCuration.adding(refutations:)`)."""
        merged = copy.copy(self)
        merged.refuted = dict(self.refuted)
        for r in refutations:
            merged.refuted[r["object"]] = r
        return merged

    def unresolved(self, m: Manifest) -> list:
        """Curation ids the manifest no longer has. The corpus test fails on any."""
        bad = []
        for o in list(self.refuted) + list(self.settings):
            if o not in m.objects:
                bad.append(f"object {o}")
        for e in (list(self.quarantine) + list(self.equivalences) + list(self.weakens)
                  + list(self.data.get("statementLint", {}))):
            if e not in m.reductions:
                bad.append(f"reduction {e}")
        for e, v in self.equivalences.items():
            if e in m.reductions and m.reductions[e]["kind"] != "equivalence":
                bad.append(f"not an equivalence {e}")
        # A quarantine scoped to one direction names a direction of an
        # equivalence; an implication has only the one.
        for e, q in self.quarantine.items():
            if q.get("direction") is not None and e in m.reductions and m.reductions[e]["kind"] != "equivalence":
                bad.append(f"not an equivalence {e}")
        for (e, rev), reqs in self.requires.items():
            r = m.reductions.get(e)
            if r is None:
                bad.append(f"reduction {e}")
                continue
            hyps = [r["conclusion"]] if rev else r["hypotheses"]
            for q in reqs:
                if q.hypothesis not in hyps:
                    bad.append(f"hypothesis {e}:{q.hypothesis}")
                bad += [f"reduction {p}" for p in q.met_by if p not in m.reductions]
        for w in self.weakens.values():
            bad += [f"reduction {p}" for p in w.accepted_by if p not in m.reductions]
        return sorted(set(bad))


_CITATION_LINK = re.compile(r"!?\[\[([^\[\]|#\\]+)?(#+[^\[\]|#\\]+)?(\\?\|[^\[\]#]*)?\]\]")


def citation_key(entry: str) -> str | None:
    """The citation key a `source` or `refutedBy` entry is shown by, as
    Swift's `RelationText.citationKey` reads it: `[[KEY - Title|KEY]]` ->
    `KEY`; a link with no display text takes the key from its file name;
    a bare token such as `folklore` is itself. None for an empty entry."""
    trimmed = entry.strip()
    m = _CITATION_LINK.search(trimmed)
    if m is None:
        return trimmed or None
    alias = m.group(3)
    if alias is not None:
        alias = alias.lstrip("\\")[1:].strip()
        if alias:
            return alias
    base = (m.group(1) or "").strip().split("/")[-1]
    key = base.split(" - ")[0].strip()
    return key or base or None


def manifest_refutations(m: Manifest) -> list:
    """R14 from the record (§4.4, ask 2): each object or variant whose
    manifest record carries `refutedBy`, as a refutation. Its source is the
    entries' citation keys; its evidence, the entries as recorded."""
    out = []
    for oid in sorted(m.objects):
        entries = m.refuted_by(oid)
        if not entries:
            continue
        keys = [k for k in (citation_key(e) for e in entries) if k]
        out.append({"object": oid, "source": ", ".join(keys), "text": RECORDED_REFUTATION_TEXT,
                    "evidence": ", ".join(entries)})
    return out


# ---------------------------------------------------------------------------
# Steps: the eligible, directed Horn clauses (R1-R4)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Step:
    edge: str  # reductions[].id
    hyps: tuple  # a conjunction, never split
    concl: str
    reverse: bool  # the backward direction of an equivalence
    model: str  # effective model (R3, R4)
    cls: str  # effective class (R1, R3)
    stub: bool
    requires: tuple = ()  # R13: Requirements on this step's hypotheses
    weakens: Weakening | None = None  # R13: this step concludes a weaker notion

    @property
    def default(self) -> bool:
        return self.model in DEFAULT_MODELS

    @property
    def sort_key(self):
        return (self.edge, self.reverse)

    @property
    def clean(self) -> bool:
        """No precondition, no weakened conclusion, not a stub (R12 side edges)."""
        return not self.requires and self.weakens is None and not self.stub


def build_steps(m: Manifest, cur: Curation):
    """Returns (steps, quarantined steps, excluded reason -> [edge ids],
    unreviewed equivalence ids)."""
    steps, quarantined, excluded, unreviewed = [], [], {}, []

    def skip(reason, rid):
        excluded.setdefault(reason, []).append(rid)

    for rid in sorted(m.reductions):
        r = m.reductions[rid]
        ends = list(r["hypotheses"]) + [r["conclusion"]]
        if r["kind"] == "inclusion":  # R1
            skip("inclusion", rid)
            continue
        if r["kind"] not in ("implication", "equivalence"):
            skip("unknown-kind", rid)
            continue
        if r.get("heuristic"):  # R1
            skip("heuristic", rid)
            continue
        if any(m.type(e) in EXCLUDED_TYPES for e in ends):  # R2
            skip("complexity-class-endpoint", rid)
            continue
        if any(e not in m.objects for e in ends):
            skip("unresolved-endpoint", rid)
            continue
        if m.model_of_node(r["conclusion"]):  # R4: a model is never concluded
            skip("concludes-a-model", rid)
            continue
        model, cls, stub = r["model"], r["class"], r.get("status") == "stub"
        # R4: an edge whose sole hypothesis is a model node is in that model,
        # whatever its record says.
        if len(r["hypotheses"]) == 1 and m.model_of_node(r["hypotheses"][0]):
            model = m.model_of_node(r["hypotheses"][0])
        # R3: a stub's class and model are not evidence.
        if stub:
            model, cls = UNKNOWN_MODEL, "unstated"
        dirs = [(False, tuple(r["hypotheses"]), r["conclusion"], cls)]
        if r["kind"] == "equivalence":  # R1: both directions, each with its own class
            rv, recorded = cur.equivalences.get(rid), m.reverse_class(rid)
            if recorded is not None:
                # The record states each direction's class (§4.4, ask 1), so
                # the curation's table is not read for it. R3 still makes a
                # stub unstated both ways.
                fwd_cls = cls
                rev_cls = "unstated" if stub else recorded
            elif rv is None:
                unreviewed.append(rid)
                fwd_cls = rev_cls = "unstated"
            else:
                fwd_cls = cls if rv.get("forward") == "record" else "unstated"
                rev_cls = cls if rv.get("reverse") == "record" else "unstated"
            dirs = [(False, tuple(r["hypotheses"]), r["conclusion"], fwd_cls),
                    (True, (r["conclusion"],), r["hypotheses"][0], rev_cls)]
        held = 0
        for rev, hyps, concl, c in dirs:
            s = Step(rid, hyps, concl, rev, model, c, stub,
                     tuple(cur.requires.get((rid, rev), ())),
                     None if rev else cur.weakens.get(rid))
            # R13: the record does not match the Statement, for the whole
            # reduction or for this direction of an equivalence.
            if cur.quarantined(rid, rev) is not None:
                quarantined.append(s)
                held += 1
            else:
                steps.append(s)
        if held == len(dirs):  # R13: no direction of it is a step
            skip("quarantined", rid)
    return steps, quarantined, excluded, unreviewed


# ---------------------------------------------------------------------------
# Facts and closures (R5-R7, R13)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Fact:
    id: str
    depth: int
    step: Step | None  # None: given
    models: frozenset  # non-standard models the derivation relies on
    scoped: bool  # R5: holds only inside an idealised model
    chain: str  # R6: chain class
    assumes: frozenset = frozenset()  # R13: Requirements discharged by assuming a given
    weak: Weakening | None = None  # R13: only the weaker notion is derived
    weak_inputs: frozenset = frozenset()  # hypotheses consumed as weakened facts
    caveats: frozenset = frozenset()  # comparison policies only


@dataclass
class Closure:
    start: tuple
    include_idealised: bool
    facts: dict = field(default_factory=dict)  # full notion
    weak: dict = field(default_factory=dict)  # weakened notion only (R13)
    blocked: dict = field(default_factory=dict)  # (edge, reverse) -> (step, refusal)

    def get(self, oid):
        return self.facts.get(oid) or self.weak.get(oid)


class Derivation:
    def __init__(self, m: Manifest, cur: Curation | None = None,
                 policy: str = UNSTATED_AFTER_IDEALISED, precondition_policy: str = UNMET_PRECONDITION,
                 *, steps=None, quarantined=None, allow_assume: bool = True, rules: bool = True):
        self.m = m
        # R14 from the record (§4.4, ask 2): a manifest's `refutedBy` joins
        # the working curation before anything reads it, so every rule that
        # reads `refuted` applies it unedited.
        self.cur = (cur if cur is not None else Curation.empty()).adding_refutations(manifest_refutations(m))
        self.policy = policy
        self.pre_policy = precondition_policy
        self.allow_assume = allow_assume
        self.rules = rules
        if steps is None:
            self.steps, self.quarantined, self.excluded, self.unreviewed = build_steps(m, self.cur)
        else:
            self.steps, self.quarantined, self.excluded, self.unreviewed = steps, list(quarantined or []), {}, []
        self.default_steps = [s for s in self.steps if s.default and not s.stub]
        self.step_index = {s.sort_key: s for s in self.steps + self.quarantined}
        self._closure_cache = {}
        self._sub = {}
        self._rules_cache = None

    # -- engines over a subset of the steps -----------------------------------

    def _derive(self, key, steps, **kw) -> "Derivation":
        if key not in self._sub:
            sub = Derivation(self.m, self.cur, kw.get("policy", self.policy),
                             kw.get("precondition_policy", self.pre_policy),
                             steps=steps, quarantined=self.quarantined,
                             allow_assume=kw.get("allow_assume", self.allow_assume),
                             rules=kw.get("rules", self.rules))
            sub.excluded, sub.unreviewed = self.excluded, self.unreviewed
            self._sub[key] = sub
        return self._sub[key]

    def restricted(self, cls: str) -> "Derivation":
        """R6: the same engine over only the steps whose class implies `cls`."""
        return self._derive(("class", cls), [s for s in self.steps if self.m.implies(s.cls, cls)])

    def clean_standard(self, cls: str) -> "Derivation":
        """R8: standard-model steps only, no stub, and no precondition
        discharged by assuming a given. `cls` "any" admits unstated steps too:
        an unstated step is still a proved implication, so it counts against
        a barrier on `free` reductions."""
        keep = [s for s in self.steps if s.model == "standard" and not s.stub
                and (cls == "any" or self.m.implies(s.cls, cls))]
        return self._derive(("clean", cls), keep, allow_assume=False,
                            policy="refuse", precondition_policy="refuse")

    def relaxed(self) -> "Derivation":
        """Plain Horn closure over every eligible step, quarantined ones
        included: what R5 and R13 refuse is read off its trees."""
        return self._derive(("relaxed",), self.steps + self.quarantined, rules=False)

    # -- R6 ------------------------------------------------------------------

    def chain_class(self, classes) -> str:
        classes = list(classes)
        for c in COMPOSABLE_CLASSES:
            if all(self.m.implies(x, c) for x in classes):
                return c
        return "unstated"

    def strongest(self, start, target: str, include_idealised: bool, shown: Fact):
        """R6. The strongest class of any derivation of the same notion of
        `target` that uses no model, assumption or caveat the shown one does
        not: (class, depth, edges), or None."""
        for c in COMPOSABLE_CLASSES:
            sub = self.restricted(c)
            cl = sub.closure(start, include_idealised)
            f = cl.facts.get(target) if shown.weak is None else cl.weak.get(target)
            if f is None or f.step is None:
                continue
            if shown.weak is not None and (f.weak is None or f.weak.edge != shown.weak.edge):
                continue
            if f.models <= shown.models and f.assumes <= shown.assumes and f.caveats <= shown.caveats:
                return c, f.depth, sub.tree_edges(cl, target)
        return None

    # -- R5 and R13: may a step fire ------------------------------------------

    def _check(self, s: Step, hf: list, phase: int):
        """Returns (fires, assumes, caveats, refusal). A refusal of None with
        fires False means "not yet": a given that needs assuming waits for
        phase 2."""
        assumes, caveats = set(), set()
        if not self.rules:
            return True, assumes, caveats, None
        byid = dict(zip(s.hyps, hf))
        for req in s.requires:  # R13
            f = byid[req.hypothesis]
            if f.step is None:
                if phase >= 2 and self.allow_assume:
                    assumes.add(req)
                    continue
                return False, None, None, None
            if f.step.edge in req.met_by:
                continue
            if self.pre_policy == "caveat" and phase >= 2:
                caveats.add(("requires", s.edge, req.hypothesis))
                continue
            return False, None, None, {"kind": "requires", "hypothesis": req.hypothesis,
                                       "notion": req.notion, "producedBy": f.step.edge}
        if any(f.scoped for f in hf) and not self.m.implies(s.cls, RELATIVIZING):  # R5
            if s.cls == "unstated" and self.policy == "caveat":
                caveats.add(("idealised", s.edge))
            else:
                return False, None, None, {"kind": "idealised-composition", "class": s.cls,
                                           "scopedHypotheses": [f.id for f in hf if f.scoped]}
        return True, assumes, caveats, None

    def _fact(self, s: Step, hf: list, weak_in: set, depth: int, assumes, caveats, makes_weak: bool) -> Fact:
        models = frozenset().union(*(f.models for f in hf))
        if s.model != "standard":
            models |= {s.model}
        scoped = any(f.scoped for f in hf) or s.model in IDEALISED_MODELS or s.model == UNKNOWN_MODEL
        # A given fact's chain is fully-black-box, the identity of the meet.
        chain = self.chain_class([s.cls] + [f.chain for f in hf])
        return Fact(s.concl, depth, s, models, scoped, chain,
                    frozenset().union(*(f.assumes for f in hf)) | frozenset(assumes),
                    s.weakens if makes_weak else None, frozenset(weak_in),
                    frozenset().union(*(f.caveats for f in hf)) | frozenset(caveats))

    @staticmethod
    def preference(f: Fact):
        """R7 tie-break among candidates for one fact at one layer."""
        return (len(f.models), len(f.assumes), len(f.caveats), CLASS_RANK[f.chain], f.step.edge, f.step.reverse)

    # -- forward chaining ----------------------------------------------------

    def _layers(self, cl: Closure, steps: list, phase: int):
        """Layered Horn chaining. A step fires at layer k when every hypothesis
        is known with depth < k; each new fact takes the preferred candidate
        among the steps firing at its first layer, and never changes after.
        A weakened fact (R13) is kept apart and never blocks a full one."""
        known, weak = cl.facts, cl.weak
        k = 0
        while True:
            k += 1
            cands, wcands = {}, {}
            for s in steps:
                makes_weak = self.rules and s.weakens is not None
                if s.concl in known or (makes_weak and s.concl in weak):
                    continue
                hf, weak_in, extra, ok = [], set(), set(), True
                for h in s.hyps:
                    f = known.get(h)
                    if f is not None and f.depth < k:
                        hf.append(f)
                        continue
                    w = weak.get(h)
                    if w is not None and w.depth < k:
                        if s.edge in w.weak.accepted_by:
                            hf.append(w)
                            weak_in.add(h)
                            continue
                        if self.pre_policy == "caveat" and phase >= 2:
                            hf.append(w)
                            weak_in.add(h)
                            extra.add(("weakened", w.step.edge, s.edge))
                            continue
                        cl.blocked.setdefault(s.sort_key, (s, {
                            "kind": "weakened", "hypothesis": h, "producedBy": w.step.edge,
                            "notion": w.weak.notion}))
                    ok = False
                    break
                if not ok:
                    continue
                fires, assumes, cav, refusal = self._check(s, hf, phase)
                if not fires:
                    if refusal is not None:
                        cl.blocked.setdefault(s.sort_key, (s, refusal))
                    continue
                c = self._fact(s, hf, weak_in, k, assumes, cav | extra, makes_weak)
                into = wcands if makes_weak else cands
                if s.concl not in into or self.preference(c) < self.preference(into[s.concl]):
                    into[s.concl] = c
            known.update(cands)
            weak.update(wcands)
            deepest = max((f.depth for f in list(known.values()) + list(weak.values())), default=0)
            if not cands and not wcands and k > deepest:
                return

    def closure(self, start, include_idealised: bool = False) -> Closure:
        start = tuple(sorted(set(start)))
        key = (start, include_idealised)
        if key in self._closure_cache:
            return self._closure_cache[key]
        cl = Closure(start, include_idealised)
        # Every start is a given fact. A model node given as a start (R4) is
        # not itself model-scoped: the edges leaving it are the idealised
        # steps, and what they conclude is scoped.
        cl.facts = {s: Fact(s, 0, None, frozenset(), False, "fully-black-box") for s in start}
        # Phase 1: default models, nothing assumed; every fact is clean (R4, R13).
        self._layers(cl, self.default_steps, 1)
        # Phase 2: default models; a precondition on a given may be assumed (R13).
        if self.allow_assume or self.pre_policy == "caveat":
            self._layers(cl, self.default_steps, 2)
        # Phase 3: every eligible step; never replaces an earlier fact (R4, R5).
        if include_idealised:
            self._layers(cl, self.steps, 3)
        self._closure_cache[key] = cl
        return cl

    def single(self, oid: str, include_idealised: bool = False) -> Closure:
        return self.closure([oid], include_idealised)

    # -- proof trees (R7) ----------------------------------------------------

    def tree(self, cl: Closure, target: str) -> list:
        """Depth-first, hypotheses in the edge's order. A fact already shown is
        a reference, never a second copy of its subtree."""
        rows, seen = [], set()

        def walk(fid, weak, level):
            f = cl.weak[fid] if weak else cl.facts[fid]
            ref = (fid, weak) in seen
            seen.add((fid, weak))
            rows.append({"fact": fid, "weak": weak, "level": level, "ref": ref, "given": f.step is None,
                         "edge": None if f.step is None else f.step.edge,
                         "reverse": False if f.step is None else f.step.reverse})
            if not ref and f.step is not None:
                for h in f.step.hyps:
                    walk(h, h in f.weak_inputs, level + 1)

        walk(target, target not in cl.facts, 0)
        return rows

    def tree_edges(self, cl: Closure, target: str) -> list:
        return sorted({r["edge"] for r in self.tree(cl, target) if r["edge"]})

    def tree_steps(self, cl: Closure, target: str) -> list:
        return sorted({(r["edge"], r["reverse"]) for r in self.tree(cl, target) if r["edge"]})

    def render(self, cl: Closure, target: str) -> str:
        lines = []
        for r in self.tree(cl, target):
            pad = "  " * r["level"]
            name = self.m.title(r["fact"])
            f = cl.weak[r["fact"]] if r["weak"] else cl.facts[r["fact"]]
            if r["given"]:
                lines.append(f"{pad}{name}  (given)")
            elif r["ref"]:
                lines.append(f"{pad}{name}  (shown above)")
            else:
                s = f.step
                red = self.m.reductions[s.edge]
                rev = ", reverse of the equivalence" if s.reverse else ""
                lines.append(f"{pad}{name}  <= {s.edge} [{s.cls}, {s.model}{rev}] {red['title']}")
                for q in s.requires:
                    if q in f.assumes:
                        lines.append(f"{pad}    assuming {q.notion}")
                if f.weak:
                    lines.append(f"{pad}    only: {f.weak.notion}")
        return "\n".join(lines)

    # -- barriers (R8) ---------------------------------------------------------

    def recorded_barriers(self, hyps, concl) -> list:
        hs = set(hyps)
        return sorted(b["id"] for b in self.m.barriers.values()
                      if set(b["hypotheses"]) == hs and b["conclusion"] == concl)

    def consequence_rules(self, b: dict) -> list:
        """R8, R12. Each consequence at its own class, with what it does: a
        contradiction, or a complexity proposition believed false, rules the
        reduction out; one believed true makes it a major result; the other
        kinds are not interpreted."""
        out = []
        for i, cons in enumerate(b["consequences"]):
            kind = cons["kind"]
            c = cons.get("class") or b["class"]
            effect = None
            if kind == "contradiction":
                effect = "rules-out"
            elif kind == "complexity":
                p = self.m.propositions.get(cons.get("target", ""))
                believed = p.get("believed") if p else None
                effect = "rules-out" if believed is False else "major-result" if believed is True else None
            out.append({"index": i, "kind": kind, "target": cons.get("target", ""), "class": c, "effect": effect})
        return out

    def barrier_view(self, bid: str) -> dict:
        """R8. A recorded barrier as an answer lists it, with the qualifier the
        UI must print beside its title."""
        b = self.m.barriers[bid]
        if b.get("status") == "stub":
            q = "stub"
        elif b["class"] in self.m.sentinels or b["class"] not in self.m.classes:
            q = "unclassified"
        elif b["class"] == FIXED_CONSTRUCTION:
            q = "fixed-construction"
        else:
            q = None
        return {"id": bid, "class": b["class"], "strength": b["strength"],
                "conditionalOn": list(b.get("conditionalOn", [])), "qualifier": q,
                "consequences": self.consequence_rules(b),
                "circumventedBy": list(b.get("circumventedBy", []))}

    def chain_exists(self, start, target: str, cls: str):
        """R8. Does ANY standard-model, precondition-clean derivation of
        `target` have a class that implies* `cls`? Returns that class (or
        "unstated" for a `free` barrier met by an unstated chain), or None."""
        for c in COMPOSABLE_CLASSES:
            if self.m.implies(c, cls) and target in self.clean_standard(c).closure(start).facts:
                return c
        if cls == "free" and target in self.clean_standard("any").closure(start).facts:
            return "unstated"
        return None

    # -- R12: derived barriers -----------------------------------------------

    def _side_steps(self, cls: str) -> list:
        prim = DERIVED_BARRIER_NODE_TYPE
        return [s for s in self.steps
                if len(s.hyps) == 1 and s.clean and s.model == DERIVED_BARRIER_SIDE_MODEL
                and (self.m.implies(s.cls, cls) or (cls == "free" and s.cls == "unstated"))
                and self.m.type(s.hyps[0]) == prim and self.m.type(s.concl) == prim]

    @staticmethod
    def _reach(origin: str, steps: list, forward: bool) -> dict:
        """BFS over single-hypothesis side steps: node -> path of (edge, reverse)
        from origin (forward) or to origin (backward)."""
        nxt = {}
        for s in steps:
            a, b = (s.hyps[0], s.concl) if forward else (s.concl, s.hyps[0])
            nxt.setdefault(a, []).append((b, s))
        for a in nxt:
            nxt[a].sort(key=lambda t: (t[1].edge, t[1].reverse))
        paths, frontier = {origin: []}, [origin]
        while frontier:
            new = []
            for a in frontier:
                for b, s in nxt.get(a, []):
                    if b not in paths:
                        paths[b] = paths[a] + [(s.edge, s.reverse)]
                        new.append(b)
            frontier = sorted(new)
        return paths

    def barrier_rules(self) -> list:
        """R12. One rule per (barrier, consequence) that propagates."""
        if self._rules_cache is None:
            prim = DERIVED_BARRIER_NODE_TYPE
            rules = []
            for bid in sorted(self.m.barriers):
                b = self.m.barriers[bid]
                if b.get("status") == "stub" or len(b["hypotheses"]) != 1:
                    continue
                # Side reductions are standard-model, so only a barrier proved
                # in the standard model composes with them (§4.4, ask 3). R8
                # still checks every barrier.
                if self.m.barrier_model(bid) != "standard":
                    continue
                x, y = b["hypotheses"][0], b["conclusion"]
                if self.m.type(x) != prim or self.m.type(y) != prim:
                    continue
                for r in self.consequence_rules(b):
                    if r["effect"] != "rules-out" or r["class"] not in COMPOSABLE_CLASSES:
                        continue
                    side = self._side_steps(r["class"])
                    rules.append({"barrier": bid, "consequence": r, "class": r["class"], "x": x, "y": y,
                                  "ups": self._reach(x, side, True), "downs": self._reach(y, side, False)})
            self._rules_cache = rules
        return self._rules_cache

    def _derived_record(self, ru: dict, start: list, target: str) -> dict:
        b = self.m.barriers[ru["barrier"]]
        return {"barrier": ru["barrier"], "hypotheses": list(start), "conclusion": target,
                "class": ru["class"],
                "consequence": {k: ru["consequence"][k] for k in ("index", "kind", "target", "class")},
                "up": {s: ru["ups"][s] for s in start}, "down": list(reversed(ru["downs"][target])),
                "strength": b["strength"], "conditionalOn": list(b.get("conditionalOn", [])),
                "inheritedCircumventedBy": list(b.get("circumventedBy", []))}

    def derived_barriers(self) -> list:
        """Every single-hypothesis derived barrier (for counts and checks)."""
        out = []
        for ru in self.barrier_rules():
            for a2 in ru["ups"]:
                for b2 in ru["downs"]:
                    if (a2, b2) == (ru["x"], ru["y"]) or a2 == b2:
                        continue
                    out.append(self._derived_record(ru, [a2], b2))
        return out

    def _through(self, start, target: str, rid: str) -> bool:
        """Is `target` derivable from `start` through reduction `rid`?"""
        r = self.m.reductions.get(rid)
        if r is None:
            return False
        cl = self.closure(start)
        if not all(h in cl.facts for h in r["hypotheses"]):
            return False
        return target in self.closure(list(start) + [r["conclusion"]]).facts

    def derived_for(self, start, target: str) -> list:
        """R12 for a query: every derived barrier whose side chains reach every
        start and the target, with circumventions that actually apply and
        redundancy marked."""
        prim = DERIVED_BARRIER_NODE_TYPE
        S = sorted(set(start))
        if target in S or self.m.type(target) != prim or any(self.m.type(s) != prim for s in S):
            return []
        res = [self._derived_record(ru, S, target) for ru in self.barrier_rules()
               if all(s in ru["ups"] for s in S) and target in ru["downs"]
               and not (S == [ru["x"]] and target == ru["y"])]
        for d in res:
            d["circumventedBy"] = [r for r in d["inheritedCircumventedBy"] if self._through(S, target, r)]
            d["circumventsOriginalOnly"] = [r for r in d["inheritedCircumventedBy"] if r not in d["circumventedBy"]]
        self._mark_redundant(S, target, res)
        return res

    def _mark_redundant(self, start, target, recs: list):
        """A derived barrier is redundant when a recorded barrier, or a derived
        one already kept, on the same pair rules out at least as much: a class
        it implies*, a strength no weaker, a consequence no weaker."""
        doms = []
        for bid in self.recorded_barriers(start, target):
            b = self.m.barriers[bid]
            if b.get("status") == "stub":
                continue
            for r in self.consequence_rules(b):
                if r["effect"] == "rules-out":
                    doms.append((bid, r["class"], STRENGTH_RANK.get(b["strength"], 1), EFFECT_RANK.get(r["kind"], 1)))
        recs.sort(key=lambda d: (-CLASS_RANK.get(d["class"], 9), STRENGTH_RANK.get(d["strength"], 1),
                                 EFFECT_RANK.get(d["consequence"]["kind"], 1),
                                 sum(len(p) for p in d["up"].values()) + len(d["down"]),
                                 d["barrier"], d["consequence"]["index"]))
        for d in recs:
            mine = (d["class"], STRENGTH_RANK.get(d["strength"], 1), EFFECT_RANK.get(d["consequence"]["kind"], 1))
            d["redundantWith"] = sorted({o[0] for o in doms if self.m.implies(mine[0], o[1])
                                         and o[2] <= mine[1] and o[3] <= mine[2]})
            if not d["redundantWith"]:
                doms.append(("derived:" + d["barrier"],) + mine)

    @staticmethod
    def derived_view(d: dict) -> dict:
        return {"barrier": d["barrier"], "hypotheses": d["hypotheses"], "class": d["class"],
                "consequence": {"kind": d["consequence"]["kind"], "target": d["consequence"]["target"]},
                "strength": d["strength"],
                "up": {s: [e for e, _ in p] for s, p in d["up"].items()},
                "down": [e for e, _ in d["down"]],
                "circumventedBy": d.get("circumventedBy", []),
                "circumventsOriginalOnly": d.get("circumventsOriginalOnly", []),
                "redundantWith": d.get("redundantWith", [])}

    # -- queries (R8-R10, R13) -------------------------------------------------

    def _tags(self, f: Fact) -> dict:
        return {"depth": f.depth, "models": sorted(f.models), "chainClass": f.chain,
                "assumes": sorted(q.notion for q in f.assumes),
                "weakened": f.weak.notion if f.weak else None}

    def query(self, start, target: str, include_idealised: bool = False) -> dict:
        m = self.m
        start = sorted(set(start))
        for oid in start + [target]:
            if oid not in m.objects:
                return {"supported": False, "reason": f"unknown object {oid}"}
            if m.type(oid) in EXCLUDED_TYPES:
                return {"supported": False, "reason":
                        f"{oid} is a complexity class; classes are related by containment, not derived"}
        cl = self.closure(start, include_idealised)
        f = cl.get(target)
        ans = {"supported": True, "start": start, "target": target, "includeIdealised": include_idealised}
        vac = [{"object": s, **{k: self.cur.refuted[s][k] for k in ("source", "text", "evidence")}}
               for s in start if s in self.cur.refuted]
        if vac:  # R14: an implication from a refuted assumption is vacuous
            ans["vacuous"] = vac
        settings = [s for s in start if s in self.cur.settings]
        if settings:
            ans["settingStart"] = settings
        model_starts = [s for s in start if m.model_of_node(s)]
        if model_starts and not include_idealised:
            ans["modelStart"] = model_starts
        ans["recordedBarriers"] = [self.barrier_view(b) for b in self.recorded_barriers(start, target)]
        ans["reverseBarriers"] = ([self.barrier_view(b) for b in self.recorded_barriers([target], start[0])]
                                  if len(start) == 1 else [])
        derived = self.derived_for(start, target)
        ans["derivedBarriers"] = [self.derived_view(d) for d in derived]
        ans["derivedReverseBarriers"] = ([self.derived_view(d) for d in self.derived_for([target], start[0])]
                                         if len(start) == 1 else [])
        if f is not None:
            edges = self.tree_edges(cl, target)
            ans.update({
                "derivable": True, "depth": f.depth, "models": sorted(f.models),
                "scoped": f.scoped, "chainClass": f.chain,
                "assumes": [{"edge": q.edge, "hypothesis": q.hypothesis, "notion": q.notion}
                            for q in sorted(f.assumes, key=lambda q: (q.edge, q.reverse, q.hypothesis))],
                "weakened": {"edge": f.weak.edge, "notion": f.weak.notion} if f.weak else None,
                "caveats": sorted("|".join(c) for c in f.caveats),
                "edges": edges, "reductionCount": len(edges),
                "reverseSteps": sorted(e for e, rev in self.tree_steps(cl, target) if rev),
                "given": f.step is None,
            })
            ans["recordedOnPair"] = self.recorded_on_pair(start, target, include_idealised, set(edges), True)
            if f.step is not None:
                st = self.strongest(start, target, include_idealised, f)
                if st is not None and st[0] != f.chain:
                    ans["strongest"] = {"chainClass": st[0], "depth": st[1], "edges": st[2]}
                # R8: a barrier on the pair against a class that ANY clean,
                # standard-model derivation has would make the record
                # inconsistent. Never expected; the corpus test asserts it.
                conflicts, majors = [], []
                for bv in ans["recordedBarriers"]:
                    if bv["qualifier"] == "stub":
                        continue
                    for r in bv["consequences"]:
                        if r["effect"] not in ("rules-out", "major-result"):
                            continue
                        c = self.chain_exists(start, target, r["class"])
                        if c:
                            (conflicts if r["effect"] == "rules-out" else majors).append(
                                {"barrier": bv["id"], "consequence": r["index"], "chainClass": c})
                for d in derived:
                    c = self.chain_exists(start, target, d["class"])
                    if c:
                        conflicts.append({"barrier": "derived:" + d["barrier"], "consequence": d["consequence"]["index"],
                                          "chainClass": c})
                ans["conflictingBarriers"] = conflicts
                ans["majorResultBarriers"] = majors
                outside = sorted(f.models) + (["assumption"] if f.assumes else []) + (["weakened"] if f.weak else [])
                # The note says the barriers concern standard-model reductions,
                # so a barrier proved in another model (ask 3), whose own row
                # names its model, does not call for it. A stub's model is not
                # evidence, and every derived barrier is standard-model.
                beside = any(bv["qualifier"] == "stub"
                             or self.m.barrier_model(bv["id"]) == "standard" for bv in ans["recordedBarriers"])
                if outside and (beside or any(not d["redundantWith"] for d in derived)):
                    ans["barrierScopeNote"] = outside
            return ans
        ans["derivable"] = False
        ans["recordedOnPair"] = self.recorded_on_pair(start, target, include_idealised, set(), False)
        # Would the toggle find it? (R4)
        if not include_idealised:
            alt = self.closure(start, True)
            af = alt.get(target)
            if af is not None:
                stub = any(self.step_index[k].stub for k in self.tree_steps(alt, target))
                ans["withIdealised"] = {"depth": af.depth, "models": sorted(af.models), "usesStub": stub}
        # What R5 and R13 refused on the way (explanation only).
        ans["refusedSteps"] = self.refused_on_path(start, target, include_idealised)
        barrier_on_pair = (any(b["qualifier"] != "stub" for b in ans["recordedBarriers"])
                           or any(not d["redundantWith"] for d in derived))
        ans["nearMisses"] = self.near_misses(start, cl, target, include_idealised, barrier_on_pair)
        comps, total, becomes = self.completions(start, target, cl, include_idealised)
        ans["completions"] = comps
        ans["completionCount"] = total
        ans["questionBecomes"] = becomes
        ans["footer"] = FOOTER
        return ans

    def recorded_on_pair(self, start, target, inc: bool, used: set, derivable: bool) -> list:
        """R10 item 0. Reductions the wiki records on exactly this hyperedge,
        and what CCwiki did with each."""
        S = set(start)
        reason = {rid: why for why, ids in self.excluded.items() for rid in ids}
        out = []
        for rid in sorted(self.m.reductions):
            r = self.m.reductions[rid]
            fwd = set(r["hypotheses"]) == S and r["conclusion"] == target
            rev = (r["kind"] == "equivalence" and len(S) == 1
                   and r["hypotheses"] == [target] and r["conclusion"] in S)
            if not (fwd or rev):
                continue
            row = {"edge": rid, "reverse": not fwd}
            s = self.step_index.get((rid, not fwd))
            # A quarantine of one direction leaves the reduction eligible, so
            # it is not in `excluded`; its row says so all the same.
            held = self.cur.quarantined(rid, not fwd)
            if rid in reason or held is not None:
                row["status"] = reason.get(rid, "quarantined")
                if held is not None:
                    row["detail"] = held["reason"]
            elif s is not None and s.stub and not inc:
                row["status"] = "stub"
            elif s is not None and not s.default and not inc:
                row["status"] = "idealised-model"
            elif rid in used:
                row["status"] = "used"
            else:
                row["status"] = "not-on-shown-derivation" if derivable else "unused"
                if s is not None and s.requires:
                    row["needs"] = [q.notion for q in s.requires]
            out.append(row)
        return out

    def refused_on_path(self, start, target, include_idealised) -> list:
        """Steps R5 or R13 refused on the derivation plain closure would give."""
        rx = self.relaxed()
        rcl = rx.closure(start, include_idealised)
        if target not in rcl.facts:
            return []
        out = []
        for e, rev in rx.tree_steps(rcl, target):
            s = self.step_index[(e, rev)]
            hf = {h: rcl.facts[h] for h in s.hyps}
            reasons = []
            held = self.cur.quarantined(e, rev)
            if held is not None:
                reasons.append({"kind": "quarantined", "reason": held["reason"]})
            for h, f in hf.items():
                w = f.step.weakens if f.step is not None else None
                if w is not None and e not in w.accepted_by:
                    reasons.append({"kind": "weakened", "hypothesis": h, "producedBy": f.step.edge,
                                    "notion": w.notion})
            for q in s.requires:
                f = hf[q.hypothesis]
                if f.step is not None and f.step.edge not in q.met_by:
                    reasons.append({"kind": "requires", "hypothesis": q.hypothesis, "notion": q.notion,
                                    "producedBy": f.step.edge})
            if any(f.scoped for f in hf.values()) and not self.m.implies(s.cls, RELATIVIZING) \
                    and not (s.cls == "unstated" and self.policy == "caveat"):
                reasons.append({"kind": "idealised-composition", "class": s.cls,
                                "scopedHypotheses": sorted(h for h, f in hf.items() if f.scoped)})
            if reasons:
                bars = sorted(set(self.recorded_barriers(list(s.hyps), s.concl))
                              | set(self.recorded_barriers(start, s.concl)))
                out.append({"edge": e, "reverse": rev, "class": s.cls, "reasons": reasons, "barriers": bars})
        return out

    def near_misses(self, start, cl: Closure, target: str, include_idealised: bool, barrier_on_pair: bool) -> dict:
        """R9. Hosts and variants are related by page structure, never by an
        edge, so none of this is a derivation; it is shown as a hint."""
        m = self.m
        o = m.objects[target]
        target_variants = sorted(v for v, vo in m.objects.items()
                                 if vo["kind"] == "variant" and vo.get("of") == target
                                 and v in cl.facts and v not in start)
        host = o.get("of") if o["kind"] == "variant" else None
        # The host hint reads "nearly derivable": never for a host that is the
        # premise itself, and never beside a barrier, since a section is
        # usually the stronger notion.
        target_host = (host if host in cl.facts and host not in start and not barrier_on_pair else None)
        start_variants = []
        for s in start:
            for v, vo in sorted(m.objects.items()):
                if vo["kind"] != "variant" or vo.get("of") != s or v == target:
                    continue
                alt = [x for x in start if x != s] + [v]
                if target in self.closure(alt, include_idealised).facts:
                    start_variants.append(v)
        start_hosts = []
        for s in start:
            so = m.objects[s]
            if so["kind"] == "variant" and so.get("of") in m.objects and so["of"] != target:
                alt = [x for x in start if x != s] + [so["of"]]
                if target in self.closure(alt, include_idealised).facts:
                    start_hosts.append(so["of"])
        return {"targetVariantsDerived": target_variants, "targetHostDerived": target_host,
                "startVariantsDerive": start_variants, "startHostsDerive": start_hosts}

    def completions(self, start, target, cl: Closure, include_idealised: bool):
        """R10. Objects Z with which the recorded reductions reach the target.
        Never a claim that Z is needed: Z may suffice alone. A Z that the
        target itself gives back (with the start) is not offered: adding it
        only restates the target, so it is returned apart as "the question
        becomes start => Z"."""
        m = self.m
        with_target = self.closure(list(start) + [target], include_idealised).facts
        found = {}
        for z in sorted(m.objects):
            if z == target or z in cl.facts or m.type(z) not in COMPLETION_TYPES or m.model_of_node(z):
                continue
            if z in self.cur.refuted or z in self.cur.settings:
                continue
            if self.single(z, include_idealised).get(target) is not None:
                continue  # z alone suffices; that is implied-by, not a completion
            zc = self.closure(list(start) + [z], include_idealised)
            f = zc.facts.get(target)
            if f is None:
                continue
            found[z] = (f, self.tree_edges(zc, target))
        # Keep the weakest: drop z when another candidate z2 follows from z
        # and z does not follow from z2. Restating candidates take part, so a
        # stronger object never stands in for one that was set aside.
        keep = []
        for z in found:
            zf = self.single(z, include_idealised).facts
            dominated = any(z2 != z and z2 in zf and z not in self.single(z2, include_idealised).facts
                            for z2 in found)
            if not dominated:
                keep.append(z)
        keep.sort(key=lambda z: (found[z][0].depth, len(found[z][0].models), len(found[z][0].assumes),
                                 CLASS_RANK[found[z][0].chain], len(found[z][1]), z))
        offered = [z for z in keep if z not in with_target]
        restating = [z for z in keep if z in with_target]
        rows = [{"add": z, **self._tags(found[z][0]), "edges": found[z][1]} for z in offered[:COMPLETION_CAP]]
        becomes = [{"add": z, **self._tags(found[z][0]), "edges": found[z][1]} for z in restating[:COMPLETION_CAP]]
        return rows, len(offered), becomes

    # -- R11: backward closure -----------------------------------------------

    def implied_by(self, target: str, include_idealised: bool = False) -> dict:
        m = self.m
        base = [o for o in sorted(m.objects)
                if m.type(o) not in EXCLUDED_TYPES and not m.model_of_node(o) and o != target]
        objs = [o for o in base if o not in self.cur.refuted and o not in self.cur.settings]
        singles, settings, refuted = [], [], []
        for a in base:
            f = self.single(a, include_idealised).get(target)
            if f is None:
                continue
            row = {"from": a, **self._tags(f)}
            if a in self.cur.refuted:
                refuted.append(a)  # R14: vacuous, never listed
            elif a in self.cur.settings:
                settings.append(row)
            else:
                singles.append(row)
        single_set = {s["from"] for s in singles} | {target}
        conj = [s for s in (self.steps if include_idealised else self.default_steps) if len(s.hyps) > 1]
        cover = {a: set(self.single(a, include_idealised).facts) for a in objs}
        sources = {}  # h -> objects deriving h alone
        for a in objs:
            for h in cover[a]:
                sources.setdefault(h, set()).add(a)
        # A pair derives more than its halves only if some conjunctive step
        # has every hypothesis in the union of their closures and neither
        # closure alone covers it. Those pairs are the candidates; each is
        # then checked with a real closure.
        pairs = set()
        for s in conj:
            hs = set(s.hyps)
            for a in sorted(set().union(*(sources.get(h, set()) for h in hs))):
                if a in single_set:
                    continue
                need = hs - cover[a]
                if not need:
                    continue
                bs = set.intersection(*(sources.get(h, set()) for h in need))
                for b in bs:
                    if b != a and b not in single_set:
                        pairs.add(tuple(sorted((a, b))))
        groups = {}
        for a, b in sorted(pairs):
            cl = self.closure([a, b], include_idealised)
            f = cl.get(target)
            if f is None:
                continue
            g = self._joining_edge(cl, target, cover[a], cover[b])
            groups.setdefault(g, []).append({"pair": [a, b], **self._tags(f)})
        group_rows = []
        for g, ps in sorted(groups.items(), key=lambda t: (-len(t[1]), t[0])):
            group_rows.append({"edge": g, "hypotheses": list(m.reductions[g]["hypotheses"]) if g in m.reductions else [],
                               "pairCount": len(ps),
                               "models": sorted(set().union(*(set(p["models"]) for p in ps))),
                               "assumes": sorted(set().union(*(set(p["assumes"]) for p in ps))),
                               "pairs": ps[:IMPLIED_BY_GROUP_CAP]})
        # Conjunctions of three or more are shown as the edge, not enumerated.
        larger = []
        for s in conj:
            if len(s.hyps) < 3 or s.edge in groups:
                continue
            if any(self.single(h, include_idealised).get(target) is not None for h in s.hyps):
                continue
            f = self.closure(list(s.hyps), include_idealised).get(target)
            if f is not None:
                larger.append({"edge": s.edge, "hypotheses": list(s.hyps), **self._tags(f)})
        singles.sort(key=lambda s: (s["depth"], len(s["models"]), len(s["assumes"]), s["from"]))
        return {"target": target, "includeIdealised": include_idealised,
                "singleCount": len(singles), "singles": singles[:IMPLIED_BY_SINGLE_CAP],
                "settings": settings, "refutedExcluded": refuted,
                "pairCount": sum(len(v) for v in groups.values()), "groups": group_rows,
                "largerConjunctions": larger}

    def _joining_edge(self, cl: Closure, target: str, ca: set, cb: set) -> str:
        """The conjunctive step nearest the root whose hypotheses neither side
        derives alone: where the two halves of the pair meet."""
        queue, seen = [target], set()
        while queue:
            fid = queue.pop(0)
            if fid in seen:
                continue
            seen.add(fid)
            f = cl.get(fid)
            if f is None or f.step is None:
                continue
            hs = set(f.step.hyps)
            if len(hs) > 1 and not hs <= ca and not hs <= cb:
                return f.step.edge
            queue.extend(f.step.hyps)
        return "?"


# ---------------------------------------------------------------------------
# Invariants and sentinels (the corpus test asserts these whatever the commit)
# ---------------------------------------------------------------------------


def invariants(dv: Derivation, all_derived: list) -> dict:
    m = dv.m
    res = {}
    # Step by step: a quarantine of one direction of an equivalence leaves
    # the other direction a step.
    bad = sorted({s.edge for s in dv.steps if m.reductions[s.edge]["kind"] == "inclusion"
                  or m.reductions[s.edge].get("heuristic") or dv.cur.quarantined(s.edge, s.reverse) is not None
                  or any(m.type(x) in EXCLUDED_TYPES
                         for x in m.reductions[s.edge]["hypotheses"] + [m.reductions[s.edge]["conclusion"]])})
    res["noIneligibleEdges"] = not bad
    leaks = []
    starts = sorted(o for o in m.objects if m.type(o) not in EXCLUDED_TYPES)
    for a in starts:
        cl = dv.single(a, False)
        for fid, f in list(cl.facts.items()) + list(cl.weak.items()):
            if f.models - DEFAULT_MODELS or (f.scoped and f.step is not None):
                leaks.append((a, fid))
    res["defaultHasNoIdealisedModels"] = not leaks
    # R8: no derivation of any class contradicts a recorded barrier.
    conflicts, majors = [], []
    for bid in sorted(m.barriers):
        b = m.barriers[bid]
        if b.get("status") == "stub":
            continue
        for r in dv.consequence_rules(b):
            if r["effect"] not in ("rules-out", "major-result"):
                continue
            c = dv.chain_exists(b["hypotheses"], b["conclusion"], r["class"])
            if c:
                (conflicts if r["effect"] == "rules-out" else majors).append((bid, r["index"], c))
    res["noChainContradictsRecordedBarrier"] = not conflicts
    res["noChainProvesBelievedProposition"] = not majors
    # R12: no derivation of any class contradicts a derived barrier.
    dconf = []
    for d in all_derived:
        c = dv.chain_exists(d["hypotheses"], d["conclusion"], d["class"])
        if c:
            dconf.append((d["barrier"], d["hypotheses"][0], d["conclusion"], c))
    res["noChainContradictsDerivedBarrier"] = not dconf
    # ... and no recorded standard-model reduction on its own pair does, even
    # one the engine does not use (a stub's class is not evidence).
    rconf = []
    for d in all_derived:
        for r in m.reductions.values():
            if r["hypotheses"] == d["hypotheses"] and r["conclusion"] == d["conclusion"] \
                    and r["model"] == "standard" and r.get("status") != "stub" \
                    and m.implies(r["class"], d["class"]) and not r.get("heuristic"):
                rconf.append((d["barrier"], r["id"]))
    res["noDerivedBarrierContradictsRecordedReduction"] = not rconf
    res["romDoesNotReachOT"] = all("ot" not in dv.closure(["rom"], inc).facts for inc in (False, True))
    res["romDoesNotReachKE"] = all("ke" not in dv.closure(["rom"], inc).facts for inc in (False, True))
    res["_detail"] = {"ineligible": bad, "leaks": leaks[:10], "conflicts": conflicts[:10], "majors": majors[:10],
                      "derivedConflicts": dconf[:10], "recordedVsDerived": rconf[:10]}
    return res


def sentinels(dv: Derivation) -> dict:
    """Drift checks on the curation (section 2a). The corpus test fails on
    the first two and prints the last two."""
    m = dv.m
    curated = {e for (e, _rev) in dv.cur.requires}
    regime = sorted(s.edge for s in dv.steps
                    if any(w in m.reductions[s.edge].get("securityLoss", "").lower() for w in REGIME_WORDS)
                    and s.edge not in curated)
    gone = superseded(dv)
    return {
        "curationResolves": not dv.cur.unresolved(m),
        "regimeLossCurated": not regime,
        "equivalencesReviewed": not dv.unreviewed,
        "curationSuperseded": not gone,
        "_detail": {"unresolved": dv.cur.unresolved(m), "uncuratedRegime": sorted(set(regime)),
                    "unreviewedEquivalences": dv.unreviewed, "superseded": gone},
    }


def superseded(dv: Derivation) -> list:
    """Curation entries the manifest now records itself (plans/relations-
    followups.md §4.4), by entry id in the curation's order: an equivalence
    whose record states `reverseClass`, a refuted object whose record carries
    `refutedBy`, and a setting that is no longer the sole hypothesis of any
    eligible step. The engine already prefers the record for the first two;
    each is an entry to retire."""
    m = dv.m
    sole = {s.hyps[0] for s in dv.steps if len(s.hyps) == 1}
    out = []
    for e in curation_entries(dv.cur.data):
        if e["key"] == "equivalences":
            r = m.reductions.get(e["edge"])
            if r is not None and r["kind"] == "equivalence" and m.reverse_class(e["edge"]) is not None:
                out.append(e["id"])
        elif e["key"] == "refuted" and m.refuted_by(e["object"]):
            out.append(e["id"])
        elif e["key"] == "settings" and e["object"] not in sole:
            out.append(e["id"])
    return out


def curated_edges(dv: Derivation) -> dict:
    """The golden file's `curatedEdges`: every reduction the curation names
    (each entry's edge, every `metBy` and `acceptedBy` id), as the manifest
    records it, by id. The corpus test's `curationEdgesUnchanged` compares
    the wiki's head against it (§2.4)."""
    ids = set()
    for e in curation_entries(dv.cur.data):
        if "edge" in e:
            ids.add(e["edge"])
        if isinstance(e["raw"], dict):
            ids.update(e["raw"].get("metBy", []))
            ids.update(e["raw"].get("acceptedBy", []))
    out = {}
    for rid in sorted(ids):
        r = dv.m.reductions.get(rid)
        if r is not None:
            out[rid] = {"kind": r["kind"], "hypotheses": list(r["hypotheses"]), "conclusion": r["conclusion"],
                        "class": r.get("class", ""), "model": r.get("model", "")}
    return out


# ---------------------------------------------------------------------------
# Statement lint (section 2a): reads the wiki's pages, not only the manifest
# ---------------------------------------------------------------------------

_WIKILINK = re.compile(r"\[\[([^\]|#]+)(?:#([^\]|]+))?(?:\|[^\]]*)?\]\]")
_MDLINK = re.compile(r"\]\(([^)#\s]+)(?:#([^)\s]+))?\)")


def statement_of(wiki_root: str, page: str) -> str:
    try:
        with open(os.path.join(wiki_root, page), encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return ""
    mm = re.search(r"## Statement\n(.*?)(\n## |\Z)", text, re.S)
    return mm.group(1).strip() if mm else ""


def statement_lint(dv: "Derivation", wiki_root: str) -> list:
    """Assumptions a step's Statement names before its citation that are not
    among the edge's endpoints, nor the host page of one: a possible dropped
    conjunct. Quarantined edges and edges the curation lists under
    `statementLint` as reviewed are skipped."""
    m = dv.m
    index = {}
    for oid, o in m.objects.items():
        index[(o["slug"], o.get("anchor", "").lstrip("#"))] = oid
    reviewed = set(dv.cur.data.get("statementLint", {}))
    hits = []
    for e in sorted({s.edge for s in dv.steps}):
        if e in reviewed:
            continue
        r = m.reductions[e]
        claim = statement_of(wiki_root, r["page"]).split(" \u2014 ")[0]
        linked = set()
        for slug, anchor in _WIKILINK.findall(claim) + _MDLINK.findall(claim):
            oid = index.get((slug, anchor or "")) or index.get((slug, ""))
            if oid and m.type(oid) == "assumption":
                linked.add(oid)
        ends = set(r["hypotheses"]) | {r["conclusion"]}
        hosts = {m.objects[x].get("of") for x in ends if x in m.objects}
        missing = sorted(linked - ends - hosts)
        if missing:
            hits.append({"edge": e, "hypotheses": r["hypotheses"], "unlisted": missing})
    return hits


# ---------------------------------------------------------------------------
# Curation evidence (plans/relations-followups.md §2.2): each entry's
# citations of the wiki, its id, and the one order entries are listed in
# ---------------------------------------------------------------------------

#: The curation's keys in §2.2's order. Entries are listed this way
#: everywhere: the review document, the app (`DerivationCuration.entries`)
#: and the asks.
ENTRY_KEYS = ("refuted", "settings", "quarantine", "equivalences", "requires", "statementLint", "weakens")

_HEADING_LINE = re.compile(r"(#{1,6}) (.*)")
_FENCE_OPEN = re.compile(r" {0,3}(`{3,}|~{3,})")
_FENCE_CLOSE = re.compile(r" {0,3}(`{3,}|~{3,})[ \t]*")
_CLOSING_HASHES = re.compile(r"(?:^|[ \t])#+$")


def _page_lines(text: str) -> list:
    """The page's lines, CRLF and a lone CR read as LF, each in NFC. NFC
    never composes across a line break, so a line at a time is the whole
    text's NFC."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return [unicodedata.normalize("NFC", line) for line in text.split("\n")]


def _headings(lines: list) -> list:
    """(line index, level, text) of each ATX heading: `#` to `######` at the
    start of a line, then a space. The text is trimmed of spaces and tabs and
    of a closing run of `#`s. Lines in the frontmatter (a first line `---` up
    to the next line `---`) and in fenced code blocks are not headings. A
    fence opens on three or more backticks or tildes after at most three
    spaces, and closes on a line holding only at least as many of its own
    character, or at the end of the file."""
    start = 0
    if lines and lines[0].rstrip(" \t") == "---":
        for i in range(1, len(lines)):
            if lines[i].rstrip(" \t") == "---":
                start = i + 1
                break
    out, fence = [], None
    for i in range(start, len(lines)):
        line = lines[i]
        if fence is not None:
            m = _FENCE_CLOSE.fullmatch(line)
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence):
                fence = None
            continue
        m = _FENCE_OPEN.match(line)
        if m:
            fence = m.group(1)
            continue
        m = _HEADING_LINE.fullmatch(line)
        if m:
            text = _CLOSING_HASHES.sub("", m.group(2).strip(" \t")).strip(" \t")
            out.append((i, len(m.group(1)), text))
    return out


def _collapse(text: str, line_of=None):
    """`text` with every run of space, tab and LF as one space. With
    `line_of`, the line of each character of `text`, also the line each
    character of the result came from (a run: where it starts)."""
    out, lines, run = [], [], False
    for i, ch in enumerate(text):
        if ch in " \t\n":
            if not run:
                out.append(" ")
                lines.append(line_of[i] if line_of else 0)
            run = True
        else:
            out.append(ch)
            lines.append(line_of[i] if line_of else 0)
            run = False
    return "".join(out), lines


def locate_quote(text: str, quote: str, section) -> int | None:
    """§2.2's matching rule. Swift's `CurationQuote.contains` follows it too,
    and both are held to Tests/CCwikiTests/Fixtures/quote-cases.json.

    Line breaks become LF and both texts NFC; every run of `[ \\t\\n]`
    becomes one space in both; then `quote` must be a case-sensitive
    substring of the section, compared code point by code point (never by
    grapheme). The section is the body under the first heading (`_headings`)
    whose text equals `section`, up to the next heading of the same or a
    higher level; `section` None is the whole file, frontmatter included. A
    quote that collapses to nothing or to one space is never found.

    Returns the 1-based line where the first match starts, counting lines
    after line breaks became LF (so a lone CR starts a line), or None."""
    lines = _page_lines(text)
    first, end = 0, len(lines)
    if section is not None:
        want = unicodedata.normalize("NFC", section)
        heads = _headings(lines)
        found = next((n for n, h in enumerate(heads) if h[2] == want), None)
        if found is None:
            return None
        index, level, _ = heads[found]
        first = index + 1
        end = next((h[0] for h in heads[found + 1:] if h[1] <= level), len(lines))
    line_of = []
    for i in range(first, end):
        line_of.extend([i] * (len(lines[i]) + 1))
    haystack, line_at = _collapse("\n".join(lines[first:end]), line_of)
    needle, _ = _collapse("\n".join(_page_lines(quote)))
    if needle in ("", " "):
        return None
    at = haystack.find(needle)
    return None if at < 0 else line_at[at] + 1


def curation_entries(data: dict) -> list:
    """Every entry of the curation file, in §2.2's order, as a dict: `id`
    (computed, never stored, such as `requires:red-dlog-to-prg-bm84:dlog`),
    `key` (the file's key it is under), `object` or `edge`, `reverse` and
    `hypothesis` for a requirement, `raw` (the file's value), `prose` (its
    evidence, reason or note) and `cites`.

    `refuted`, `settings`, `requires` and `weakens` keep file order;
    `quarantine`, `equivalences` and `statementLint` are sorted by edge id
    with `sorted`, which is UTF-8 byte order, as `Derivation.precedes` is. A
    key given twice keeps its first place and its last content, as a dict
    does."""
    entries, at = [], {}

    def add(key, eid, raw, prose, **fields):
        cites = list(raw.get("cites", [])) if isinstance(raw, dict) else []
        entry = {"id": eid, "key": key, "raw": raw, "prose": prose, "cites": cites, **fields}
        if eid in at:
            entries[at[eid]] = entry
        else:
            at[eid] = len(entries)
            entries.append(entry)

    for e in data.get("refuted", []):
        add("refuted", f"refuted:{e['object']}", e, e.get("evidence", ""), object=e["object"])
    for e in data.get("settings", []):
        add("settings", f"settings:{e['object']}", e, e.get("evidence", ""), object=e["object"])
    for e in sorted(data.get("quarantine", []), key=lambda e: e["edge"]):
        add("quarantine", f"quarantine:{e['edge']}", e, e.get("reason", ""), edge=e["edge"])
    for edge, e in sorted(data.get("equivalences", {}).items()):
        add("equivalences", f"equivalences:{edge}", e, e.get("note", ""), edge=edge)
    for e in data.get("requires", []):
        rev = e.get("direction", "forward") == "reverse"
        add("requires", f"requires:{e['edge']}{'~reverse' if rev else ''}:{e['hypothesis']}", e,
            e.get("evidence", ""), edge=e["edge"], reverse=rev, hypothesis=e["hypothesis"])
    for edge, e in sorted(data.get("statementLint", {}).items()):
        add("statementLint", f"statementLint:{edge}", e, e if isinstance(e, str) else e.get("note", ""),
            edge=edge)
    for e in data.get("weakens", []):
        add("weakens", f"weakens:{e['edge']}", e, e.get("evidence", ""), edge=e["edge"])
    return entries


def without_entry(data: dict, entry: dict) -> dict:
    """A copy of the curation file without one entry, every copy of its key
    included."""
    d = copy.deepcopy(data)
    key = entry["key"]
    if key in ("equivalences", "statementLint"):
        d.get(key, {}).pop(entry["edge"], None)
    else:
        d[key] = [e for e in d.get(key, []) if curation_entries({key: [e]})[0]["id"] != entry["id"]]
    return d


def check_quotes(cur: Curation, wiki_root: str) -> list:
    """Every citation of every entry, located: {"entry", "cite", "line"},
    with `line` None when the quote is not on its page or the page cannot
    be read."""
    out, pages = [], {}
    for entry in curation_entries(cur.data):
        for c in entry["cites"]:
            page = c["page"]
            if page not in pages:
                try:
                    with open(os.path.join(wiki_root, page), encoding="utf-8", newline="") as f:
                        pages[page] = f.read()
                except (OSError, UnicodeDecodeError):
                    pages[page] = None
            text = pages[page]
            line = None if text is None else locate_quote(text, c["quote"], c.get("section"))
            out.append({"entry": entry["id"], "cite": c, "line": line})
    return out


# ---------------------------------------------------------------------------
# Synthetic patches: the review's counterexamples, replayable by the Swift test
# ---------------------------------------------------------------------------


def _obj(oid, typ="primitive"):
    return {"id": oid, "kind": "object", "type": typ, "page": "", "slug": oid, "graphSlug": "",
            "title": oid, "aliases": [], "unlisted": False}


def _red(rid, hyps, concl, cls, model="standard"):
    return {"id": rid, "kind": "implication", "hypotheses": hyps, "conclusion": concl, "class": cls,
            "model": model, "source": ["folklore"], "via": [], "heuristic": False, "securityLoss": "",
            "status": "draft", "page": "", "slug": rid, "graphSlug": "", "title": rid}


def _bar(bid, hyps, concl, cls):
    return {"id": bid, "hypotheses": hyps, "conclusion": concl, "class": cls,
            "consequences": [{"kind": "contradiction", "target": "", "class": cls}],
            "strength": "unconditional", "conditionalOn": [], "circumventedBy": [], "source": ["folklore"],
            "status": "draft", "page": "", "slug": bid, "graphSlug": "", "title": bid}


#: (id, patch, query start, target, toggle). A patch adds records, then sets
#: fields on existing barriers and reductions and appends consequences to
#: barriers. The last three try the upstream fields of
#: plans/relations-followups.md §4.4 before the wiki ships them.
MUTATIONS = [
    ("strongest-chain-conflict",
     {"objects": [_obj("syn-x", "assumption")],
      "reductions": [_red("red-syn-pke-to-x", ["pke"], "syn-x", "fully-black-box"),
                     _red("red-syn-x-to-tdp", ["syn-x"], "tdp", "fully-black-box"),
                     _red("red-syn-pke-to-tdp", ["pke"], "tdp", "unstated")]},
     ["pke"], "tdp", False),
    ("derived-barrier-conflict",
     {"objects": [_obj("syn-y")],
      "reductions": [_red("red-syn-owf-to-y", ["owf"], "syn-y", "fully-black-box"),
                     _red("red-syn-y-to-ot", ["syn-y"], "ot", "fully-black-box")]},
     ["owf"], "ot", False),
    ("quantum-chain-is-context",
     {"reductions": [_red("red-syn-owf-to-pke-quantum", ["owf"], "pke", "fully-black-box", "quantum")]},
     ["owf"], "pke", False),
    ("rom-chain-is-context",
     {"reductions": [_red("red-syn-owf-to-pke-rom", ["owf"], "pke", "fully-black-box", "rom")]},
     ["owf"], "pke", True),
    ("believed-true-consequence-not-propagated",
     {"barrierPatches": [{"id": "bar-owp-to-ke-ir89", "appendConsequences": [
         {"kind": "complexity", "target": "p-neq-np", "class": "fully-black-box"}]}]},
     ["owf"], "ke", False),
    ("free-barrier-meets-unstated-chain",
     {"objects": [_obj("syn-a"), _obj("syn-b")],
      "reductions": [_red("red-syn-a-to-b", ["syn-a"], "syn-b", "unstated")],
      "barriers": [_bar("bar-syn-a-to-b", ["syn-a"], "syn-b", "free")]},
     ["syn-a"], "syn-b", False),
    ("stub-barrier-not-propagated",
     {"barrierPatches": [{"id": "bar-owp-to-ke-ir89", "set": {"status": "stub"}}]},
     ["owf"], "ke", False),
    # Ask 3: Sim98 proved in the random oracle model no longer composes with
    # standard-model side reductions.
    ("barrier-model-not-propagated",
     {"barrierPatches": [{"id": "bar-owp-to-crhf-sim98", "set": {"model": "rom"}}]},
     ["owf"], "crhf", False),
    # Ask 1: the record's own reverse class wins over the curation's table,
    # which says the reverse direction of Cre87 takes the record's class.
    ("reverse-class-field",
     {"reductionPatches": [{"id": "red-rabin-ot-to-ot", "set": {"reverseClass": "unstated"}}]},
     ["ot"], "rabin-ot", False),
    # Ask 2: an object the record marks refuted is vacuous, with no entry.
    ("refuted-by-field",
     {"objects": [dict(_obj("syn-r", "assumption"), refutedBy=["[[X - Y|X]]"])],
      "reductions": [_red("red-syn-r-to-pke", ["syn-r"], "pke", "fully-black-box")]},
     ["syn-r"], "pke", False),
]


def apply_patch(data: dict, patch: dict) -> dict:
    d = copy.deepcopy(data)
    d["objects"] = sorted(d["objects"] + patch.get("objects", []), key=lambda o: o["id"])
    d["reductions"] = sorted(d["reductions"] + patch.get("reductions", []), key=lambda r: r["id"])
    d["barriers"] = sorted(d["barriers"] + patch.get("barriers", []), key=lambda b: b["id"])
    for bp in patch.get("barrierPatches", []):
        b = next(b for b in d["barriers"] if b["id"] == bp["id"])
        b.update(bp.get("set", {}))
        b["consequences"] = b["consequences"] + bp.get("appendConsequences", [])
    for rp in patch.get("reductionPatches", []):
        next(r for r in d["reductions"] if r["id"] == rp["id"]).update(rp.get("set", {}))
    return d


def run_mutation(m: Manifest, cur: Curation, mut):
    mid, patch, start, target, inc = mut
    pm = Manifest(apply_patch(m.data, patch), "")
    dv = Derivation(pm, cur)
    ad = dv.derived_barriers()
    return dv, ad, dv.query(start, target, inc), invariants(dv, ad)


# ---------------------------------------------------------------------------
# Golden file
# ---------------------------------------------------------------------------

#: (id, start, target, includeIdealised, fields asserted even when the
#: manifest differs from the golden one). Chosen to pin every rule.
GOLDEN_QUERIES = [
    # R6, R7: the worked examples.
    ("ddh-ot", ["ddh"], "ot", False, ["derivable"]),
    ("ddh-mpc", ["ddh"], "mpc", False, ["derivable"]),
    ("owf-kem-pke", ["owf", "kem"], "pke", False, ["derivable"]),
    ("owf-io-pke", ["owf", "io"], "pke", False, ["derivable"]),
    ("gapsvp-pke", ["gapsvp"], "pke", False, ["derivable"]),
    ("oihf-mpc", ["oblivious-interactive-hash-function"], "mpc", False, []),
    ("ddh-invertible-prf", ["ddh"], "invertible-prf", False, ["derivable"]),
    # R1: equivalences, each direction with its own class; a heuristic edge never fires.
    ("rabin-ot-mpc", ["rabin-ot"], "mpc", False, []),
    ("ot-rabin-ot", ["ot"], "rabin-ot", False, ["derivable"]),
    ("ntru-pke", ["ntru"], "pke", False, []),
    ("isis-crhf", ["inhomogeneous-sis"], "crhf", False, []),
    ("sis-isis", ["sis"], "inhomogeneous-sis", False, ["derivable"]),
    # R2: complexity classes are not derived.
    ("dlog-bqp", ["dlog"], "bqp", False, ["supported"]),
    ("owf-ip-czk", ["owf", "ip"], "czk", False, ["supported"]),
    # R3: the stub only with the toggle, model unknown.
    ("stub-default", ["lpn-high-noise"], "sk-depir", False, []),
    ("stub-all", ["lpn-high-noise"], "sk-depir", True, []),
    # R4: the default filter.
    ("fac-rsa", ["fac"], "rsa", False, []),
    ("fac-rsa-all", ["fac"], "rsa", True, []),
    ("dlog-cdh", ["dlog"], "cdh", False, []),
    ("dlog-cdh-all", ["dlog"], "cdh", True, []),
    ("cdh-dlog", ["cdh"], "dlog", False, ["derivable"]),
    ("rom-ot", ["rom"], "ot", False, ["derivable"]),
    # R5: composition after an idealised step.
    ("rom-oihf-all", ["rom"], "oblivious-interactive-hash-function", True, []),
    ("rom-ot-all", ["rom"], "ot", True, ["derivable"]),
    ("rom-mpc-all", ["rom"], "mpc", True, ["derivable"]),
    ("rom-ke-all", ["rom"], "ke", True, ["derivable"]),
    ("fac-pke", ["fac"], "pke", False, []),
    ("fac-pke-all", ["fac"], "pke", True, []),
    ("ggm-pke-all", ["ggm"], "pke", True, []),
    ("ggm-ot-all", ["ggm"], "ot", True, []),
    # R8, R12: barriers, recorded and derived.
    ("owf-pke", ["owf"], "pke", False, ["derivable"]),
    ("owf-prg-pke", ["owf", "prg"], "pke", False, ["derivable"]),
    ("pke-ot", ["pke"], "ot", False, ["derivable"]),
    ("oihf-ot", ["oblivious-interactive-hash-function"], "ot", False, []),
    ("oihf-rabin-ot", ["oblivious-interactive-hash-function"], "rabin-ot", False, []),
    ("oihf-etdp", ["oblivious-interactive-hash-function"], "enhanced-trapdoor-permutation", False, ["derivable"]),
    ("owf-ot", ["owf"], "ot", False, ["derivable"]),
    ("owf-crhf", ["owf"], "crhf", False, ["derivable"]),
    ("com-pke", ["com"], "pke", False, ["derivable"]),
    ("com-tdp", ["com"], "tdp", False, ["derivable"]),
    ("ot-tdp", ["ot"], "tdp", False, ["derivable"]),
    ("zkp-argument", ["zkp"], "constant-round-zk-argument", False, []),
    ("cpa-cca1", ["pke-cpa-security"], "pke-cca1-security", False, []),
    ("agm-ggm-all", ["agm"], "ggm", True, []),
    ("tdp-etdp", ["tdp"], "enhanced-trapdoor-permutation", False, ["derivable"]),
    # R9, R10: host and variant hints; completions.
    ("lpn-pke", ["lpn"], "pke", False, []),
    ("lwe-ring-lwe", ["lwe"], "ring-lwe", False, ["derivable"]),
    ("kem-pke", ["kem"], "pke", False, []),
    ("crhf-ds", ["crhf"], "ds", False, []),
    ("ddh-she", ["ddh"], "somewhat-homomorphic-encryption", False, []),
    ("ddh-sparse-lpn-she", ["ddh", "sparse-lpn"], "somewhat-homomorphic-encryption", False, []),
    # R13: preconditions, weakened conclusions, quarantine.
    ("jls21-given", ["sxdh", "lwe", "lpn", "prg-in-nc0"], "io", False, ["derivable"]),
    ("jls21-deniable-encryption", ["sxdh", "lwe", "lpn", "prg-in-nc0"], "deniable-encryption", False, []),
    ("jls21-lsn", ["sxdh", "lwe", "learning-subspace-with-noise", "prg-in-nc0"], "io", False, ["derivable"]),
    ("jls21-gapsvp", ["sxdh", "gapsvp", "lpn", "prg-in-nc0"], "io", False, ["derivable"]),
    ("gapsvp-leveled-fhe", ["gapsvp"], "leveled-fully-homomorphic-encryption", False, ["derivable"]),
    ("lwe-leveled-fhe", ["lwe"], "leveled-fully-homomorphic-encryption", False, ["derivable"]),
    ("lpn-low-noise-ot", ["lpn-low-noise"], "ot", False, ["derivable"]),
    ("fe-io", ["functional-encryption"], "io", False, ["derivable"]),
    ("dcr-fe-deniable", ["dcr", "functional-encryption"], "deniable-encryption", False, []),
    ("tdp-nizk", ["tdp"], "nizk", False, ["derivable"]),
    ("rsa-nizk", ["rsa"], "nizk", False, ["derivable"]),
    ("ddh-prg", ["ddh"], "prg", False, ["derivable"]),
    ("lwe-com", ["lwe"], "com", False, ["derivable"]),
    ("etdp-mpc", ["enhanced-trapdoor-permutation"], "mpc", False, ["derivable"]),
    ("bdh-abe", ["bdh"], "abe", False, []),
    ("bdh-ibe", ["bdh"], "ibe", False, []),
    ("bdh-range-query", ["bdh"], "range-query-encryption", False, ["derivable"]),
    ("evasive-lwe-be", ["evasive-lwe"], "be", False, ["derivable"]),
    ("subexp-lpn-crhf", ["subexponential-lpn"], "crhf", False, ["derivable"]),
    # The PR #9 audit's semantic cases (plans/relations-followups.md §13). A
    # case a wiki ask would change asserts nothing on a drifted manifest.
    ("bdh-be", ["bdh"], "be", False, []),
    ("bdh-pke", ["bdh"], "pke", False, []),
    ("cdh-prg", ["cdh"], "prg", False, []),
    ("ot-mpc", ["ot"], "mpc", False, []),
    ("prp-prf", ["prp"], "prf", False, []),
    ("sprp-prf", ["strong-pseudorandom-permutation"], "prf", False, []),
    ("rsa-fac", ["rsa"], "fac", False, ["derivable"]),
    ("dcr-rsa-all", ["dcr"], "rsa", True, []),
    ("isis-sis", ["inhomogeneous-sis"], "sis", False, []),
    # R14: refuted starts.
    ("circular-evasive-lwe-pke", ["circular-evasive-lwe"], "pke", False, ["derivable"]),
    ("ssddh-ke", ["ssddh"], "ke", False, ["derivable"]),
]


def golden_expect(a: dict) -> dict:
    exp = {"supported": a["supported"]}
    if not a["supported"]:
        return exp
    exp["derivable"] = a["derivable"]
    for k in ("vacuous", "modelStart", "settingStart"):
        if k in a:
            exp[k] = [v["object"] for v in a[k]] if k == "vacuous" else a[k]
    exp["recordedBarriers"] = [{"id": b["id"], "qualifier": b["qualifier"]} for b in a["recordedBarriers"]]
    exp["reverseBarriers"] = [b["id"] for b in a["reverseBarriers"]]
    exp["derivedBarriers"] = a["derivedBarriers"]
    exp["derivedReverseBarriers"] = [d["barrier"] + ":" + d["class"] for d in a["derivedReverseBarriers"]
                                     if not d["redundantWith"]]
    exp["recordedOnPair"] = [{"edge": r["edge"], "reverse": r["reverse"], "status": r["status"]}
                             for r in a["recordedOnPair"]]
    if a["derivable"]:
        for k in ("depth", "models", "scoped", "chainClass", "edges", "reverseSteps", "caveats",
                  "conflictingBarriers", "majorResultBarriers"):
            if k in a:
                exp[k] = a[k]
        exp["assumes"] = [q["edge"] + ":" + q["hypothesis"] for q in a["assumes"]]
        exp["weakened"] = a["weakened"]["edge"] if a["weakened"] else None
        for k in ("strongest", "barrierScopeNote"):
            if k in a:
                exp[k] = a[k]
    else:
        exp["completions"] = [c["add"] for c in a["completions"][:5]]
        exp["completionCount"] = a["completionCount"]
        exp["questionBecomes"] = [c["add"] for c in a["questionBecomes"]]
        exp["refusedSteps"] = [{"edge": r["edge"], "reverse": r["reverse"],
                                "reasons": sorted(x["kind"] for x in r["reasons"])} for r in a["refusedSteps"]]
        exp["nearMisses"] = a["nearMisses"]
        if "withIdealised" in a:
            exp["withIdealised"] = a["withIdealised"]
    return exp


def golden(dv: Derivation, wiki_commit: str) -> dict:
    all_derived = dv.derived_barriers()
    records = []
    for qid, start, target, inc, stable in GOLDEN_QUERIES:
        if target not in dv.m.objects or any(s not in dv.m.objects for s in start):
            continue
        a = dv.query(start, target, inc)
        records.append({"id": qid, "start": start, "target": target,
                        "includeIdealised": inc, "stable": stable, "expect": golden_expect(a)})
    mutations = []
    base_count = len(all_derived)
    for mut in MUTATIONS:
        mdv, mad, a, inv = run_mutation(dv.m, dv.cur, mut)
        mid, patch, start, target, inc = mut
        mutations.append({"id": mid, "patch": patch, "start": start, "target": target, "includeIdealised": inc,
                          "expect": golden_expect(a), "derivedBarrierCount": len(mad),
                          "invariants": {k: v for k, v in inv.items() if not k.startswith("_")},
                          "superseded": superseded(mdv)})
    closures = {}
    for o in ["owf", "ddh", "lwe", "dcr", "fac", "rsa", "gapsvp", "dlog", "rom", "ggm", "pke", "ot",
              "lpn-low-noise", "bdh", "circular-evasive-lwe"]:
        if o in dv.m.objects:
            closures[o] = {"default": len(dv.single(o, False).facts) - 1,
                           "defaultWeak": len(dv.single(o, False).weak),
                           "all": len(dv.single(o, True).facts) - 1}
    ib = {}
    for t in ["pke", "ot", "mpc"]:
        r = dv.implied_by(t, False)
        ib[t] = {"singleCount": r["singleCount"], "pairCount": r["pairCount"],
                 "settings": [s["from"] for s in r["settings"]], "refutedExcluded": r["refutedExcluded"],
                 "singlesWithAssumptions": sorted(s["from"] for s in r["singles"] if s["assumes"]),
                 "groups": {g["edge"]: {"pairCount": g["pairCount"], "models": g["models"], "assumes": g["assumes"]}
                            for g in r["groups"]}}
    inv = invariants(dv, all_derived)
    sen = sentinels(dv)
    return {
        "about": ("Expected answers of CCwiki's derivation engine on one wiki manifest and one curation. "
                  "Written by scripts/derivations_reference.py; spec in plans/derivations.md. "
                  "Exact when manifestSHA256 matches the clone's .reductions/relations.json and "
                  "curationSHA256 matches Resources/derivation-curation.json; otherwise only each "
                  "record's `stable` fields, `invariants`, `sentinels` and `mutations` are asserted, "
                  "and only while every count is within `tolerance` of `counts`. `curatedEdges` is "
                  "every reduction the curation names, as recorded here: a later manifest that "
                  "changes one under its id fails the corpus test."),
        "generator": "scripts/derivations_reference.py",
        "wikiCommit": wiki_commit,
        "manifestSHA256": dv.m.sha256,
        "curationSHA256": dv.cur.sha256,
        "counts": dv.m.counts(),
        "tolerance": 0.10,
        "policy": {
            "defaultModels": sorted(DEFAULT_MODELS),
            "idealisedModels": sorted(IDEALISED_MODELS),
            "modelNodes": MODEL_NODES,
            "composableClasses": list(COMPOSABLE_CLASSES),
            "unstatedAfterIdealised": dv.policy,
            "unmetPrecondition": dv.pre_policy,
            "completionCap": COMPLETION_CAP,
        },
        "eligibleSteps": {"default": len(dv.default_steps), "all": len(dv.steps),
                          "quarantined": len(dv.quarantined)},
        "excluded": {k: len(v) for k, v in sorted(dv.excluded.items())},
        "closureSizes": closures,
        "impliedBy": ib,
        "derivedBarrierCount": base_count,
        "derivedBarrierPairs": len({(d["hypotheses"][0], d["conclusion"]) for d in all_derived}),
        "invariants": {k: v for k, v in inv.items() if not k.startswith("_")},
        "sentinels": {k: v for k, v in sen.items() if not k.startswith("_")},
        "curatedEdges": curated_edges(dv),
        "queries": records,
        "mutations": mutations,
    }


# ---------------------------------------------------------------------------
# The curation review (plans/relations-followups.md §2.3): each entry beside
# the wiki text it rests on and what it does to the answers
# ---------------------------------------------------------------------------

#: How many removed, added or changed pairs an entry's effect names.
REPORT_LIST_CAP = 8

_MD_ESCAPED = "|*_$`[]"


def md_escape(text: str) -> str:
    """The one escaper for generated Markdown outside fences: `\\` first,
    then | * _ $ ` [ and ] each get a backslash. So a notion such as
    "Z_p^*" or a title such as "$k$-Linear" renders as written."""
    text = text.replace("\\", "\\\\")
    for ch in _MD_ESCAPED:
        text = text.replace(ch, "\\" + ch)
    return text


def md_code(text: str) -> str:
    """A code span for an id or a path. Its content is never escaped, so it
    must hold no backtick or pipe; anything else is escaped text instead."""
    if "`" in text or "|" in text or "\n" in text:
        return md_escape(text)
    return f"`{text}`"


def md_fence(text: str, info: str = "markdown") -> str:
    """`text` verbatim in a fenced block one backtick longer than its
    longest backtick run, and at least three, so the wiki's source (`$…$`,
    `**`, `[[a|b]]`) is shown as written, not typeset."""
    longest = max((len(run) for run in re.findall(r"`+", text)), default=0)
    ticks = "`" * max(3, longest + 1)
    return f"{ticks}{info}\n{text}\n{ticks}"


def _content_path(page: str) -> str:
    return page[len("content/"):] if page.startswith("content/") else page


def _blob_url(page: str, commit: str, line) -> str:
    """The page at the commit. With a line, GitHub's source view
    (`?plain=1`), since a line anchor does nothing on a rendered page."""
    url = f"{WIKI_REPOSITORY}/blob/{commit}/{urllib.parse.quote(page, safe='/')}"
    return url + (f"?plain=1#L{line}" if line else "")


def _source_keys(source) -> list:
    """The citation keys of a reduction's `source`: a wikilink's display
    text, else its page name up to " - ", and "folklore" as is."""
    keys = []
    for s in source if isinstance(source, list) else [source]:
        m = re.fullmatch(r"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]", s.strip())
        if m:
            keys.append((m.group(2) or m.group(1).split(" - ")[0]).strip())
        else:
            keys.append(s.strip())
    return keys


def _name(m: Manifest, oid: str) -> str:
    """An object as the report names it: a page object by its first alias
    or its title, a variant as "<host> § <variant title>"."""
    o = m.objects.get(oid)
    if o is None:
        return oid
    own = (o.get("aliases") or [o["title"]])[0]
    if o["kind"] == "variant" and o.get("of") in m.objects:
        return f"{_name(m, o['of'])} § {o['title']}"
    return own


def _step_name(m: Manifest, edge: str, reverse: bool = False) -> str:
    """A reduction as the report names it: its title and its citation keys,
    "DLOG ⇒ PRG (BM84)", with ", used right to left" for the reverse
    direction of an equivalence."""
    r = m.reductions.get(edge)
    if r is None:
        return edge
    name = f"{r['title']} ({', '.join(_source_keys(r.get('source', [])))})"
    return name + (", used right to left" if reverse else "")


def _what_it_changes(m: Manifest, entry: dict) -> str:
    """One sentence per kind, in the words of plans/derivations.md §7."""
    raw, key = entry["raw"], entry["key"]
    if key == "refuted":
        return f"Answers from {_name(m, entry['object'])} are vacuous ({raw.get('source', '')})"
    if key == "settings":
        return f"{_name(m, entry['object'])} is listed apart as a setting, never as an assumption or a completion"
    step = _step_name(m, entry["edge"])
    if key == "quarantine":
        if raw.get("direction") is not None:
            way = "right-to-left" if raw["direction"] == "reverse" else "left-to-right"
            return f"The {way} direction of {step} is never used"
        return f"{step} is never used"
    if key == "equivalences":
        fwd, rev = raw.get("forward") == "record", raw.get("reverse") == "record"
        if fwd and rev:
            return f"Both directions of {step} take the record's class"
        if fwd or rev:
            kept = "left-to-right" if fwd else "right-to-left"
            return f"Only the {kept} direction of {step} takes the record's class; the other is unstated"
        return f"Neither direction of {step} takes the record's class"
    if key == "requires":
        step = _step_name(m, entry["edge"], entry["reverse"])
        met = raw.get("metBy", [])
        tail = f", given or from {', '.join(_step_name(m, e) for e in met)}" if met else ", which must be given"
        return f"{step} fires only on {raw['notion']}{tail}"
    if key == "statementLint":
        return f"The Statement lint does not flag {step}"
    accepted = raw.get("acceptedBy", [])
    tail = (f"; only {', '.join(_step_name(m, e) for e in accepted)} may use it" if accepted
            else "; no step may use it")
    return f"{step} concludes {raw['notion']}{tail}"


def _description(m: Manifest, entry: dict) -> str:
    """The entry's first paragraph in the review: what it says, with the
    step or object in bold."""
    raw, key = entry["raw"], entry["key"]
    if key == "refuted":
        return (f"Answers from **{md_escape(_name(m, entry['object']))}** are vacuous. "
                f"CCwiki's sentence: {md_escape(raw.get('text', ''))}")
    if key == "settings":
        return (f"**{md_escape(_name(m, entry['object']))}** is a setting, not an assumption: listed apart, and "
                f"never a completion. CCwiki's sentence: {md_escape(raw.get('text', ''))}")
    step = f"**{md_escape(_step_name(m, entry['edge']))}**"
    if key == "quarantine":
        if raw.get("direction") is not None:
            way = "right to left" if raw["direction"] == "reverse" else "left to right"
            return (f"{step} is never used {way}: its Statement does not establish that direction. "
                    f"The other direction is still a step.")
        return f"{step} is never used: its recorded hypotheses do not match its Statement."
    if key == "equivalences":
        cls = m.reductions.get(entry["edge"], {}).get("class", "?")

        def said(direction):
            return "takes the record's class" if raw.get(direction) == "record" else "is unstated"
        return (f"{step}, recorded as {md_escape(cls)}: left to right {said('forward')}, right to left "
                f"{said('reverse')}.")
    if key == "requires":
        step = f"**{md_escape(_step_name(m, entry['edge'], entry['reverse']))}**"
        met = raw.get("metBy", [])
        met_text = (", ".join(md_escape(_step_name(m, e)) for e in met) if met
                    else "nothing; the notion must be given")
        return (f"{step} needs *{md_escape(raw['notion'])}* of its hypothesis "
                f"{md_escape(_name(m, entry['hypothesis']))}. Met by: {met_text}.")
    if key == "statementLint":
        return f"The Statement lint does not flag {step}."
    accepted = raw.get("acceptedBy", [])
    accepted_text = ", ".join(md_escape(_step_name(m, e)) for e in accepted) if accepted else "nothing"
    return f"{step} concludes *{md_escape(raw['notion'])}*. Accepted by: {accepted_text}."


def _single_pairs(dv: Derivation, starts: list, include_idealised: bool) -> dict:
    """(start, target) -> (chain class, models, assumptions, weakened
    notion) for every derived fact of every single-object closure, full or
    weakened (a fact with both is read as its full one)."""
    out = {}
    for a in starts:
        cl = dv.single(a, include_idealised)
        for t in set(cl.facts) | set(cl.weak):
            f = cl.get(t)
            if f.step is None:
                continue
            out[(a, t)] = (f.chain, tuple(sorted(f.models)), tuple(sorted(q.notion for q in f.assumes)),
                           f.weak.notion if f.weak else None)
    return out


def _backward_lists(dv: Derivation, pairs: dict) -> dict:
    """R11's lists for every target, read off the single-object closures:
    target -> (singles, settings, refuted), each a set of sources."""
    m, out = dv.m, {}
    for (a, t) in pairs:
        if m.model_of_node(a):
            continue
        lists = out.setdefault(t, (set(), set(), set()))
        lists[2 if a in dv.cur.refuted else 1 if a in dv.cur.settings else 0].add(a)
    return out


@dataclass
class ReviewBaseline:
    """What the full curation gives, computed once for every entry's effect."""
    dv: Derivation
    starts: list
    pairs: dict  # include_idealised -> _single_pairs
    backward: dict  # include_idealised -> _backward_lists
    golden: dict  # golden query id -> golden_expect
    wiki_root: str | None  # the clone, for the Statement lint
    lint: list | None  # its hits with the full curation; None without a clone


def review_baseline(dv: Derivation, wiki_root: str | None) -> ReviewBaseline:
    starts = sorted(o for o in dv.m.objects if dv.m.type(o) not in EXCLUDED_TYPES)
    pairs = {inc: _single_pairs(dv, starts, inc) for inc in (False, True)}
    return ReviewBaseline(dv, starts, pairs, {inc: _backward_lists(dv, pairs[inc]) for inc in (False, True)},
                          _golden_expectations(dv), wiki_root,
                          statement_lint(dv, wiki_root) if wiki_root else None)


def _golden_expectations(dv: Derivation) -> dict:
    out = {}
    for qid, start, target, inc, _stable in GOLDEN_QUERIES:
        if target in dv.m.objects and all(s in dv.m.objects for s in start):
            out[qid] = golden_expect(dv.query(start, target, inc))
    return out


def entry_effect(base: ReviewBaseline, entry: dict) -> dict:
    """What one entry does: the engine rebuilt without it, compared with the
    full curation (§2.3). Per model setting (False: default models, True:
    idealised included): `removes` (pairs only the run without the entry
    derives), `adds` (pairs only the full curation derives), `changed`
    (pairs whose chain class, models, assumptions or weakened notion
    differ, with what differs), `vacuous` (single-object answers whose
    vacuity differs) and `backward` (targets whose R11 lists differ). Then
    `golden` (golden query ids whose expectation differs) and `lint` (the
    Statement lint's new hits, with a clone)."""
    dv = base.dv
    data = without_entry(dv.cur.data, entry)
    alt = Derivation(dv.m, Curation(data), dv.policy, dv.pre_policy)
    out = {"golden": [], "lint": [], "none": True}
    for inc in (False, True):
        full, other = base.pairs[inc], _single_pairs(alt, base.starts, inc)
        removes = sorted(set(other) - set(full))
        adds = sorted(set(full) - set(other))
        changed = []
        for p in sorted(set(full) & set(other)):
            if full[p] != other[p]:
                changed.append((p, _what_changed(full[p], other[p])))
        vac_full = {p for p in full if p[0] in dv.cur.refuted}
        vac_other = {p for p in other if p[0] in alt.cur.refuted}
        back_other = _backward_lists(alt, other)
        targets = set(base.backward[inc]) | set(back_other)
        empty = (set(), set(), set())
        backward = sorted(t for t in targets if base.backward[inc].get(t, empty) != back_other.get(t, empty))
        out[inc] = {"removes": removes, "adds": adds, "changed": changed,
                    "vacuous": sorted(vac_full ^ vac_other), "backward": backward}
    alt_golden = _golden_expectations(alt)
    out["golden"] = sorted(q for q in set(base.golden) | set(alt_golden) if base.golden.get(q) != alt_golden.get(q))
    if base.lint is not None and entry["key"] == "statementLint":
        known = {(h["edge"], tuple(h["unlisted"])) for h in base.lint}
        out["lint"] = [h for h in statement_lint(alt, base.wiki_root)
                       if (h["edge"], tuple(h["unlisted"])) not in known]
    out["none"] = not (out["golden"] or out["lint"]
                       or any(out[inc][k] for inc in (False, True) for k in ("removes", "adds", "changed",
                                                                               "vacuous", "backward")))
    return out


def _what_changed(full: tuple, other: tuple) -> str:
    """How a pair differs without the entry: its chain class, models,
    assumptions or weakened notion."""
    parts = []
    if full[0] != other[0]:
        parts.append(f"class {full[0]} → {other[0]}")
    if full[1] != other[1]:
        parts.append(f"models {', '.join(full[1]) or 'standard'} → {', '.join(other[1]) or 'standard'}")
    if full[2] != other[2]:
        a, b = set(full[2]), set(other[2])
        parts.append("assumption dropped" if b < a else "assumption added" if a < b else "assumptions differ")
    if full[3] != other[3]:
        parts.append("no longer weakened" if other[3] is None else "weakened" if full[3] is None
                     else "weakened differently")
    return ", ".join(parts)


def _plural(n: int, one: str, many: str | None = None) -> str:
    return f"{n} {one if n == 1 else (many or one + 's')}"


def _listed(items: list) -> str:
    """The first few of a list, joined; a longer list ends in an ellipsis."""
    return ", ".join(items[:REPORT_LIST_CAP]) + (", …" if len(items) > REPORT_LIST_CAP else "")


def _sentence(text: str) -> str:
    """`text` with a full stop, unless it ends in an ellipsis."""
    return text if text.endswith("…") else text + "."


def _counts(e: dict) -> list:
    parts = []
    for key, word in (("removes", "removes"), ("adds", "adds"), ("changed", "changes")):
        if e[key]:
            parts.append(f"{word} {len(e[key])}")
    if e["vacuous"]:
        parts.append(f"{len(e['vacuous'])} vacuous")
    if e["backward"]:
        parts.append(f"backward lists {len(e['backward'])}")
    return parts


def _why_no_effect(dv: Derivation, entry: dict):
    """Why an entry shows no effect, when the measure itself explains it, as
    (short, long), or None: its object derives nothing alone, or its step has
    several hypotheses, which no single start gives it together."""
    if entry["key"] in ("refuted", "settings"):
        derives = any(f.step is not None for inc in (False, True)
                      for f in dv.single(entry["object"], inc).facts.values())
        if derives:
            return None
        reason = f"nothing follows from {_name(dv.m, entry['object'])} alone"
        return reason, reason
    r = dv.m.reductions.get(entry.get("edge", ""))
    if r is None or len(r["hypotheses"]) < 2:
        return None
    n = len(r["hypotheses"])
    return (f"its step has {n} hypotheses, which no single start gives",
            f"the step has {n} hypotheses, so the entry acts only in questions with several starts, which this "
            "measure samples only through the golden queries")


def _effect_cell(dv: Derivation, entry: dict, x: dict) -> str:
    """The Summary's effect column: default models (or, failing those,
    idealised ones), the golden queries and the Statement lint."""
    if x["none"]:
        why = _why_no_effect(dv, entry)
        return md_escape("no effect" + (f": {why[0]}" if why else ""))
    parts = []
    default, idealised = _counts(x[False]), _counts(x[True])
    if default:
        parts.append(md_escape(", ".join(default)))
    elif idealised:
        parts.append(md_escape("with idealised models only: " + ", ".join(idealised)))
    if x["golden"]:
        parts.append("golden " + ", ".join(md_code(q) for q in x["golden"]))
    if x["lint"]:
        parts.append(md_escape(f"the Statement lint flags {_plural(len(x['lint']), 'edge')} without it"))
    return "; ".join(parts)


def _effect_paragraph(dv: Derivation, entry: dict, x: dict) -> str:
    m = dv.m
    if x["none"]:
        why = _why_no_effect(dv, entry)
        return ("**Effect.** None: without this entry no single-object answer, vacuous answer, backward list or "
                "golden query changes." + (f" {md_escape(why[1][0].upper() + why[1][1:])}." if why else ""))
    d, i = x[False], x[True]
    out = []
    if any(e[k] for e in (d, i) for k in ("removes", "adds", "changed")):
        def more(e):
            return (f"{len(e['removes'])} more" if e["removes"] else "no more") + (
                f", {len(e['adds'])} fewer" if e["adds"] else "")
        noun = "pair" if len(d["removes"]) + len(d["adds"]) == 1 else "pairs"
        out.append(f"Without this entry the engine derives {more(d)} {noun} and changes {len(d['changed'])} "
                   f"(default models), and {more(i)} and {len(i['changed'])} changed with idealised models.")

    def pairs_sentence(label, key, describe):
        e, where = (d, "") if d[key] else (i, ", with idealised models")
        if not e[key]:
            return
        lead = (f"{label}{where} ({len(e[key])}), first {REPORT_LIST_CAP}: " if len(e[key]) > REPORT_LIST_CAP
                else f"{label}{where}: ")
        out.append(_sentence(lead + _listed([md_escape(describe(p)) for p in e[key]])))

    pairs_sentence("Removed", "removes", lambda p: f"{_name(m, p[0])} ⇒* {_name(m, p[1])}")
    pairs_sentence("Added", "adds", lambda p: f"{_name(m, p[0])} ⇒* {_name(m, p[1])}")
    pairs_sentence("Changed", "changed", lambda c: f"{_name(m, c[0][0])} ⇒* {_name(m, c[0][1])} ({c[1]})")
    if d["vacuous"] or i["vacuous"]:
        out.append(f"Vacuous answers that change: {len(d['vacuous'])} (default models), {len(i['vacuous'])} with "
                   "idealised models.")
    if d["backward"] or i["backward"]:
        targets = [md_escape(_name(m, t)) for t in (d["backward"] or i["backward"])]
        out.append(_sentence(f"Backward lists that change: {len(d['backward'])} (default models), "
                             f"{len(i['backward'])} with idealised models: {_listed(targets)}"))
    if x["golden"]:
        out.append("Golden queries that change: " + ", ".join(md_code(q) for q in x["golden"]) + ".")
    for h in x["lint"]:
        out.append(md_escape(f"Without it the Statement lint flags {_step_name(m, h['edge'])}: its Statement "
                             f"names {', '.join(_name(m, o) for o in h['unlisted'])}, which its hypotheses "
                             "do not list."))
    return "**Effect.** " + " ".join(out)


def _locations(found: list) -> list:
    """Each citation of an entry with the line its quote starts on: the
    Summary's "Wiki text" cell, one code span per distinct place."""
    cells, seen, last = [], set(), None
    for c, line in found:
        path = _content_path(c["page"])
        if line is None:
            cells.append(f"{md_code(path)} not found")
            last = None
            continue
        if (path, line) in seen:
            continue
        seen.add((path, line))
        cells.append(md_code(f":{line}" if path == last else f"{path}:{line}"))
        last = path
    return cells


def _citation_lines(c: dict, line, wiki_commit: str) -> list:
    """One citation in the review: where it is, linked to the line at the
    commit, then the quote in a fence."""
    page, section = c["page"], c.get("section")
    where = f"§ {md_escape(section)}" if section is not None else "anywhere on the page"
    if line is None:
        head = f"{md_code(page)}, {where}: **Not found on the page at {wiki_commit[:7]}**"
    else:
        head = f"[{md_code(f'{page}:{line}')}]({_blob_url(page, wiki_commit, line)}), {where}"
    return [head, "", md_fence(c["quote"])]


def curation_report(dv: Derivation, wiki_root: str, wiki_commit: str) -> str:
    """plans/curation-review.md (relations-followups.md §2.3): every entry
    beside the wiki text it rests on and what it does to the answers. Writes
    only repository-relative paths and GitHub URLs, never `wiki_root`."""
    m, cur = dv.m, dv.cur
    entries = curation_entries(cur.data)
    located = {}
    for r in check_quotes(cur, wiki_root):
        located.setdefault(r["entry"], []).append((r["cite"], r["line"]))
    quotes = sum(len(v) for v in located.values())
    missing = sum(1 for v in located.values() for _, line in v if line is None)
    short = wiki_commit[:7]
    counts = ", ".join(f"{sum(1 for e in entries if e['key'] == k)} {k}" for k in ENTRY_KEYS)

    base = review_baseline(dv, wiki_root)
    effects = {}
    for e in entries:
        effects[e["id"]] = entry_effect(base, e)
        print(f"  {e['id']}", file=sys.stderr)

    lines = [
        f"<!-- curation-review: curation={cur.sha256} manifest={m.sha256} wiki={wiki_commit} "
        f"entries={len(entries)} quotesMissing={missing} -->",
        "# Curation review",
        "",
        "Generated by `scripts/derivations_reference.py --curation-report`; regenerate with",
        "`make curation-review WIKI=…`. Spec: plans/relations-followups.md §2. Do not edit by hand.",
        "",
        "| | |",
        "|---|---|",
        f"| Curation | `Resources/derivation-curation.json`, SHA-256 `{cur.sha256[:8]}…` |",
        f"| Generated against | wiki `{short}`, relations.json `{m.sha256[:8]}…` (the golden file's) |",
        f"| Entries | {len(entries)}: {counts} |",
        f"| Quotes | {quotes - missing} of {quotes} found |",
        "",
        "Each entry is something `relations.json` does not record and CCwiki reads from the wiki's pages. "
        "Read each one's claim beside the quotes it rests on. The quotes are the page source at the wiki "
        "commit above, in fences, so math, emphasis and wikilinks show as written.",
        "",
        "**Effect** is measured by removing the one entry and rebuilding the engine: over every single-object "
        f"closure ({len(base.starts)} starts), it *removes* the pairs only the run without it derives, *adds* "
        "the pairs only the full curation derives, and *changes* the pairs whose chain class, models, "
        "assumptions or weakened notion differ. Vacuous answers, the backward lists (R11) and the golden "
        "queries are compared too. The Summary gives default models; each entry gives both settings.",
        "",
        "## Summary",
        "",
        "| # | Entry | What it changes | Wiki text | Effect (default) |",
        "|---|---|---|---|---|",
    ]
    for n, e in enumerate(entries, 1):
        lines.append(f"| {n} | {md_code(e['id'])} | {md_escape(_what_it_changes(m, e))} | "
                     f"{', '.join(_locations(located.get(e['id'], [])))} | "
                     f"{_effect_cell(dv, e, effects[e['id']])} |")
    lines += ["", "## Entries"]
    for n, e in enumerate(entries, 1):
        lines += ["", f"### {n}. {md_code(e['id'])}", "", _description(m, e)]
        for c, line in located.get(e["id"], []):
            lines += [""] + _citation_lines(c, line, wiki_commit)
        if e["prose"]:
            lines += ["", f"CCwiki's note: {md_escape(e['prose'])}"]
        lines += ["", _effect_paragraph(dv, e, effects[e["id"]])]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Self-test: each review finding as an executable check
# ---------------------------------------------------------------------------


def selftest(dv: Derivation) -> bool:
    m, ok = dv.m, True

    def check(name, cond, detail=""):
        nonlocal ok
        ok &= bool(cond)
        print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"   ({detail})" if detail and not cond else ""))

    q = dv.query
    print("real manifest")
    a = q(["sxdh", "lwe", "learning-subspace-with-noise", "prg-in-nc0"], "io")
    check("JLS21 is refused on LPN derived from LSN (binary, few samples)", not a["derivable"]
          and any(r["edge"].endswith("jls21") for r in a["refusedSteps"]))
    a = q(["sxdh", "gapsvp", "lpn", "prg-in-nc0"], "io")
    check("JLS21 is refused on LWE derived from GapSVP (Reg05 modulus)", not a["derivable"])
    a = q(["sxdh", "lwe", "lpn", "prg-in-nc0"], "io")
    check("JLS21 on given hypotheses is derived, assuming its regime", a["derivable"] and len(a["assumes"]) == 4)
    a = q(["gapsvp"], "leveled-fully-homomorphic-encryption")
    check("GapSVP => leveled FHE is refused at BGV12", not a["derivable"])
    a = q(["lpn-low-noise"], "ot")
    check("low-noise LPN => OT carries the quasi-polynomial assumption", a["derivable"] and a["assumes"])
    a = q(["functional-encryption"], "io")
    check("FE => iO only assuming compact sub-exponential FE", a["derivable"] and a["assumes"])
    fe = [r for r in dv.step_index[("red-fe-to-io", False)].requires]
    check("an FE concluded by SW14 never meets FE => iO's precondition",
          fe and all("red-hash-function-and-io-to-fe-sw14" not in r.met_by for r in fe))
    a = q(["inhomogeneous-sis"], "sis")
    check("ISIS => SIS (left to right) is quarantined, and its row on the pair says so",
          not a["derivable"]
          and [(r["edge"], r["reverse"], r["status"]) for r in a["recordedOnPair"]]
          == [("red-isis-inhomogeneous-sis-to-sis", False, "quarantined")]
          and any(x["kind"] == "quarantined" for r in a["refusedSteps"] for x in r["reasons"]))
    check("ISIS => CRHF is not derived", not q(["inhomogeneous-sis"], "crhf")["derivable"])
    a = q(["sis"], "inhomogeneous-sis")
    check("SIS => ISIS keeps the record's class", a["derivable"] and a["chainClass"] == "fully-black-box"
          and a["reverseSteps"] == ["red-isis-inhomogeneous-sis-to-sis"] and not a["assumes"])
    a = q(["circular-evasive-lwe"], "pke")
    check("a refuted start is marked vacuous", a.get("vacuous"))
    r = dv.implied_by("pke")
    check("refuted starts never appear in implied-by", "circular-evasive-lwe" not in {s["from"] for s in r["singles"]})
    r = dv.implied_by("ke")
    check("SSDDH is excluded from implied-by KE", "ssddh" in r["refutedExcluded"])
    for t in ("range-query-encryption", "hve"):
        check(f"BW07 is quarantined (bdh => {t})", not q(["bdh"], t)["derivable"])
    check("Wee22 BE is quarantined", not q(["evasive-lwe"], "be")["derivable"])
    a = q(["tdp"], "nizk")
    check("FLS90 on a given TDP assumes doubly enhanced, certified", a["derivable"] and a["assumes"])
    check("FLS90 is refused on RSA78's TDP", not q(["rsa"], "nizk")["derivable"])
    a = q(["subexponential-lpn"], "crhf")
    check("YZW19 carries the exponent > 1/2 assumption", a["derivable"] and a["assumes"])
    a = q(["kem"], "pke")
    check("completions never restate the target", all(c["add"] != "kem" for c in q(["owf"], "pke")["completions"]))
    a = q(["ddh"], "invertible-prf")
    check("no 'strongest' across iPRF notions", a["derivable"] and "strongest" not in a)
    a = q(["ddh"], "prg")
    check("DDH => PRG avoids BM84", a["derivable"] and "red-dlog-to-prg-bm84" not in a["edges"])
    # The PR #9 audit's semantic cases (plans/relations-followups.md §13).
    a = q(["cdh"], "prg")
    check("CDH => PRG is refused at BM84 (no DLOG => OWF on the same group yet: ccw:missing-edge-dlog-to-owf)",
          not a["derivable"] and any(r["edge"] == "red-dlog-to-prg-bm84"
                                     and [x["kind"] for x in r["reasons"]] == ["requires"] for r in a["refusedSteps"]))
    a = q(["lwe"], "com")
    check("LWE => COM avoids PKE => COM", a["derivable"] and "red-pke-to-com" not in a["edges"])
    a = q(["enhanced-trapdoor-permutation"], "mpc")
    check("ETDP => MPC is refused at Kil88 (semi-honest EGL OT; no compiler yet: "
          "ccw:missing-edge-ot-semi-honest-to-malicious)",
          not a["derivable"] and any(r["edge"] == "red-ot-to-mpc-kil88" for r in a["refusedSteps"]))
    a = q(["ddh"], "mpc")
    check("DDH => MPC holds through DMO00's OT, and only as Kil88's static MPC with abort",
          a["derivable"] and a["weakened"] and a["weakened"]["edge"] == "red-ot-to-mpc-kil88"
          and "red-cpir-to-ot-dmo00" in a["edges"])
    a = q(["ot"], "mpc")
    check("OT => MPC assumes malicious OT and concludes static MPC with abort only",
          a["derivable"] and [x["edge"] for x in a["assumes"]] == ["red-ot-to-mpc-kil88"]
          and a["weakened"] and a["weakened"]["edge"] == "red-ot-to-mpc-kil88")
    a = q(["bdh"], "abe")
    check("GPSW06 gives only selective KP-ABE, and only assuming DBDH (computational BDH does not invoke it)",
          a["derivable"] and a["weakened"] and a["weakened"]["edge"] == "red-bdh-to-abe-gpsw06"
          and [(x["edge"], x["hypothesis"]) for x in a["assumes"]] == [("red-bdh-to-abe-gpsw06", "bdh")])
    check("selective KP-ABE does not feed ABE => IBE", not q(["bdh"], "ibe")["derivable"])
    a = q(["bdh"], "be")
    check("selective KP-ABE does not feed ABE => BE",
          not a["derivable"] and any(r["edge"] == "red-abe-to-be" and "weakened" in [x["kind"] for x in r["reasons"]]
                                     for r in a["refusedSteps"]))
    check("BDH => PKE is not derived (selective KP-ABE => PKE awaits ccw:missing-edge-selective-kp-abe-to-pke)",
          not q(["bdh"], "pke")["derivable"])
    a = q(["prp"], "prf")
    check("a bare PRP gives a PRF only assuming a superpolynomial domain",
          a["derivable"] and [(x["edge"], x["hypothesis"]) for x in a["assumes"]] == [("red-prp-to-prf", "prp")])
    a = q(["strong-pseudorandom-permutation"], "prf")
    check("an sPRP, whose domain may be small, does not meet the PRP => PRF domain condition",
          not a["derivable"] and any(r["edge"] == "red-prp-to-prf" and [x["kind"] for x in r["reasons"]] == ["requires"]
                                     for r in a["refusedSteps"]))
    # HPPY25 (unstated) gives the full iPRF from a PRF first, so LR88's route
    # shows over the fully black-box steps only (R6).
    w = dv.restricted("fully-black-box").single("prf").weak.get("invertible-prf")
    check("LR88's PRP meets the domain condition: PRF => PRP => forward-game iPRF assumes nothing",
          w is not None and w.weak.edge == "red-prp-to-invertible-prf" and not w.assumes
          and w.step.hyps == ("prp",) and dv.restricted("fully-black-box").single("prf").facts["prp"].step.edge
          == "red-prf-to-prp-lr88")
    a = q(["fac"], "rsa", True)
    check("FAC => RSA (DLO24, generic ring) only assuming its preprocessing experiment",
          a["derivable"] and a["models"] == ["other"] and a["reverseSteps"] == ["red-rsa-to-fac-dlo24"]
          and [(x["edge"], x["hypothesis"]) for x in a["assumes"]] == [("red-rsa-to-fac-dlo24", "fac")]
          and "before the modulus is sampled" in a["assumes"][0]["notion"])
    a = q(["dcr"], "rsa", True)
    check("DCR => FAC => RSA is refused at DLO24: uniform factoring hardness is not its preprocessing notion",
          not a["derivable"] and any(r["edge"] == "red-rsa-to-fac-dlo24" and r["reverse"]
                                     and [x["kind"] for x in r["reasons"]] == ["requires"] for r in a["refusedSteps"]))
    a = q(["rsa"], "fac")
    check("RSA => FAC stays the ordinary fully black-box standard-model direction (RSA78)",
          a["derivable"] and a["chainClass"] == "fully-black-box" and a["edges"] == ["red-rsa-to-fac-rsa78"]
          and not a["assumes"])
    r = dv.implied_by("deniable-encryption")
    check("implied-by pair rows carry models", any(g["models"] for g in r["groups"]))
    r = dv.implied_by("mpc")
    check("honest-majority settings are listed apart", {s["from"] for s in r["settings"]}
          == {"honest-majority-t-lt-n-over-2", "honest-majority-t-lt-n-over-3"})
    a = q(["tdp"], "enhanced-trapdoor-permutation")
    check("no host hint naming the premise", a["nearMisses"]["targetHostDerived"] is None)
    a = q(["oblivious-interactive-hash-function"], "enhanced-trapdoor-permutation")
    check("a derived barrier inherits only circumventions that reach its pair",
          all(not d["circumventedBy"] for d in a["derivedBarriers"]) and
          any(d["circumventsOriginalOnly"] for d in a["derivedBarriers"]))
    a = q(["lpn-high-noise"], "sk-depir")
    check("the stub on the pair is named, and the hint says stub",
          any(r["status"] == "stub" for r in a["recordedOnPair"]) and a.get("withIdealised", {}).get("usesStub"))
    a = q(["ntru"], "pke")
    check("the heuristic edge on the pair is named", any(r["status"] == "heuristic" for r in a["recordedOnPair"]))
    a = q(["zkp"], "constant-round-zk-argument")
    check("an unclassified barrier carries its qualifier",
          a["recordedBarriers"] and a["recordedBarriers"][0]["qualifier"] == "unclassified")
    a = q(["pke-cpa-security"], "pke-cca1-security")
    check("a fixed-construction barrier carries its qualifier",
          a["recordedBarriers"] and a["recordedBarriers"][0]["qualifier"] == "fixed-construction")
    a = q(["com"], "tdp")
    kept = [d for d in a["derivedBarriers"] if not d["redundantWith"]]
    check("a derived barrier subsumed by a broader one is redundant", len(kept) < len(a["derivedBarriers"]),
          f"{len(kept)} of {len(a['derivedBarriers'])}")
    a = q(["owf", "prg"], "pke")
    check("a multi-start query gets derived barriers", any(not d["redundantWith"] for d in a["derivedBarriers"]))
    ad = dv.derived_barriers()
    inv = invariants(dv, ad)
    check("invariants hold", all(v for k, v in inv.items() if not k.startswith("_")), inv["_detail"])
    sen = sentinels(dv)
    check("sentinels hold", all(v for k, v in sen.items() if not k.startswith("_")), sen["_detail"])
    ok &= selftest_report(dv)

    print("synthetic patches")
    base = len(ad)
    res = {mut[0]: run_mutation(m, dv.cur, mut) for mut in MUTATIONS}
    _, _, a, inv = res["strongest-chain-conflict"]
    check("a stronger chain behind an unstated shortcut conflicts",
          a["chainClass"] == "unstated" and a["conflictingBarriers"] and not inv["noChainContradictsRecordedBarrier"])
    _, _, a, inv = res["derived-barrier-conflict"]
    check("a chain contradicting a derived barrier fails the invariant", not inv["noChainContradictsDerivedBarrier"])
    _, _, a, inv = res["quantum-chain-is-context"]
    check("a quantum chain beside a barrier is context, not conflict",
          a["derivable"] and not a["conflictingBarriers"] and a.get("barrierScopeNote") == ["quantum"]
          and inv["noChainContradictsRecordedBarrier"])
    _, _, a, inv = res["rom-chain-is-context"]
    check("a ROM chain beside a barrier is context, not conflict", a["derivable"] and not a["conflictingBarriers"])
    mdv, mad, a, inv = res["believed-true-consequence-not-propagated"]
    check("a believed-true consequence is not propagated",
          len(mad) == base and all(d["consequence"]["kind"] == "contradiction" for d in a["derivedBarriers"]),
          f"{len(mad)} vs {base}")
    _, _, a, inv = res["free-barrier-meets-unstated-chain"]
    check("an unstated chain conflicts with a free barrier",
          not inv["noChainContradictsRecordedBarrier"] and a["conflictingBarriers"]
          and a["conflictingBarriers"][0]["chainClass"] == "unstated")
    mdv, mad, a, inv = res["stub-barrier-not-propagated"]
    check("a stub barrier is not propagated",
          len(mad) < base and all(d["barrier"] != "bar-owp-to-ke-ir89" for d in a["derivedBarriers"]))
    ok &= selftest_upstream(dv, ad, res)
    ok &= selftest_direction_quarantine(dv)
    return ok


def selftest_direction_quarantine(dv: Derivation) -> bool:
    """A quarantine entry with `direction` holds back that direction of an
    equivalence only (R13, plans/derivations.md §2a): the other direction is
    still a step with the record's class, the reduction is not `excluded`,
    and the held direction is named on its pair and in its refusal. On an
    implication, `direction` does not resolve."""
    check, state = _checker()
    print("a quarantine of one direction (R13)")
    eq = dict(_red("red-syn-e-eq-f", ["syn-e"], "syn-f", "fully-black-box"), kind="equivalence")
    patch = {"objects": [_obj("syn-e", "assumption"), _obj("syn-f"), _obj("syn-g")],
             "reductions": [eq, _red("red-syn-f-to-g", ["syn-f"], "syn-g", "fully-black-box")]}
    pm = Manifest(apply_patch(dv.m.data, patch), "")
    data = copy.deepcopy(dv.cur.data)
    reason = "The Statement does not establish this direction."
    data.setdefault("quarantine", []).append({"edge": "red-syn-e-eq-f", "direction": "forward", "reason": reason})
    data.setdefault("equivalences", {})["red-syn-e-eq-f"] = {"forward": "record", "reverse": "record"}
    qdv = Derivation(pm, Curation(data, ""))
    held = sorted(s.sort_key for s in qdv.quarantined if s.edge == "red-syn-e-eq-f")
    check("only the held direction is quarantined, and the reduction is not excluded",
          held == [("red-syn-e-eq-f", False)] and "red-syn-e-eq-f" not in qdv.excluded.get("quarantined", []),
          held)
    a = qdv.query(["syn-e"], "syn-g")
    refused = [(r["edge"], r["reverse"], [x["kind"] for x in r["reasons"]]) for r in a["refusedSteps"]]
    check("the held direction is refused, with its reason",
          not a["derivable"] and ("red-syn-e-eq-f", False, ["quarantined"]) in refused
          and any(x.get("reason") == reason for r in a["refusedSteps"] for x in r["reasons"]), refused)
    a = qdv.query(["syn-e"], "syn-f")
    rows = [(r["edge"], r["reverse"], r["status"], r.get("detail")) for r in a["recordedOnPair"]]
    check("its row on the pair is quarantined, with the reason",
          rows == [("red-syn-e-eq-f", False, "quarantined", reason)], rows)
    a = qdv.query(["syn-f"], "syn-e")
    rows = [(r["edge"], r["reverse"], r["status"]) for r in a["recordedOnPair"]]
    check("the other direction is a step, with the record's class",
          a["derivable"] and a["chainClass"] == "fully-black-box" and a["reverseSteps"] == ["red-syn-e-eq-f"]
          and rows == [("red-syn-e-eq-f", True, "used")], (a.get("chainClass"), rows))
    inv = invariants(qdv, qdv.derived_barriers())
    check("invariants hold with a quarantine of one direction", inv["noIneligibleEdges"], inv["_detail"])
    data["quarantine"].append({"edge": "red-syn-f-to-g", "direction": "reverse", "reason": reason})
    check("a quarantine of one direction of an implication does not resolve",
          "not an equivalence red-syn-f-to-g" in Curation(data, "").unresolved(pm))
    return state["ok"]


def _checker():
    """A `check(name, cond, detail)` that prints as `selftest` does, and the
    running result."""
    state = {"ok": True}

    def check(name, cond, detail=""):
        state["ok"] &= bool(cond)
        print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"   ({detail})" if detail and not cond else ""))
    return check, state


def selftest_upstream(dv: Derivation, all_derived: list, res: dict) -> bool:
    """The upstream fields of plans/relations-followups.md §4.4, through their
    three mutations (`res`, by id, from `run_mutation`): a barrier `model`
    stops R12, a `reverseClass` overrides the curation, and a `refutedBy`
    makes an answer vacuous. Two patches of its own show that R8 still
    checks a ROM barrier and that its scope note does not claim one is
    standard-model. None is on the reviewed commit, so the real manifest
    supersedes nothing."""
    check, state = _checker()
    print("upstream fields (plans/relations-followups.md §4.4)")
    check("the reviewed manifest supersedes no curation entry", not superseded(dv), superseded(dv))

    sim98 = sum(1 for d in all_derived if d["barrier"] == "bar-owp-to-crhf-sim98")
    mdv, mad, a, inv = res["barrier-model-not-propagated"]
    check("a barrier proved in the ROM is not propagated, and costs exactly its own derived barriers",
          sim98 > 0 and len(mad) == len(all_derived) - sim98
          and all(d["barrier"] != "bar-owp-to-crhf-sim98" for d in a["derivedBarriers"]),
          f"{len(mad)} vs {len(all_derived)} - {sim98}")
    check("invariants hold with a barrier proved in the ROM", all(v for k, v in inv.items() if not k.startswith("_")),
          inv["_detail"])
    # They would hold just as well if R8 skipped the barrier: a standard-model
    # chain on Sim98's own pair must still conflict with it.
    rom_sim98 = {"barrierPatches": [{"id": "bar-owp-to-crhf-sim98", "set": {"model": "rom"}}]}
    cdv = Derivation(Manifest(apply_patch(dv.m.data, dict(rom_sim98, reductions=[
        _red("red-syn-owp-to-crhf", ["owp"], "crhf", "fully-black-box")])), ""), dv.cur)
    conflicts = invariants(cdv, cdv.derived_barriers())["_detail"]["conflicts"]
    check("R8 still checks a barrier proved in the ROM",
          ("bar-owp-to-crhf-sim98", 0, "fully-black-box") in conflicts, conflicts)
    # R8's scope note says the barriers concern standard-model reductions, so
    # a ROM chain beside the ROM barrier alone does not get it.
    rom_chain = {"reductions": [_red("red-syn-owp-to-crhf-rom", ["owp"], "crhf", "fully-black-box", "rom")]}
    notes = []
    for patch in (rom_chain, dict(rom_chain, **rom_sim98)):
        pdv = Derivation(Manifest(apply_patch(dv.m.data, patch), ""), dv.cur)
        notes.append(pdv.query(["owp"], "crhf", True).get("barrierScopeNote"))
    check("a ROM chain gets the scope note beside a standard-model barrier, not beside a ROM one",
          notes == [["rom"], None], notes)

    base = dv.query(["ot"], "rabin-ot")
    mdv, mad, a, inv = res["reverse-class-field"]
    check("the record's reverseClass wins over the curation's table",
          base["derivable"] and base["chainClass"] == "fully-black-box"
          and a["derivable"] and a["chainClass"] == "unstated", (base.get("chainClass"), a.get("chainClass")))
    check("an equivalence whose record states reverseClass supersedes its entry",
          superseded(mdv) == ["equivalences:red-rabin-ot-to-ot"]
          and not sentinels(mdv)["curationSuperseded"], superseded(mdv))

    mdv, mad, a, inv = res["refuted-by-field"]
    vac = a.get("vacuous", [])
    check("an object the record marks refuted is vacuous, by the record's key and sentence",
          [v["object"] for v in vac] == ["syn-r"] and vac[0]["source"] == "X"
          and vac[0]["text"] == RECORDED_REFUTATION_TEXT, vac)
    r = mdv.implied_by("pke")
    check("an object the record marks refuted is never a source",
          "syn-r" in r["refutedExcluded"] and "syn-r" not in {s["from"] for s in r["singles"]})
    check("a manifest refutation is not a curation entry", "refuted:syn-r" not in
          {e["id"] for e in curation_entries(mdv.cur.data)} and mdv.cur.sha256 == dv.cur.sha256)
    return state["ok"]


def selftest_report(dv: Derivation) -> bool:
    """The review document's measure on the reviewed commit (§2.6): BM84's
    requirement removes 32 default pairs, and the ssddh and honest-majority
    entries, which change no closure, still show an effect."""
    check, state = _checker()
    print("curation review")
    base = review_baseline(dv, None)
    entries = {e["id"]: e for e in curation_entries(dv.cur.data)}

    def effect(eid):
        return entry_effect(base, entries[eid]) if eid in entries else None

    x = effect("requires:red-dlog-to-prg-bm84:dlog")
    check("without BM84's requirement the engine derives 32 more default pairs",
          x and len(x[False]["removes"]) == 32 and "ddh-prg" in x["golden"],
          x and f"{len(x[False]['removes'])} more; golden {x['golden']}")
    x = effect("refuted:ssddh")
    check("refuted:ssddh has an effect: its answers stop being vacuous",
          x and not x["none"] and x[False]["vacuous"] and x[False]["backward"] and "ssddh-ke" in x["golden"])
    x = effect("settings:honest-majority-t-lt-n-over-2")
    check("settings:honest-majority-t-lt-n-over-2 has an effect: MPC's backward list",
          x and not x["none"] and x[False]["backward"] == ["mpc"], x and x[False]["backward"])
    return state["ok"]


#: The wiki's inbox kinds (`INBOX_KINDS` in its scripts/review/round.mjs).
INBOX_KINDS = ("content-error", "verification-gap", "missing-edge", "node-granularity", "reference-page", "stub",
               "schema-convention", "title-or-slug")
#: The keys plans/relations-followups.md §4.1 lets an ask carry; the wiki's
#: own check rejects a file with any key it does not know.
INBOX_KEYS = {"id", "kind", "summary", "pages", "proposed_action", "rationale", "related", "needs_paper",
              "confidence"}
INBOX_REQUIRED = ("id", "kind", "summary", "pages", "proposed_action")
_INBOX_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*:[A-Za-z0-9][A-Za-z0-9._-]*")
#: Where an ask names the curation entries it retires: its `rationale`'s
#: sentence "Retires CCwiki's curation entries `…`, `…`."
_RETIRES = re.compile(r"Retires CCwiki's curation entr(?:y|ies) ((?:`[^`]+`(?:,? and |, )?)+)")


def inbox_problems(inbox: dict, asks_markdown: str, entry_ids: set) -> list:
    """Every problem with the asks' inbox file (§4.1): its shape, ids, kinds
    and keys; a retired entry that is not in the curation; a `ccw:` id the
    asks document does not name. The wiki's `round.mjs inbox` is the
    authority; this catches what would make it reject the file."""
    bad = []
    if not isinstance(inbox, dict) or set(inbox) != {"source", "items"}:
        return ['the file must be one object {"source", "items"}']
    if not isinstance(inbox["source"], str) or not inbox["source"].strip():
        bad.append("source must be a non-empty string")
    if not isinstance(inbox["items"], list) or not inbox["items"]:
        return bad + ["items must be a non-empty list"]
    seen = set()
    for n, it in enumerate(inbox["items"]):
        label = it.get("id", f"items[{n}]") if isinstance(it, dict) else f"items[{n}]"
        if not isinstance(it, dict):
            bad.append(f"{label}: not an object")
            continue
        bad += [f"{label}: unknown key {k}" for k in sorted(set(it) - INBOX_KEYS)]
        bad += [f"{label}: no {k}" for k in INBOX_REQUIRED if k not in it]
        iid = it.get("id")
        if not isinstance(iid, str) or not _INBOX_ID.fullmatch(iid):
            bad.append(f"{label}: the id must be <prefix>:<name>")
        elif re.match(r"r\d+:", iid):
            bad.append(f"{label}: the prefix r<n>: is the wiki's audit findings'")
        elif not iid.startswith("ccw:"):
            bad.append(f"{label}: CCwiki's asks are ccw:")
        if iid in seen:
            bad.append(f"{label}: a second item with this id")
        seen.add(iid)
        if isinstance(iid, str) and iid.startswith("ccw:") and f"`{iid}`" not in asks_markdown:
            bad.append(f"{label}: plans/wiki-asks.md does not name it")
        if it.get("kind") not in INBOX_KINDS:
            bad.append(f"{label}: kind {it.get('kind')!r} is not one of the wiki's")
        for k in ("summary", "proposed_action", "rationale"):
            if k in it and (not isinstance(it[k], str) or not it[k].strip()):
                bad.append(f"{label}: {k} must be a non-empty string")
        pages = it.get("pages")
        if (not isinstance(pages, list) or not pages
                or any(not isinstance(p, str) or not p or p.startswith("/") or ".." in p.split("/") for p in pages)):
            bad.append(f"{label}: pages must be a non-empty list of repository-relative paths")
        if "needs_paper" in it and not isinstance(it["needs_paper"], bool):
            bad.append(f"{label}: needs_paper must be true or false")
        if "confidence" in it and it["confidence"] not in ("high", "medium", "low"):
            bad.append(f"{label}: confidence must be high, medium or low")
        if "related" in it and (not isinstance(it["related"], list)
                                or any(not isinstance(r, str) for r in it["related"])):
            bad.append(f"{label}: related must be a list of ids")
        for m in _RETIRES.finditer(it.get("rationale", "") if isinstance(it.get("rationale"), str) else ""):
            for eid in re.findall(r"`([^`]+)`", m.group(1)):
                if eid not in entry_ids:
                    bad.append(f"{label}: retires {eid}, which is not a curation entry")
    return bad


def selftest_units() -> bool:
    """The checks that need no manifest and no clone, run by `make check`:
    the quote-matching cases Python and Swift share, the review document's
    escaping and fences, the asks' inbox file, and the curation's citations
    (plans/relations-followups.md §2.6, §4.1)."""
    check, state = _checker()

    print("quote matching (Tests/CCwikiTests/Fixtures/quote-cases.json)")
    with open(QUOTE_CASES, encoding="utf-8") as f:
        cases = json.load(f)["cases"]
    check("the shared cases load", len(cases) >= 10, f"{len(cases)} cases")
    for c in cases:
        line = locate_quote(c["page"], c["quote"], c["section"])
        ok = (line is not None) == c["found"] and ("line" not in c or line == c["line"])
        check(c["name"], ok, f"line {line}; expected {'line ' + str(c.get('line')) if c['found'] else 'not found'}")

    print("the review document")
    quote = "If [[discrete-logarithm|DLOG]] is hard in $\\ZZ_p^*$, a **PRG** follows — [[a|b]]"
    block = "\n".join(_citation_lines({"page": "content/Reductions/x y.md", "section": "Statement",
                                       "quote": quote}, 23, "ab81f02ff4a0e898d1e6b76dcf5ec8df2acf4157"))
    check("a quote comes out inside a fence unchanged", f"\n```markdown\n{quote}\n```" in block, block)
    check("its location links the line of the source view at the commit, the path percent-encoded",
          "https://github.com/axhoover/cryptology.city/blob/ab81f02ff4a0e898d1e6b76dcf5ec8df2acf4157/"
          "content/Reductions/x%20y.md?plain=1#L23" in block, block)
    fenced = md_fence("uses ``` and ```` inside")
    check("a fence is one backtick longer than the quote's longest run",
          fenced.startswith("`````markdown\n") and fenced.endswith("\n`````"), fenced)
    check("generated text is escaped: \\ first, then | * _ $ ` [ ]",
          md_escape("a|b*c_d$e`f[g]h\\i") == "a\\|b\\*c\\_d\\$e\\`f\\[g\\]h\\\\i", md_escape("a|b*c_d$e`f[g]h\\i"))
    check("a cell with | and * is escaped", md_escape("Z_p^* | t < n/2") == "Z\\_p^\\* \\| t < n/2")
    check("an id is a code span, unescaped", md_code("requires:red-a_b~reverse:x") == "`requires:red-a_b~reverse:x`")
    missing = "\n".join(_citation_lines({"page": "content/a.md", "section": None, "quote": "gone"}, None, "ab81f02ff4"))
    check("a missing quote says so", "**Not found on the page at ab81f02**" in missing, missing)

    print("the curation's citations")
    with open(DEFAULT_CURATION, encoding="utf-8") as f:
        data = json.load(f)
    entries = curation_entries(data)
    ids = [e["id"] for e in entries]
    check("47 entries, each id once", len(ids) == 47 and len(set(ids)) == len(ids), len(ids))
    uncited = [e["id"] for e in entries if not e["cites"]]
    check("every entry cites the wiki", not uncited, uncited)
    bad = [(e["id"], c.get("page")) for e in entries for c in e["cites"]
           if not (c.get("page", "").startswith("content/") and c["page"].endswith(".md"))
           or "…" in c.get("quote", "") or not c.get("quote", "").strip()]
    check("each citation is a content page and a contiguous quote", not bad, bad)
    notions = [e["raw"].get("notionMarkdown") for e in entries if e["key"] in ("requires", "weakens")]
    check("every requirement and weakening has a notionMarkdown", all(notions), notions.count(None))
    check("no notionMarkdown has wikilinks, links or emphasis",
          not [n for n in notions if n and any(k in n for k in ("[[", "](", "**"))])

    print("the wiki asks (plans/wiki-asks.inbox.json)")
    with open(WIKI_ASKS_INBOX, encoding="utf-8") as f:
        inbox = json.load(f)
    with open(WIKI_ASKS, encoding="utf-8") as f:
        asks = f.read()
    problems = inbox_problems(inbox, asks, set(ids))
    check("the inbox file is valid, its retired entries exist and wiki-asks.md names each ask",
          not problems, "; ".join(problems))
    check("the checker refuses an unknown key, an r<n>: id and a retired entry that does not exist",
          len(inbox_problems({"source": "s", "items": [
              {"id": "r3:edge-1", "kind": "missing-edge", "summary": "s", "pages": ["content/a.md"],
               "proposed_action": "a", "origin": "x",
               "rationale": "Retires CCwiki's curation entries `requires:red-x:y`."}]}, "", set(ids))) == 3)
    return state["ok"]


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------


def parse_query(q: str):
    lhs, rhs = q.split("=>")
    return [s.strip() for s in lhs.split(",") if s.strip()], rhs.strip()


def print_answer(dv: Derivation, start, target, inc):
    a = dv.query(start, target, inc)
    mode = "all models" if inc else "default models"
    print(f"\n== {{{', '.join(start)}}} => {target}   [{mode}]")
    if not a["supported"]:
        print("  unsupported:", a["reason"])
        return a
    for k in ("vacuous", "modelStart", "settingStart"):
        if a.get(k):
            print(f"  {k}: {a[k]}")
    if a["derivable"]:
        cl = dv.closure(start, inc)
        print(f"  derivable: depth {a['depth']}, chain class {a['chainClass']}, "
              f"models {a['models'] or ['standard']}, derived by CCwiki from {a['reductionCount']} recorded reductions")
        for q in a["assumes"]:
            print(f"  assuming {q['notion']}  ({q['edge']})")
        if a["weakened"]:
            print(f"  only: {a['weakened']['notion']}  ({a['weakened']['edge']})")
        if a["caveats"]:
            print("  caveats:", a["caveats"])
        if a.get("strongest"):
            st = a["strongest"]
            print(f"  strongest class over all derivations: {st['chainClass']} at depth {st['depth']} via {st['edges']}")
        for line in dv.render(cl, target).splitlines():
            print("   ", line)
        for k in ("conflictingBarriers", "majorResultBarriers", "barrierScopeNote"):
            if a.get(k):
                print(f"  {k}: {a[k]}")
    else:
        print("  no derivation")
        if a.get("withIdealised"):
            print(f"  withIdealised: {a['withIdealised']}")
        for r in a["refusedSteps"]:
            print(f"  refused {r['edge']}{' (reverse)' if r['reverse'] else ''} [{r['class']}]: "
                  + "; ".join(f"{x['kind']}" + (f" {x.get('hypothesis')} from {x.get('producedBy')}: {x.get('notion')}"
                                                if x["kind"] in ("requires", "weakened") else
                                                f" {x.get('reason', '')}{x.get('scopedHypotheses', '')}")
                              for x in r["reasons"])
                  + (f"  barriers {r['barriers']}" if r["barriers"] else ""))
        nm = {k: v for k, v in a["nearMisses"].items() if v}
        if nm:
            print(f"  nearMisses: {nm}")
        print(f"  completions ({a['completionCount']}):",
              [(c["add"], c["depth"], c["chainClass"], c["models"], c["assumes"]) for c in a["completions"]])
        if a["questionBecomes"]:
            print("  the target gives back, so the question becomes start =>", [c["add"] for c in a["questionBecomes"]])
        print("  footer:", a["footer"])
    rec = [r for r in a["recordedOnPair"]]
    if rec:
        print("  recorded on this pair:", [(r["edge"], r["status"]) for r in rec])
    for b in a["recordedBarriers"]:
        print(f"  recorded barrier {b['id']} [{b['class']}, {b['strength']}]"
              + (f" qualifier {b['qualifier']}" if b["qualifier"] else ""))
    for b in a["reverseBarriers"]:
        print(f"  reverse barrier {b['id']} [{b['class']}]")
    for k in ("derivedBarriers", "derivedReverseBarriers"):
        for d in a.get(k, []):
            tag = f" (covered by {d['redundantWith']})" if d["redundantWith"] else ""
            circ = f" circumvented by {d['circumventedBy']}" if d["circumventedBy"] else ""
            orig = f" ({d['circumventsOriginalOnly']} circumvent the original pair only)" if d["circumventsOriginalOnly"] else ""
            print(f"  {k}: {d['barrier']} [{d['class']}, {d['consequence']['kind']}] up {d['up']} down {d['down']}{circ}{orig}{tag}")
    return a


def report(dv: Derivation):
    m = dv.m
    t0 = time.perf_counter()
    dv2 = Derivation(m, dv.cur)
    t_build = time.perf_counter() - t0
    print(f"manifest sha256 {m.sha256}; curation sha256 {dv.cur.sha256}")
    print("counts", m.counts())
    print(f"eligible steps: default {len(dv.default_steps)}, all {len(dv.steps)}, quarantined {len(dv.quarantined)}; "
          f"excluded", {k: len(v) for k, v in sorted(dv.excluded.items())})
    starts = sorted(o for o in m.objects if m.type(o) not in EXCLUDED_TYPES)
    t0 = time.perf_counter()
    sizes = {o: (len(dv2.closure([o], False).facts) - 1, len(dv2.closure([o], True).facts) - 1) for o in starts}
    t_all = time.perf_counter() - t0
    nonempty = {o: s for o, s in sizes.items() if s[0] or s[1]}
    print(f"\nsingle-object closures: {len(starts)} starts, {len(nonempty)} with a non-empty closure")
    print(f"timing: build {t_build*1000:.1f} ms; all {2*len(starts)} closures {t_all*1000:.0f} ms "
          f"({t_all/(2*len(starts))*1000:.2f} ms each)")
    print("largest (default, all):")
    for o, s in sorted(nonempty.items(), key=lambda t: (-t[1][1], t[0]))[:25]:
        print(f"  {o:40s} {s[0]:3d} {s[1]:3d}")
    pairs = [(o, t, f) for o in starts for t, f in dv.single(o).facts.items() if f.step is not None]
    wk = [(o, t) for o in starts for t in dv.single(o).weak if t not in dv.single(o).facts]
    from collections import Counter
    print(f"default derived pairs: {len(pairs)}; by chain class {dict(Counter(f.chain for _, _, f in pairs))}; "
          f"with assumptions {sum(1 for _, _, f in pairs if f.assumes)}; weakened-only {len(wk)}")
    print("  by models", dict(Counter(tuple(sorted(f.models)) for _, _, f in pairs)))
    print("  by depth", dict(sorted(Counter(f.depth for _, _, f in pairs).items())))
    allp = [(o, t) for o in starts for t, f in dv.single(o, True).facts.items() if f.step is not None]
    print(f"with the toggle: {len(allp)} pairs, {sum(1 for o, t in allp if dv.single(o, True).facts[t].scoped)} model-scoped")

    all_derived = dv.derived_barriers()
    dpairs = {(d["hypotheses"][0], d["conclusion"]) for d in all_derived}
    recorded_pairs = {(b["hypotheses"][0], b["conclusion"]) for b in m.barriers.values() if len(b["hypotheses"]) == 1}
    print(f"\nderived barriers: {len(all_derived)} records, {len(dpairs)} pairs, "
          f"{len(dpairs - recorded_pairs)} not recorded, from {len({d['barrier'] for d in all_derived})} barriers")

    t0 = time.perf_counter()
    for start, target, inc in [
        (["ddh"], "ot", False), (["owf", "kem"], "pke", False), (["owf"], "pke", False),
        (["pke"], "ot", False), (["fac"], "pke", False), (["fac"], "pke", True),
        (["rom"], "ot", False), (["rom"], "ot", True), (["lpn"], "pke", False), (["dlog"], "cdh", True),
        (["sxdh", "lwe", "learning-subspace-with-noise", "prg-in-nc0"], "io", False),
        (["lpn-low-noise"], "ot", False), (["enhanced-trapdoor-permutation"], "mpc", False),
    ]:
        print_answer(dv, start, target, inc)
    print(f"\n(worked examples {1000*(time.perf_counter()-t0):.0f} ms including completions)")

    for t in ("pke", "ot", "mpc"):
        t0 = time.perf_counter()
        r = dv.implied_by(t, False)
        dt = time.perf_counter() - t0
        print(f"\nimplied-by {t}: {r['singleCount']} single objects, {r['pairCount']} pairs ({dt*1000:.0f} ms); "
              f"settings {[s['from'] for s in r['settings']]}; refuted excluded {r['refutedExcluded']}")
        print("  singles:", [(s["from"], s["depth"]) + ((s["assumes"],) if s["assumes"] else ()) for s in r["singles"]])
        for g in r["groups"]:
            print(f"  via {g['edge']} {g['hypotheses']}: {g['pairCount']} pairs, models {g['models']}, "
                  f"e.g. {[p['pair'] for p in g['pairs'][:4]]}")

    print("\nR5 policy: unstated after an idealised step")
    cav = Derivation(m, dv.cur, "caveat")
    lost = {}
    for o in starts:
        r = set(dv.closure([o], True).facts)
        c = set(cav.closure([o], True).facts)
        if c - r:
            lost[o] = sorted(c - r)
    print(f"  facts the caveat policy would add: {sum(len(v) for v in lost.values())} from {len(lost)} starts")
    print("\nR13 policy: unmet preconditions")
    pc = Derivation(m, dv.cur, precondition_policy="caveat")
    lost = {}
    for o in starts:
        r = set(dv.closure([o]).facts)
        c = set(pc.closure([o]).facts)
        if c - r:
            lost[o] = sorted(c - r)
    print(f"  facts the caveat policy would add: {sum(len(v) for v in lost.values())} from {len(lost)} starts")
    for o, v in sorted(lost.items()):
        print(f"    {o}: {v}")
    nocur = Derivation(m, Curation.empty())
    gone = {}
    for o in starts:
        a = set(nocur.closure([o]).facts)
        b = set(dv.closure([o]).facts) | set(dv.closure([o]).weak)
        if a - b:
            gone[o] = sorted(a - b)
    print(f"\nfacts the curation removes (default filter): {sum(len(v) for v in gone.values())} from {len(gone)} starts")

    inv = invariants(dv, all_derived)
    print("\ninvariants:", {k: v for k, v in inv.items() if not k.startswith("_")})
    if not all(v for k, v in inv.items() if not k.startswith("_")):
        print("  detail:", inv["_detail"])
    sen = sentinels(dv)
    print("sentinels:", {k: v for k, v in sen.items() if not k.startswith("_")}, sen["_detail"])


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("relations", nargs="?",
                   help="path to .reductions/relations.json; needed by all but --selftest-units and --check-quotes")
    p.add_argument("--curation", default=DEFAULT_CURATION, help="path to derivation-curation.json")
    p.add_argument("--query", action="append", default=[], help='"a, b => c"')
    p.add_argument("--all-models", action="store_true", help="include idealised and 'other' models (R4)")
    p.add_argument("--implied-by", action="append", default=[])
    p.add_argument("--report", action="store_true")
    p.add_argument("--selftest", action="store_true")
    p.add_argument("--selftest-units", action="store_true",
                   help="the checks that need no manifest: quote matching, the review's escaping, the asks")
    p.add_argument("--lint", metavar="WIKI_ROOT", help="Statement lint over the wiki clone's pages")
    p.add_argument("--check-quotes", metavar="WIKI_ROOT", help="is every curation quote still on its page?")
    p.add_argument("--curation-report", metavar="OUT", help="write the curation review (plans/curation-review.md)")
    p.add_argument("--wiki-root", help="the clone --curation-report reads the quoted pages from")
    p.add_argument("--golden", help="write the golden JSON here")
    p.add_argument("--wiki-commit", default="", help="the clone's HEAD, recorded in the golden file and the review")
    p.add_argument("--policy", choices=["refuse", "caveat"], default=UNSTATED_AFTER_IDEALISED)
    p.add_argument("--precondition-policy", choices=["refuse", "caveat"], default=UNMET_PRECONDITION)
    a = p.parse_args(argv)

    if a.selftest_units and not selftest_units():
        sys.exit(1)
    if a.check_quotes:
        found = check_quotes(Curation.load(a.curation), a.check_quotes)
        missing = [r for r in found if r["line"] is None]
        for r in missing:
            c = r["cite"]
            where = f"§ {c['section']}" if c.get("section") is not None else "(anywhere)"
            print(f"not found: {r['entry']}: {c['page']} {where}: {c['quote']}")
        print(f"quotes: {len(found) - len(missing)} of {len(found)} found")
        if missing:
            sys.exit(1)
    if a.relations is None:
        if a.query or a.implied_by or a.report or a.selftest or a.lint or a.golden or a.curation_report \
                or not (a.selftest_units or a.check_quotes):
            p.error("RELATIONS_JSON is required")
        return

    dv = Derivation(Manifest.load(a.relations), Curation.load(a.curation), a.policy, a.precondition_policy)
    for q in a.query:
        start, target = parse_query(q)
        print_answer(dv, start, target, a.all_models)
    for t in a.implied_by:
        print(json.dumps(dv.implied_by(t, a.all_models), indent=1))
    if a.report:
        report(dv)
    if a.selftest:
        if not selftest(dv):
            sys.exit(1)
    if a.lint:
        hits = statement_lint(dv, a.lint)
        for h in hits:
            print(f"possible dropped conjunct: {h['edge']} hypotheses {h['hypotheses']}; Statement names {h['unlisted']}")
        print(f"statement lint: {len(hits)} unreviewed hit(s)")
        if hits:
            sys.exit(1)
    if a.golden:
        g = golden(dv, a.wiki_commit)
        with open(a.golden, "w") as f:
            json.dump(g, f, indent=1, sort_keys=False, ensure_ascii=False)
            f.write("\n")
        print(f"wrote {a.golden}: {len(g['queries'])} queries, {len(g['mutations'])} mutations", file=sys.stderr)
    if a.curation_report:
        write_curation_report(dv, a.curation_report, a.wiki_root, a.wiki_commit, p)


def write_curation_report(dv: Derivation, out: str, wiki_root, wiki_commit: str, parser) -> None:
    """--curation-report: refuses a manifest that is not the golden file's,
    writes the review, and exits 1 when a quote is missing (the document is
    written all the same, and says which)."""
    if not wiki_root or not wiki_commit:
        parser.error("--curation-report needs --wiki-root and --wiki-commit")
    with open(GOLDEN_FIXTURE, encoding="utf-8") as f:
        g = json.load(f)
    if dv.m.sha256 != g["manifestSHA256"]:
        sys.exit(f"✗ this relations.json is not the golden file's (SHA-256 {dv.m.sha256[:12]}…, the golden "
                 f"file's {g['manifestSHA256'][:12]}…).\n"
                 f"Use a separate clone at the golden file's commit: `git clone {WIKI_REPOSITORY} <dir> && "
                 f"git -C <dir> checkout {g['wikiCommit']}`. Never check out a commit in CCwiki's own clone, "
                 "which is pull-only.")
    if wiki_commit != g["wikiCommit"]:
        print(f"note: the clone is at {wiki_commit[:12]} and the golden file at {g['wikiCommit'][:12]}; their "
              "manifests agree, so the review quotes the clone's pages.", file=sys.stderr)
    text = curation_report(dv, wiki_root, wiki_commit)
    with open(out, "w", encoding="utf-8") as f:
        f.write(text)
    header = re.search(r"entries=(\d+) quotesMissing=(\d+)", text)
    print(f"wrote {out}: {header.group(1)} entries, {header.group(2)} quotes missing", file=sys.stderr)
    if header.group(2) != "0":
        sys.exit(1)


if __name__ == "__main__":
    main()
