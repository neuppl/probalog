"""The benchmark models, independent of any system's syntax.

A model is facts (pred, args, p), rules (head, body) over atoms
(pred, args), one query atom, and Souffle column types per predicate.
Variables in rules are `Var`; anything else is a constant. Predicate
names are written as probalog spells them; each emitter adapts them.
"""

from dataclasses import dataclass


class Var(str):
    pass


@dataclass
class Model:
    facts: list
    rules: list
    query: tuple
    types: dict


def atom(pred, *args):
    return (pred, list(args))


def rule(head, *body):
    return (head, list(body))


x, y, z, z1, z2 = (Var(v) for v in ("x", "y", "z", "z1", "z2"))
u, v, o, b, f, p, c = (Var(n) for n in ("u", "v", "o", "b", "f", "p", "c"))

REACH = [rule(atom("Reach", x, y), atom("Edge", x, y)),
         rule(atom("Reach", x, z), atom("Reach", x, y), atom("Edge", y, z))]


def startup():
    return Model([("Edge", [0, 1], 0.5)], REACH, atom("Reach", 0, 1),
                 {"Edge": ["number"] * 2, "Reach": ["number"] * 2})


def ring(n, prob=0.99):
    facts = [("Edge", [i, (i + 1) % n], prob) for i in range(n)]
    return Model(facts, REACH, atom("Reach", 0, n // 2),
                 {"Edge": ["number"] * 2, "Reach": ["number"] * 2})


def chordring(n, chord=3, prob=0.85):
    facts = [("Edge", [i, (i + 1) % n], prob) for i in range(n)]
    facts += [("Edge", [i, (i + chord) % n], prob) for i in range(n)]
    return Model(facts, REACH, atom("Reach", 0, n // 2),
                 {"Edge": ["number"] * 2, "Reach": ["number"] * 2})


def dag(layers, width, prob=0.9):
    def node(l, i):
        return f"n{l}_{i}"
    edges = [("src", node(0, j)) for j in range(width)]
    for l in range(layers - 1):
        edges += [(node(l, a), node(l + 1, b2)) for a in range(width) for b2 in range(width)]
    edges += [(node(layers - 1, j), "sink") for j in range(width)]
    return Model([("Edge", [s, t], prob) for s, t in edges],
                 [rule(atom("Path", x, y), atom("Edge", x, y)),
                  rule(atom("Path", x, z), atom("Path", x, y), atom("Edge", y, z))],
                 atom("Path", "src", "sink"),
                 {"Edge": ["symbol"] * 2, "Path": ["symbol"] * 2})


def smokers(n, pstress=0.2, pinf=0.3):
    facts = [("Stress", [f"p{i}"], pstress) for i in range(n)]
    for i in range(n):
        j = (i + 1) % n
        facts += [("Friend", [f"p{i}", f"p{j}"], 1), ("Friend", [f"p{j}", f"p{i}"], 1),
                  ("Influences", [f"p{i}", f"p{j}"], pinf),
                  ("Influences", [f"p{j}", f"p{i}"], pinf)]
    return Model(facts,
                 [rule(atom("Smokes", x), atom("Stress", x)),
                  rule(atom("Smokes", x), atom("Friend", x, y), atom("Smokes", y),
                       atom("Influences", y, x))],
                 atom("Smokes", "p0"),
                 {"Stress": ["symbol"], "Friend": ["symbol"] * 2,
                  "Influences": ["symbol"] * 2, "Smokes": ["symbol"]})


def sg(depth, branch=2, prob=0.9):
    facts, frontier = [], ["r"]
    for _ in range(depth):
        nxt = []
        for parent in frontier:
            for k in range(branch):
                child = f"{parent}{k}"
                facts.append(("Up", [child, parent], prob))
                nxt.append(child)
        frontier = nxt
    facts.append(("Flat", ["r", "r"], prob))
    return Model(facts,
                 [rule(atom("Down", p, c), atom("Up", c, p)),
                  rule(atom("SameGen", x, y), atom("Flat", x, y)),
                  rule(atom("SameGen", x, y), atom("Up", x, z1), atom("SameGen", z1, z2),
                       atom("Down", z2, y))],
                 atom("SameGen", frontier[0], frontier[-1]),
                 {"Up": ["symbol"] * 2, "Flat": ["symbol"] * 2,
                  "Down": ["symbol"] * 2, "SameGen": ["symbol"] * 2})


def pointsto(n, prob=0.99):
    facts = [("AddressOf", ["v0", "o0"], prob)]
    for i in range(n):
        facts += [("Assign", [f"v{i+1}", f"v{i}"], prob),
                  ("AddressOf", [f"w{i}", f"o{i+1}"], prob),
                  ("Store", [f"v{i}", "f", f"w{i}"], prob),
                  ("Load", [f"u{i}", f"v{i+1}", "f"], prob)]
    return Model(facts,
                 [rule(atom("VarPointsTo", v, o), atom("AddressOf", v, o)),
                  rule(atom("VarPointsTo", v, o), atom("Assign", v, u), atom("VarPointsTo", u, o)),
                  rule(atom("VarPointsTo", v, o), atom("Load", v, u, f), atom("VarPointsTo", u, b),
                       atom("FieldPointsTo", b, f, o)),
                  rule(atom("FieldPointsTo", b, f, o), atom("Store", u, f, v),
                       atom("VarPointsTo", u, b), atom("VarPointsTo", v, o))],
                 atom("VarPointsTo", f"v{n}", "o0"),
                 {"AddressOf": ["symbol"] * 2, "Assign": ["symbol"] * 2,
                  "Store": ["symbol"] * 3, "Load": ["symbol"] * 3,
                  "VarPointsTo": ["symbol"] * 2, "FieldPointsTo": ["symbol"] * 3})


# Each ladder runs from sizes every system finishes to past where
# probalog times out, with at least three steps where probalog takes 1-10s.
SUITES = {
    "startup": dict(gen=startup, ladder=[()]),
    "ring": dict(gen=ring, ladder=[(n,) for n in (250, 500, 1000, 2000, 4000, 6000, 8000, 11000, 16000)]),
    "chordring": dict(gen=chordring, ladder=[(n,) for n in (12, 20, 30, 40, 50, 60, 70, 80)]),
    "dag": dict(gen=dag, ladder=[(6, w) for w in (3, 4, 5, 6)] + [(l, 6) for l in (7, 8, 9, 10, 12)]),
    "smokers": dict(gen=smokers, ladder=[(n,) for n in (20, 40, 60, 80, 100, 130, 160, 190)]),
    "sg": dict(gen=sg, ladder=[(d,) for d in (6, 8, 10, 11, 12, 13, 14, 15)]),
    "pointsto": dict(gen=pointsto, ladder=[(n,) for n in (50, 150, 300, 600, 1000, 1700, 2500, 4000, 6000, 9000)]),
}
