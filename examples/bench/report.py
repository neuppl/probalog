#!/usr/bin/env python3
"""Comparisons derived from data.json.

    report.py [DATA_JSON] [--previous PATH] [--table]

Agreement: every system's answer against probalog's on the same case
(Souffle against probalog with every fact certain). Speed: each case's
times, and the largest size each system finished. Regressions: probalog's
times against the previous data.json (by default the committed one),
counting only runs of at least 1s on both sides.

In CI this prints annotations and writes the tables to
$GITHUB_STEP_SUMMARY; with --table it prints the tables instead. Exits 1
if the tests failed, the ground truth disagreed, or probalog disagreed
with ProbLog, PITA, Souffle or its in-process run.
"""

import argparse
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SYSTEMS = ["probalog", "probalog-certain", "problog", "pita", "souffle", "psouffle",
           "engine"]
# (system, reference system) pairs whose answers must match, and whether a
# mismatch fails the job. PSouffle is known to be wrong on cyclic programs.
CHECKS = [("problog", "probalog", True), ("pita", "probalog", True),
          ("psouffle", "probalog", False), ("souffle", "probalog-certain", True),
          ("engine", "probalog", True)]
REGRESSION = 0.15
REGRESSION_FLOOR = 1.0


def same(a, b):
    return abs(a - b) <= 1e-6 * max(abs(a), abs(b)) + 1e-300


def cases(runs):
    out = {}
    for r in runs:
        out.setdefault((r["suite"], tuple(r["size"])), {})[r["system"]] = r
    return out


def cell(r):
    if r is None:
        return ""
    if r["status"] == "ok":
        return f"{r['seconds']:.2f}"
    return "—" if r["status"] == "not run" else r["status"]


def table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + " --- |" * len(header)]
    out += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return "\n".join(out)


def previous_data(path):
    try:
        if path:
            with open(path) as f:
                return json.load(f)
        text = subprocess.run(["git", "show", "HEAD:data.json"], capture_output=True,
                              text=True, cwd=ROOT, check=True).stdout
        return json.loads(text)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("data", nargs="?", default=os.path.join(ROOT, "data.json"))
    ap.add_argument("--previous", help="data.json to compare against (default: HEAD's)")
    ap.add_argument("--table", action="store_true", help="print the tables, not annotations")
    args = ap.parse_args()
    with open(args.data) as f:
        d = json.load(f)

    notes, summary, gate = [], [], 0

    def note(kind, title, msg):
        notes.append(f"::{kind} title={title}::{msg}")

    summary.append(f"## probalog data, commit `{(d['meta']['commit'] or '')[:12]}`")

    t = d["tests"]
    if t["status"] != "ok":
        note("error", "tests", f"{t['failed']} of {t['total']} tests failed")
        gate = 1
    summary.append(f"### tests\n\n{t['total'] - t['failed']}/{t['total']} passed")

    bad = [r["program"] for r in d["reference"] if r["status"] == "disagree"]
    if bad:
        note("error", "ground truth", f"engine disagrees on {', '.join(bad)}")
        gate = 1
    summary.append("### ground truth\n\n" + table(
        ["program", "status", "rows agreeing"],
        [[r["program"], r["status"],
          f"{sum(1 for x in r['rows'] if x['agree'])}/{len(r['rows'])}" if "rows" in r else "-"]
         for r in d["reference"]]))

    by_case = cases(d["runs"])

    rows = []
    for system, ref, gating in CHECKS:
        agree, differ = 0, []
        for (suite, size), rs in by_case.items():
            a, b = rs.get(system), rs.get(ref)
            if not (a and b and a["status"] == "ok" and b["status"] == "ok"
                    and a["answer"] is not None and b["answer"] is not None):
                continue
            if same(a["answer"], b["answer"]):
                agree += 1
            else:
                differ.append(f"{suite} {list(size)} ({a['answer']:.6g} vs {b['answer']:.6g})")
        rows.append([system, ref, agree, len(differ), "; ".join(differ[:6])])
        if differ:
            note("error", f"{system} vs {ref}", f"{len(differ)} disagreements: {'; '.join(differ[:6])}")
            gate |= gating
    summary.append("### agreement\n\n" + table(
        ["system", "against", "agree", "disagree", "cases"], rows))

    suites = list(dict.fromkeys(s for s, _ in by_case))
    for suite in suites:
        sizes = [size for s, size in by_case if s == suite]
        summary.append(f"### {suite} (seconds)\n\n" + table(
            ["size"] + SYSTEMS,
            [[list(size)] + [cell(by_case[(suite, size)].get(s)) for s in SYSTEMS] for size in sizes]))

    largest = []
    for suite in suites:
        row = [suite]
        for s in SYSTEMS:
            done = [size for (st, size), rs in by_case.items()
                    if st == suite and rs.get(s, {}).get("status") == "ok"]
            row.append(list(done[-1]) if done else "-")
        largest.append(row)
    summary.append("### largest size finished within the limit\n\n" + table(["suite"] + SYSTEMS, largest))

    prev = previous_data(args.previous)
    if prev and "runs" in prev:
        old = {(r["suite"], tuple(r["size"]), r["system"]): r for r in prev["runs"]}
        changes = []
        for r in d["runs"]:
            if not r["system"].startswith(("probalog", "engine")):
                continue
            o = old.get((r["suite"], tuple(r["size"]), r["system"]))
            if not (o and r["status"] == "ok" and o["status"] == "ok"
                    and min(r["seconds"], o["seconds"]) >= REGRESSION_FLOOR):
                continue
            change = r["seconds"] / o["seconds"] - 1
            if abs(change) > REGRESSION:
                changes.append([r["suite"], r["size"], r["system"], f"{o['seconds']:.2f}",
                                f"{r['seconds']:.2f}", f"{change:+.0%}"])
        slower = [c for c in changes if c[5].startswith("+")]
        if slower:
            note("warning", "regressions",
                 "; ".join(f"{c[0]} {c[1]} {c[2]} {c[5]}" for c in slower[:8]))
        summary.append(f"### changes over {REGRESSION:.0%} against commit "
                       f"`{(prev['meta'].get('commit') or '')[:12]}`\n\n"
                       + (table(["suite", "size", "system", "before", "after", "change"], changes)
                          if changes else "none"))

    text = "\n\n".join(summary) + "\n"
    if args.table:
        print(text)
    else:
        print("\n".join(notes))
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
                f.write(text)
    sys.exit(gate)


if __name__ == "__main__":
    main()
