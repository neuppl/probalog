#!/usr/bin/env python3
"""Runs every test, check and benchmark, and writes data.json at the
repository root.

    examples/bench/setup.sh                      # once; installs the systems
    python3 examples/bench/collect.py            # everything
    python3 examples/bench/collect.py --quick    # two sizes per suite

Every system runs on every size of every suite, interleaved by case, each
run under a 10s limit. Once a system times out in a suite, its larger
sizes there are recorded as not run.
"""

import argparse
import datetime
import json
import os
import platform
import re
import statistics
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import suites
import systems

EXAMPLES = os.path.join(ROOT, "examples")
EXAMPLE_DIRS = ["basics", "models", "semantics", "ported"]
REPEAT_BELOW = 2.0
STOPPING = ("timeout", "memory limit", "compile timeout")


def log(msg):
    print(f"==> {msg}", file=sys.stderr, flush=True)


def run(cmd, timeout=None, cwd=ROOT):
    t0 = time.perf_counter()
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd)
    except subprocess.TimeoutExpired:
        return None, "", "timeout"
    return time.perf_counter() - t0, r.stdout, r.stderr if r.returncode else ""


def output(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT).stdout.strip()
    except OSError:
        return None


def example_files():
    return sorted(os.path.join(EXAMPLES, d, f)
                  for d in EXAMPLE_DIRS
                  for f in os.listdir(os.path.join(EXAMPLES, d)) if f.endswith(".rkt"))


# --------------------------------------------------------------------------
# Checks and the engine's own programs

def meta(quick):
    return dict(
        generated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        commit=output(["git", "rev-parse", "HEAD"]),
        uncommitted_changes=bool(output(["git", "status", "--porcelain"])),
        os=platform.platform(),
        machine=platform.machine(),
        cpu=(output(["sysctl", "-n", "machdep.cpu.brand_string"])
             if sys.platform == "darwin" else platform.processor()),
        cpus=os.cpu_count(),
        python=platform.python_version(),
        quick=quick,
        timeout_s=systems.TIMEOUT,
        repeat_below_s=REPEAT_BELOW,
    )


def tests():
    t, out, err = run(["raco", "test", "test/probalog.rkt"], timeout=900)
    text = out + err
    passed = re.search(r"(\d+) tests? passed", text)
    failed = re.search(r"(\d+)/(\d+) test failures", text)
    return dict(
        file="test/probalog.rkt",
        seconds=t,
        total=int(failed.group(2)) if failed else (int(passed.group(1)) if passed else None),
        failed=int(failed.group(1)) if failed else 0,
        status="ok" if passed and not failed else "failed",
    )


def engine_helper(*args, timeout=None):
    _, out, err = run(["racket", os.path.join(HERE, "collect-engine.rkt"), *args], timeout=timeout)
    if err:
        raise RuntimeError(f"collect-engine.rkt {args[0]} failed: {err.strip()[:2000]}")
    return json.loads(out) if out else None


def reference():
    return engine_helper("reference", *example_files())


def examples_end_to_end():
    out = []
    for f in example_files():
        t, _, err = run(["racket", f], timeout=60)
        out.append(dict(program=os.path.relpath(f, ROOT), wall_s=t,
                        status="ok" if t and not err else (err.strip()[:500] or "timeout")))
    return out


def programs():
    """The examples and the CI and timing-plot programs, in-process."""
    with tempfile.TemporaryDirectory() as dir:
        engine_helper("programs", dir)
        groups = [("example", example_files()),
                  ("benchmark", sorted(os.path.join(dir, f) for f in os.listdir(dir)))]
        out = []
        for kind, files in groups:
            for f in files:
                log(f"program: {os.path.basename(f)}")
                rec = engine_helper("engine", f)[0]
                rec["kind"] = kind
                if kind == "example":
                    rec["program"] = os.path.relpath(f, ROOT)
                out.append(rec)
        return out


def ci_benchmarks():
    with tempfile.TemporaryDirectory() as dir:
        path = os.path.join(dir, "results.json")
        _, _, err = run(["racket", "run-benchmarks.rkt", "-o", path,
                         output(["git", "rev-parse", "HEAD"]) or "unknown"], cwd=HERE)
        if err:
            return dict(status="failed", error=err.strip()[:2000])
        with open(path) as f:
            return json.load(f)


# --------------------------------------------------------------------------
# The matrix

def measure(system, model, case_dir):
    status, t, answer, extra = system.run(model, case_dir)
    if isinstance(system, systems.Engine):
        return dict(status=status, seconds=t, runs=extra.pop("runs", []), answer=answer, **extra)
    runs = [t] if status == "ok" else []
    if status == "ok" and t < REPEAT_BELOW:
        for _ in range(2):
            s2, t2, _, _ = system.run(model, case_dir)
            if s2 == "ok":
                runs.append(t2)
    return dict(status=status, seconds=statistics.median(runs) if runs else None,
                runs=runs, answer=answer, **extra)


def matrix(available, quick):
    rows = []
    for suite, spec in suites.SUITES.items():
        stopped = {}
        ladder = spec["ladder"][:2] if quick else spec["ladder"]
        for size in ladder:
            model = spec["gen"](*size)
            log(f"{suite} {list(size)}: {len(model.facts)} facts")
            with tempfile.TemporaryDirectory() as case_dir:
                for system in available:
                    row = dict(suite=suite, size=list(size), system=system.name,
                               facts=len(model.facts))
                    if system.name in stopped:
                        row.update(status="not run",
                                   note=f"timed out at size {stopped[system.name]}")
                    else:
                        row.update(measure(system, model, case_dir))
                        if row["status"] in STOPPING:
                            stopped[system.name] = list(size)
                    rows.append(row)
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quick", action="store_true", help="the first two sizes of each suite")
    ap.add_argument("-o", "--output", default=os.path.join(ROOT, "data.json"))
    args = ap.parse_args()

    log("compiling")
    subprocess.run(["raco", "make", "lang/expander.rkt", "reference.rkt",
                    os.path.join(HERE, "collect-engine.rkt"), *example_files()],
                   cwd=ROOT, check=True, capture_output=True)
    all_systems = systems.all_systems()
    versions = {s.name: s.available() for s in all_systems}
    available = [s for s in all_systems if versions[s.name]]

    data = dict(meta=meta(args.quick), systems=versions)
    log("tests")
    data["tests"] = tests()
    log("reference")
    data["reference"] = reference()
    log("examples, end to end")
    data["examples"] = examples_end_to_end()
    log("ci benchmarks")
    data["ci_benchmarks"] = ci_benchmarks()
    data["programs"] = programs()
    data["runs"] = matrix(available, args.quick)
    data["meta"]["finished_at"] = datetime.datetime.now(
        datetime.timezone.utc).isoformat(timespec="seconds")

    with open(args.output, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
        f.write("\n")
    log(f"wrote {args.output}")


if __name__ == "__main__":
    main()
