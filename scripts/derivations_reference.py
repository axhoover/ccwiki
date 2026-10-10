#!/usr/bin/env python3
"""Reference implementation of CCwiki's derivation engine.

The specification is plans/derivations.md; this file is its executable form.
The Swift `Derivation` type (Sources/CCwiki/Wiki/Derivation.swift) must agree
with it, and the corpus test checks that agreement against the golden file
this script writes (Tests/CCwikiTests/Fixtures/derivations-golden.json).

Python 3 standard library only. Nothing here reads the network or the wiki's
pages; the only input is `.reductions/relations.json`.

    # what follows from a set of objects, and the proof of one of them
    derivations_reference.py RELATIONS_JSON --query "ddh => ot"
    derivations_reference.py RELATIONS_JSON --query "owf, kem => pke"
    derivations_reference.py RELATIONS_JSON --query "fac => pke" --all-models

    # everything implying an object
    derivations_reference.py RELATIONS_JSON --implied-by pke

    # closure sizes, worked examples, invariants and timings
    derivations_reference.py RELATIONS_JSON --report

    # the golden file the Swift corpus test asserts against
    derivations_reference.py RELATIONS_JSON --golden OUT.json --wiki-commit SHA

Rule numbers (R1, R2, ...) refer to plans/derivations.md section 2.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
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

CLASS_RANK = {"fully-black-box": 0, "relativizing": 1, "free": 2, "unstated": 3}

FOOTER = (
    "CCwiki found no derivation from the reductions the wiki records. "
    "This is not a separation: the record is incomplete, and only the "
    "barriers listed here are results."
)


# ---------------------------------------------------------------------------
# The manifest
# ---------------------------------------------------------------------------


class Manifest:
    def __init__(self, path: str):
        with open(path, "rb") as f:
            raw = f.read()
        self.sha256 = hashlib.sha256(raw).hexdigest()
        d = json.loads(raw)
        if d.get("version") != 1:
            raise SystemExit(f"relations.json version {d.get('version')}; this knows 1")
        self.objects = {o["id"]: o for o in d["objects"]}
        self.reductions = {r["id"]: r for r in d["reductions"]}
        self.barriers = {b["id"]: b for b in d["barriers"]}
        self.classes = d["classes"]
        self.sentinels = set(d.get("classSentinels", []))
        self.propositions = d.get("propositions", {})
        self._closure = {}
        for name in self.classes:
            seen, stack = set(), [name]
            while stack:
                for broader in self.classes.get(stack.pop(), {}).get("implies", []):
                    if broader not in seen:
                        seen.add(broader)
                        stack.append(broader)
            self._closure[name] = seen

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

    def counts(self) -> dict:
        return {
            "objects": len(self.objects),
            "reductions": len(self.reductions),
            "barriers": len(self.barriers),
        }


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
    cls: str  # effective class (R3)
    stub: bool

    @property
    def default(self) -> bool:
        return self.model in DEFAULT_MODELS

    @property
    def sort_key(self):
        return (self.edge, self.reverse)


def build_steps(m: Manifest) -> tuple[list, dict]:
    """Returns (steps, excluded) where excluded maps reason -> [edge ids]."""
    steps, excluded = [], {}

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
        steps.append(Step(rid, tuple(r["hypotheses"]), r["conclusion"], False, model, cls, stub))
        if r["kind"] == "equivalence":  # R1: both directions, reverse marked
            steps.append(Step(rid, (r["conclusion"],), r["hypotheses"][0], True, model, cls, stub))
    return steps, excluded


# ---------------------------------------------------------------------------
# Facts and closures (R5-R7)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Fact:
    id: str
    depth: int
    step: Step | None  # None: given
    models: frozenset  # non-standard models the derivation relies on
    scoped: bool  # R5: holds only inside an idealised model
    chain: str  # R6: chain class
    caveats: tuple = ()  # edge ids of unstated-after-idealised steps (policy "caveat")


@dataclass
class Closure:
    start: tuple
    include_idealised: bool
    facts: dict = field(default_factory=dict)
    blocked: dict = field(default_factory=dict)  # (edge, reverse) -> (step, reason, scoped hyp ids)


class Derivation:
    def __init__(self, m: Manifest, unstated_after_idealised: str = UNSTATED_AFTER_IDEALISED):
        self.m = m
        self.policy = unstated_after_idealised
        self.steps, self.excluded = build_steps(m)
        self.default_steps = [s for s in self.steps if s.default and not s.stub]
        self._single_cache = {}

    # -- R6 ------------------------------------------------------------------

    def restricted(self, cls: str) -> "Derivation":
        """The same engine over only the steps whose class implies `cls`."""
        if not hasattr(self, "_restricted"):
            self._restricted = {}
        if cls not in self._restricted:
            sub = Derivation(self.m, self.policy)
            sub.steps = [s for s in self.steps if self.m.implies(s.cls, cls)]
            sub.default_steps = [s for s in self.default_steps if self.m.implies(s.cls, cls)]
            self._restricted[cls] = sub
        return self._restricted[cls]

    def strongest(self, start, target: str, include_idealised: bool):
        """R6. The strongest class any derivation of `target` has, which can
        be stronger than the minimal-depth one's: (class, depth, edges)."""
        for c in COMPOSABLE_CLASSES:
            sub = self.restricted(c)
            cl = sub.closure(start, include_idealised)
            if target in cl.facts:
                return c, cl.facts[target].depth, sub.tree_edges(cl, target)
        return "unstated", None, None

    def chain_class(self, classes) -> str:
        classes = list(classes)
        for c in COMPOSABLE_CLASSES:
            if all(self.m.implies(x, c) for x in classes):
                return c
        return "unstated"

    # -- R5 ------------------------------------------------------------------

    def composition(self, step: Step, hyp_facts) -> tuple[bool, str]:
        """May `step` fire on these hypothesis facts? Returns (ok, outcome)."""
        if not any(f.scoped for f in hyp_facts):
            return True, "ok"
        if self.m.implies(step.cls, RELATIVIZING):
            return True, "ok"
        if step.cls == "unstated" and self.policy == "caveat":
            return True, "caveat"
        return False, f"class {step.cls} after an idealised-model step"

    def candidate(self, step: Step, hyp_facts, depth: int) -> Fact | None:
        ok, outcome = self.composition(step, hyp_facts)
        if not ok:
            return None
        models = frozenset().union(*(f.models for f in hyp_facts))
        if step.model != "standard":
            models |= {step.model}
        scoped = any(f.scoped for f in hyp_facts) or step.model in IDEALISED_MODELS or step.model == UNKNOWN_MODEL
        # A given fact's chain is fully-black-box, the identity of the meet.
        chain = self.chain_class([step.cls] + [f.chain for f in hyp_facts])
        caveats = tuple(sorted(set().union(*(f.caveats for f in hyp_facts)) | ({step.edge} if outcome == "caveat" else set())))
        return Fact(step.concl, depth, step, models, scoped, chain, caveats)

    @staticmethod
    def preference(f: Fact):
        """R7 tie-break among candidates for one fact at one layer."""
        return (len(f.models), CLASS_RANK[f.chain], len(f.caveats), f.step.edge, f.step.reverse)

    # -- forward chaining ----------------------------------------------------

    def _layers(self, known: dict, steps: list, scoped_only: bool, blocked: dict | None):
        """Layered Horn chaining. A step fires at layer k when every hypothesis
        is known with depth < k; each new fact takes the preferred candidate
        among the steps firing at its first layer, and never changes after."""
        k = 0
        while True:
            k += 1
            cands = {}
            for s in steps:
                if s.concl in known:
                    continue
                hf = [known.get(h) for h in s.hyps]
                if any(f is None or f.depth >= k for f in hf):
                    continue
                if scoped_only and not (any(f.scoped for f in hf) or not s.default or s.stub):
                    continue  # would be clean: phase 1 already decided it
                c = self.candidate(s, hf, k)
                if c is None:
                    if blocked is not None:
                        blocked.setdefault(s.sort_key, (s, self.composition(s, hf)[1], [f.id for f in hf if f.scoped]))
                    continue
                if s.concl not in cands or self.preference(c) < self.preference(cands[s.concl]):
                    cands[s.concl] = c
            known.update(cands)
            if not cands and k > max((f.depth for f in known.values()), default=0):
                return

    def closure(self, start, include_idealised: bool = False) -> Closure:
        start = tuple(sorted(set(start)))
        out = Closure(start, include_idealised)
        # Every start is a given fact. A model node given as a start (R4) is
        # not itself model-scoped: the edges leaving it are the idealised
        # steps, and what they conclude is scoped. No default step has a model
        # node as a hypothesis, so in the default mode it derives nothing.
        known = {s: Fact(s, 0, None, frozenset(), False, "fully-black-box") for s in start}
        # Phase 1: default models; every fact it adds is clean (R4).
        self._layers(known, self.default_steps, False, None)
        if include_idealised:
            # Phase 2: every eligible step; every fact it adds is model-scoped,
            # and clean facts are never replaced (R5).
            self._layers(known, self.steps, True, out.blocked)
        out.facts = known
        return out

    def single(self, oid: str, include_idealised: bool = False) -> Closure:
        key = (oid, include_idealised)
        if key not in self._single_cache:
            self._single_cache[key] = self.closure([oid], include_idealised)
        return self._single_cache[key]

    # -- proof trees (R7) ----------------------------------------------------

    def tree(self, cl: Closure, target: str) -> list:
        """Depth-first, hypotheses in the edge's order. A fact already shown is
        a reference, never a second copy of its subtree."""
        rows, seen = [], set()

        def walk(fid, level):
            f = cl.facts[fid]
            ref = fid in seen
            seen.add(fid)
            rows.append({"fact": fid, "level": level, "ref": ref, "given": f.step is None,
                         "edge": None if f.step is None else f.step.edge,
                         "reverse": False if f.step is None else f.step.reverse})
            if not ref and f.step is not None:
                for h in f.step.hyps:
                    walk(h, level + 1)

        walk(target, 0)
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
            if r["given"]:
                lines.append(f"{pad}{name}  (given)")
            elif r["ref"]:
                lines.append(f"{pad}{name}  (shown above)")
            else:
                s = cl.facts[r["fact"]].step
                red = self.m.reductions[s.edge]
                rev = ", reverse of the equivalence" if s.reverse else ""
                lines.append(f"{pad}{name}  <= {s.edge} [{s.cls}, {s.model}{rev}] {red['title']}")
        return "\n".join(lines)

    # -- barriers ------------------------------------------------------------

    def recorded_barriers(self, hyps, concl) -> list:
        hs = set(hyps)
        return sorted(b["id"] for b in self.m.barriers.values()
                      if set(b["hypotheses"]) == hs and b["conclusion"] == concl)

    # -- R12: derived barriers -----------------------------------------------

    def _side_steps(self, cls: str) -> list:
        prim = DERIVED_BARRIER_NODE_TYPE
        return [s for s in self.steps
                if len(s.hyps) == 1 and not s.stub
                and s.model == DERIVED_BARRIER_SIDE_MODEL
                and self.m.implies(s.cls, cls)
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

    def derived_barriers(self) -> list:
        prim = DERIVED_BARRIER_NODE_TYPE
        out = []
        for bid in sorted(self.m.barriers):
            b = self.m.barriers[bid]
            if len(b["hypotheses"]) != 1:
                continue
            x, y = b["hypotheses"][0], b["conclusion"]
            if self.m.type(x) != prim or self.m.type(y) != prim:
                continue
            for cons in b["consequences"]:
                c = cons.get("class") or b["class"]
                if c not in COMPOSABLE_CLASSES:
                    continue
                side = self._side_steps(c)
                ups = self._reach(x, side, True)  # x =>* a'
                downs = self._reach(y, side, False)  # b' =>* y
                for a2, up in ups.items():
                    for b2, down in downs.items():
                        if (a2, b2) == (x, y) or a2 == b2:
                            continue
                        out.append({
                            "barrier": bid, "hypothesis": a2, "conclusion": b2, "class": c,
                            "consequence": {"kind": cons["kind"], "target": cons.get("target", "")},
                            "up": up, "down": list(reversed(down)),
                            "strength": b["strength"], "conditionalOn": b["conditionalOn"],
                            "circumventedBy": b.get("circumventedBy", []),
                        })
        return out

    def derived_barriers_for(self, a: str, b: str, all_derived: list) -> list:
        """Derived barriers on (a, b), minus those a recorded barrier on the
        same pair already covers (recorded class broader than or equal to)."""
        recorded = [self.m.barriers[x] for x in self.recorded_barriers([a], b)]
        res = []
        for d in all_derived:
            if d["hypothesis"] != a or d["conclusion"] != b:
                continue
            d = dict(d)
            d["redundantWith"] = sorted(r["id"] for r in recorded if self.m.implies(d["class"], r["class"]))
            res.append(d)
        res.sort(key=lambda d: (bool(d["redundantWith"]), CLASS_RANK.get(d["class"], 9),
                                len(d["up"]) + len(d["down"]), d["barrier"]))
        return res

    # -- queries (R8-R10) ----------------------------------------------------

    def query(self, start, target: str, include_idealised: bool = False, all_derived=None) -> dict:
        m = self.m
        start = sorted(set(start))
        for oid in start + [target]:
            if oid not in m.objects:
                return {"supported": False, "reason": f"unknown object {oid}"}
            if m.type(oid) in EXCLUDED_TYPES:
                return {"supported": False, "reason":
                        f"{oid} is a complexity class; classes are related by containment, not derived"}
        cl = self.closure(start, include_idealised)
        ans = {"supported": True, "start": start, "target": target,
               "includeIdealised": include_idealised,
               "recordedBarriers": self.recorded_barriers(start, target),
               "reverseBarriers": (self.recorded_barriers([target], start[0]) if len(start) == 1 else [])}
        model_starts = [s for s in start if m.model_of_node(s)]
        if model_starts and not include_idealised:
            ans["modelStart"] = model_starts
        f = cl.facts.get(target)
        if f is not None:
            edges = self.tree_edges(cl, target)
            ans.update({
                "derivable": True, "depth": f.depth, "models": sorted(f.models),
                "scoped": f.scoped, "chainClass": f.chain, "caveats": list(f.caveats),
                "edges": edges, "reductionCount": len(edges),
                "reverseSteps": sorted(e for e, rev in self.tree_steps(cl, target) if rev),
                "given": f.step is None,
                # A barrier on the same pair whose class the chain's class
                # implies would make the record inconsistent. Never expected;
                # the corpus test asserts it stays empty.
                "conflictingBarriers": [b for b in ans["recordedBarriers"]
                                        if m.implies(f.chain, m.barriers[b]["class"])],
            })
            if f.step is not None:
                sc, sd, se = self.strongest(start, target, include_idealised)
                if sc != f.chain:
                    ans["strongest"] = {"chainClass": sc, "depth": sd, "edges": se}
            return ans
        ans["derivable"] = False
        # Would the toggle find it? (R4)
        if not include_idealised:
            alt = self.closure(start, True).facts.get(target)
            if alt is not None:
                ans["withIdealised"] = {"depth": alt.depth, "models": sorted(alt.models)}
        # What R5 refused on the way (explanation only).
        ans["refusedSteps"] = self.refused_on_path(start, target, include_idealised)
        # R9: host and variants.
        ans["nearMisses"] = self.near_misses(start, cl, target, include_idealised)
        # R12.
        if all_derived is not None and len(start) == 1:
            ans["derivedBarriers"] = [self.derived_id(d) for d in self.derived_barriers_for(start[0], target, all_derived)]
            ans["derivedReverseBarriers"] = [self.derived_id(d) for d in self.derived_barriers_for(target, start[0], all_derived)]
        # R10.
        comps, total = self.completions(start, target, cl, include_idealised)
        ans["completions"] = comps
        ans["completionCount"] = total
        ans["footer"] = FOOTER
        return ans

    @staticmethod
    def derived_id(d: dict) -> dict:
        return {"barrier": d["barrier"], "class": d["class"],
                "up": [e for e, _ in d["up"]], "down": [e for e, _ in d["down"]],
                "redundantWith": d.get("redundantWith", [])}

    def refused_on_path(self, start, target, include_idealised) -> list:
        """Steps R5 refused on the derivation the rule-free engine would give."""
        if not include_idealised:
            return []
        relaxed = Derivation(self.m, "allow-all")
        relaxed.composition = lambda step, hf: (True, "ok")
        rcl = relaxed.closure(start, True)
        if target not in rcl.facts:
            return []
        out = []
        for e, rev in relaxed.tree_steps(rcl, target):
            s = next(s for s in self.steps if s.edge == e and s.reverse == rev)
            hf_relaxed = [rcl.facts[h] for h in s.hyps]
            if any(f.scoped for f in hf_relaxed) and not self.m.implies(s.cls, RELATIVIZING) \
                    and not (s.cls == "unstated" and self.policy == "caveat"):
                out.append({"edge": e, "class": s.cls,
                            "scopedHypotheses": [f.id for f in hf_relaxed if f.scoped]})
        return out

    def near_misses(self, start, cl: Closure, target: str, include_idealised: bool) -> dict:
        """R9. Hosts and variants are related by page structure, never by an
        edge, so none of this is a derivation; it is shown as a hint."""
        m = self.m
        o = m.objects[target]
        target_variants = sorted(v for v, vo in m.objects.items()
                                 if vo["kind"] == "variant" and vo.get("of") == target
                                 and v in cl.facts and v not in start)
        target_host = o.get("of") if o["kind"] == "variant" and o.get("of") in cl.facts else None
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
        m = self.m
        found = {}
        for z in sorted(m.objects):
            if z == target or z in cl.facts or m.type(z) not in COMPLETION_TYPES or m.model_of_node(z):
                continue
            if target in self.single(z, include_idealised).facts:
                continue  # z alone suffices; that is implied-by, not a completion
            zc = self.closure(list(start) + [z], include_idealised)
            f = zc.facts.get(target)
            if f is None:
                continue
            found[z] = (f, self.tree_edges(zc, target))
        # Keep the weakest: drop z when another completion z2 follows from z
        # and z does not follow from z2.
        keep = []
        for z in found:
            zf = self.single(z, include_idealised).facts
            dominated = any(z2 != z and z2 in zf and z not in self.single(z2, include_idealised).facts
                            for z2 in found)
            if not dominated:
                keep.append(z)
        keep.sort(key=lambda z: (found[z][0].depth, len(found[z][0].models),
                                 CLASS_RANK[found[z][0].chain], len(found[z][1]), z))
        rows = [{"add": z, "depth": found[z][0].depth, "models": sorted(found[z][0].models),
                 "chainClass": found[z][0].chain, "edges": found[z][1]} for z in keep[:COMPLETION_CAP]]
        return rows, len(keep)

    # -- R11: backward closure -----------------------------------------------

    def implied_by(self, target: str, include_idealised: bool = False) -> dict:
        m = self.m
        objs = [o for o in sorted(m.objects)
                if m.type(o) not in EXCLUDED_TYPES and not m.model_of_node(o) and o != target]
        singles = []
        for a in objs:
            f = self.single(a, include_idealised).facts.get(target)
            if f is not None:
                singles.append({"from": a, "depth": f.depth, "models": sorted(f.models),
                                "chainClass": f.chain})
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
            if target not in cl.facts:
                continue
            g = self._joining_edge(cl, target, cover[a], cover[b])
            groups.setdefault(g, []).append([a, b])
        group_rows = []
        for g, ps in sorted(groups.items(), key=lambda t: (-len(t[1]), t[0])):
            group_rows.append({"edge": g, "hypotheses": list(m.reductions[g]["hypotheses"]),
                               "pairCount": len(ps), "pairs": ps[:IMPLIED_BY_GROUP_CAP]})
        # Conjunctions of three or more are shown as the edge, not enumerated.
        larger = []
        for s in conj:
            if len(s.hyps) < 3 or s.edge in groups:
                continue
            if any(target in self.single(h, include_idealised).facts for h in s.hyps):
                continue
            if target in self.closure(list(s.hyps), include_idealised).facts:
                larger.append({"edge": s.edge, "hypotheses": list(s.hyps)})
        singles.sort(key=lambda s: (s["depth"], len(s["models"]), s["from"]))
        return {"target": target, "includeIdealised": include_idealised,
                "singleCount": len(singles), "singles": singles[:IMPLIED_BY_SINGLE_CAP],
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
            f = cl.facts[fid]
            if f.step is None:
                continue
            hs = set(f.step.hyps)
            if len(hs) > 1 and not hs <= ca and not hs <= cb:
                return f.step.edge
            queue.extend(f.step.hyps)
        return "?"


# ---------------------------------------------------------------------------
# Invariants (the corpus test asserts these whatever the commit)
# ---------------------------------------------------------------------------


def invariants(dv: Derivation, all_derived: list) -> dict:
    m = dv.m
    res = {}
    eligible = {s.edge for s in dv.steps}
    bad = sorted(e for e in eligible if m.reductions[e]["kind"] == "inclusion"
                 or m.reductions[e].get("heuristic")
                 or any(m.type(x) in EXCLUDED_TYPES for x in m.reductions[e]["hypotheses"] + [m.reductions[e]["conclusion"]]))
    res["noIneligibleEdges"] = not bad
    leaks, conflicts = [], []
    starts = sorted(o for o in m.objects if m.type(o) not in EXCLUDED_TYPES)
    for a in starts:
        cl = dv.single(a, False)
        for fid, f in cl.facts.items():
            if f.models - DEFAULT_MODELS or f.scoped and f.step is not None:
                leaks.append((a, fid))
            if f.step is None:
                continue
            # A derived chain whose class a recorded barrier on the same pair rules out.
            for bid in dv.recorded_barriers([a], fid):
                b = m.barriers[bid]
                if m.implies(f.chain, b["class"]) and f.depth > 0:
                    conflicts.append((a, fid, bid, f.chain))
    res["defaultHasNoIdealisedModels"] = not leaks
    res["noChainContradictsRecordedBarrier"] = not conflicts
    res["romDoesNotReachOT"] = all("ot" not in dv.closure(["rom"], inc).facts for inc in (False, True))
    res["romDoesNotReachKE"] = all("ke" not in dv.closure(["rom"], inc).facts for inc in (False, True))
    # A derived barrier must not be contradicted by a recorded reduction on its edge.
    dconf = []
    for d in all_derived:
        for r in m.reductions.values():
            if r["hypotheses"] == [d["hypothesis"]] and r["conclusion"] == d["conclusion"] \
                    and m.implies(r["class"], d["class"]) and not r.get("heuristic"):
                dconf.append((d["barrier"], r["id"]))
    res["noDerivedBarrierContradictsRecordedReduction"] = not dconf
    res["_detail"] = {"ineligible": bad, "leaks": leaks[:10], "conflicts": conflicts[:10],
                      "derivedConflicts": dconf[:10]}
    return res


# ---------------------------------------------------------------------------
# Golden file
# ---------------------------------------------------------------------------

#: (id, start, target, includeIdealised, fields asserted even when the
#: manifest differs from the golden one). Chosen to pin every rule.
GOLDEN_QUERIES = [
    # R6, R7: the worked examples.
    ("ddh-ot", ["ddh"], "ot", False, ["derivable"]),
    ("owf-kem-pke", ["owf", "kem"], "pke", False, ["derivable"]),
    ("owf-io-pke", ["owf", "io"], "pke", False, ["derivable"]),
    ("jls21-deniable-encryption", ["sxdh", "lwe", "lpn", "prg-in-nc0"], "deniable-encryption", False, []),
    ("gapsvp-pke", ["gapsvp"], "pke", False, []),
    ("tdp-nizk", ["tdp"], "nizk", False, []),
    ("oihf-mpc", ["oblivious-interactive-hash-function"], "mpc", False, []),
    ("ddh-invertible-prf", ["ddh"], "invertible-prf", False, []),
    # R1: equivalences both ways; a heuristic edge never fires.
    ("rabin-ot-mpc", ["rabin-ot"], "mpc", False, []),
    ("ot-rabin-ot", ["ot"], "rabin-ot", False, []),
    ("ntru-pke", ["ntru"], "pke", False, []),
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
    ("pke-ot", ["pke"], "ot", False, ["derivable"]),
    ("oihf-ot", ["oblivious-interactive-hash-function"], "ot", False, []),
    ("owf-ot", ["owf"], "ot", False, ["derivable"]),
    ("owf-crhf", ["owf"], "crhf", False, ["derivable"]),
    ("com-pke", ["com"], "pke", False, ["derivable"]),
    ("ot-tdp", ["ot"], "tdp", False, ["derivable"]),
    # R9, R10: host and variant hints; completions.
    ("lpn-pke", ["lpn"], "pke", False, []),
    ("lwe-ring-lwe", ["lwe"], "ring-lwe", False, ["derivable"]),
    ("ddh-she", ["ddh"], "somewhat-homomorphic-encryption", False, []),
    ("ddh-sparse-lpn-she", ["ddh", "sparse-lpn"], "somewhat-homomorphic-encryption", False, []),
]


def golden(dv: Derivation, wiki_commit: str) -> dict:
    all_derived = dv.derived_barriers()
    records = []
    for qid, start, target, inc, stable in GOLDEN_QUERIES:
        if target not in dv.m.objects or any(s not in dv.m.objects for s in start):
            continue
        a = dv.query(start, target, inc, all_derived)
        exp = {"supported": a["supported"]}
        if a["supported"]:
            exp["derivable"] = a["derivable"]
            exp["recordedBarriers"] = a["recordedBarriers"]
            exp["reverseBarriers"] = a["reverseBarriers"]
            if a["derivable"]:
                for k in ("depth", "models", "scoped", "chainClass", "edges", "reverseSteps", "caveats",
                          "conflictingBarriers"):
                    exp[k] = a[k]
                if "strongest" in a:
                    exp["strongest"] = a["strongest"]
            else:
                exp["completions"] = [c["add"] for c in a["completions"][:5]]
                exp["completionCount"] = a["completionCount"]
                exp["refusedSteps"] = [r["edge"] for r in a["refusedSteps"]]
                exp["nearMisses"] = a["nearMisses"]
                if "withIdealised" in a:
                    exp["withIdealised"] = a["withIdealised"]
                if "derivedBarriers" in a:
                    exp["derivedBarriers"] = [d["barrier"] for d in a["derivedBarriers"] if not d["redundantWith"]]
                    exp["derivedReverseBarriers"] = [d["barrier"] for d in a["derivedReverseBarriers"] if not d["redundantWith"]]
                if "modelStart" in a:
                    exp["modelStart"] = a["modelStart"]
        records.append({"id": qid, "start": start, "target": target,
                        "includeIdealised": inc, "stable": stable, "expect": exp})
    closures = {}
    for o in ["owf", "ddh", "lwe", "dcr", "fac", "rsa", "gapsvp", "dlog", "rom", "ggm", "pke", "ot"]:
        if o in dv.m.objects:
            closures[o] = {"default": len(dv.single(o, False).facts) - 1,
                           "all": len(dv.single(o, True).facts) - 1}
    ib = {}
    for t in ["pke", "ot"]:
        r = dv.implied_by(t, False)
        ib[t] = {"singleCount": r["singleCount"], "pairCount": r["pairCount"],
                 "groups": {g["edge"]: g["pairCount"] for g in r["groups"]}}
    inv = invariants(dv, all_derived)
    return {
        "about": ("Expected answers of CCwiki's derivation engine on one wiki manifest. "
                  "Written by scripts/derivations_reference.py; spec in plans/derivations.md. "
                  "Exact when manifestSHA256 matches the clone's .reductions/relations.json; "
                  "otherwise only each record's `stable` fields and `invariants` are asserted, "
                  "and only while every count is within `tolerance` of `counts`."),
        "generator": "scripts/derivations_reference.py",
        "wikiCommit": wiki_commit,
        "manifestSHA256": dv.m.sha256,
        "counts": dv.m.counts(),
        "tolerance": 0.10,
        "policy": {
            "defaultModels": sorted(DEFAULT_MODELS),
            "idealisedModels": sorted(IDEALISED_MODELS),
            "modelNodes": MODEL_NODES,
            "composableClasses": list(COMPOSABLE_CLASSES),
            "unstatedAfterIdealised": dv.policy,
            "completionCap": COMPLETION_CAP,
        },
        "eligibleSteps": {"default": len(dv.default_steps), "all": len(dv.steps)},
        "excluded": {k: len(v) for k, v in sorted(dv.excluded.items())},
        "closureSizes": closures,
        "impliedBy": ib,
        "derivedBarrierCount": len(all_derived),
        "invariants": {k: v for k, v in inv.items() if not k.startswith("_")},
        "queries": records,
    }


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------


def parse_query(q: str):
    lhs, rhs = q.split("=>")
    return [s.strip() for s in lhs.split(",") if s.strip()], rhs.strip()


def print_answer(dv: Derivation, start, target, inc, all_derived):
    a = dv.query(start, target, inc, all_derived)
    mode = "all models" if inc else "default models"
    print(f"\n== {{{', '.join(start)}}} => {target}   [{mode}]")
    if not a["supported"]:
        print("  unsupported:", a["reason"])
        return a
    if a["derivable"]:
        cl = dv.closure(start, inc)
        print(f"  derivable: depth {a['depth']}, chain class {a['chainClass']}, "
              f"models {a['models'] or ['standard']}, derived by CCwiki from {a['reductionCount']} recorded reductions")
        if a["caveats"]:
            print("  caveats:", a["caveats"])
        if a.get("strongest"):
            st = a["strongest"]
            print(f"  strongest class over all derivations: {st['chainClass']} at depth {st['depth']} via {st['edges']}")
        for line in dv.render(cl, target).splitlines():
            print("   ", line)
        if a["recordedBarriers"]:
            print("  recorded barriers on this pair (context):", a["recordedBarriers"])
    else:
        print("  no derivation")
        for k in ("modelStart", "recordedBarriers", "reverseBarriers", "withIdealised", "refusedSteps"):
            if a.get(k):
                print(f"  {k}: {a[k]}")
        nm = {k: v for k, v in a["nearMisses"].items() if v}
        if nm:
            print(f"  nearMisses: {nm}")
        for k in ("derivedBarriers", "derivedReverseBarriers"):
            for d in a.get(k, []):
                tag = f" (covered by {d['redundantWith']})" if d["redundantWith"] else ""
                print(f"  {k}: {d['barrier']} [{d['class']}] up {d['up']} down {d['down']}{tag}")
        print(f"  completions ({a['completionCount']}):",
              [(c["add"], c["depth"], c["chainClass"], c["models"]) for c in a["completions"]])
        print("  footer:", a["footer"])
    return a


def report(dv: Derivation):
    m = dv.m
    t0 = time.perf_counter()
    dv2 = Derivation(m)
    t_build = time.perf_counter() - t0
    print(f"manifest sha256 {m.sha256}")
    print("counts", m.counts())
    print(f"eligible steps: default {len(dv.default_steps)}, all {len(dv.steps)}; excluded",
          {k: len(v) for k, v in sorted(dv.excluded.items())})

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
    grew = sorted((o for o, s in nonempty.items() if s[1] != s[0]), key=lambda o: sizes[o][0] - sizes[o][1])
    print(f"objects whose closure grows with the toggle: {len(grew)}")
    for o in grew[:20]:
        print(f"  {o:40s} {sizes[o][0]:3d} -> {sizes[o][1]:3d}")
    maxd = max((f.depth for o in starts for f in dv2.single(o).facts.values()), default=0)
    print("max default depth:", maxd)

    all_derived = dv.derived_barriers()
    pairs = {(d["hypothesis"], d["conclusion"]) for d in all_derived}
    recorded_pairs = {(b["hypotheses"][0], b["conclusion"]) for b in m.barriers.values() if len(b["hypotheses"]) == 1}
    print(f"\nderived barriers: {len(all_derived)} records, {len(pairs)} pairs, "
          f"{len(pairs - recorded_pairs)} not recorded, from "
          f"{len({d['barrier'] for d in all_derived})} barriers")

    t0 = time.perf_counter()
    for start, target, inc in [
        (["ddh"], "ot", False), (["owf", "kem"], "pke", False), (["owf"], "pke", False),
        (["pke"], "ot", False), (["fac"], "pke", False), (["fac"], "pke", True),
        (["rom"], "ot", False), (["rom"], "ot", True), (["rom"], "mpc", True),
        (["lpn"], "pke", False), (["dlog"], "cdh", True), (["ggm"], "ot", True),
    ]:
        print_answer(dv, start, target, inc, all_derived)
    print(f"\n(worked examples {1000*(time.perf_counter()-t0):.0f} ms including completions)")

    for t in ("pke", "ot"):
        t0 = time.perf_counter()
        r = dv.implied_by(t, False)
        dt = time.perf_counter() - t0
        print(f"\nimplied-by {t}: {r['singleCount']} single objects, {r['pairCount']} minimal pairs ({dt*1000:.0f} ms)")
        print("  singles:", [s["from"] for s in r["singles"]])
        for g in r["groups"]:
            print(f"  via {g['edge']} {g['hypotheses']}: {g['pairCount']} pairs, e.g. {g['pairs'][:4]}")

    # R5 policy comparison.
    print("\nR5 policy: unstated after an idealised step")
    cav = Derivation(m, "caveat")
    for mn in ("rom", "ggm", "agm", "structured-generic-group-model"):
        if mn not in m.objects:
            continue
        r = set(dv.closure([mn], True).facts) - {mn}
        c = set(cav.closure([mn], True).facts) - {mn}
        print(f"  {mn}: refuse {len(r)} {sorted(r)}")
        print(f"  {' '*len(mn)}  caveat adds {sorted(c - r)}")
    lost = {}
    for o in starts:
        r = set(dv.closure([o], True).facts)
        c = set(cav.closure([o], True).facts)
        if c - r:
            lost[o] = sorted(c - r)
    print(f"  facts the caveat policy would add across all single starts: "
          f"{sum(len(v) for v in lost.values())} from {len(lost)} starts")
    for o, v in sorted(lost.items()):
        print(f"    {o}: {v}")

    inv = invariants(dv, all_derived)
    print("\ninvariants:", {k: v for k, v in inv.items() if not k.startswith("_")})
    if not all(v for k, v in inv.items() if not k.startswith("_")):
        print("  detail:", inv["_detail"])


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("relations", help="path to .reductions/relations.json")
    p.add_argument("--query", action="append", default=[], help='"a, b => c"')
    p.add_argument("--all-models", action="store_true", help="include idealised and 'other' models (R4)")
    p.add_argument("--implied-by", action="append", default=[])
    p.add_argument("--report", action="store_true")
    p.add_argument("--golden", help="write the golden JSON here")
    p.add_argument("--wiki-commit", default="", help="the clone's HEAD, recorded in the golden file")
    p.add_argument("--policy", choices=["refuse", "caveat"], default=UNSTATED_AFTER_IDEALISED)
    a = p.parse_args(argv)

    dv = Derivation(Manifest(a.relations), a.policy)
    all_derived = None
    for q in a.query:
        all_derived = all_derived if all_derived is not None else dv.derived_barriers()
        start, target = parse_query(q)
        print_answer(dv, start, target, a.all_models, all_derived)
    for t in a.implied_by:
        print(json.dumps(dv.implied_by(t, a.all_models), indent=1))
    if a.report:
        report(dv)
    if a.golden:
        g = golden(dv, a.wiki_commit)
        with open(a.golden, "w") as f:
            json.dump(g, f, indent=1, sort_keys=False, ensure_ascii=False)
            f.write("\n")
        print(f"wrote {a.golden}: {len(g['queries'])} queries", file=sys.stderr)


if __name__ == "__main__":
    main()
