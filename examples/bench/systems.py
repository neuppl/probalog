"""One emitter and runner per system.

Each system writes a model in its own syntax into a case directory, runs
it under a time limit, and returns (status, seconds, answer, extra). The
answer is the query's probability, or for Souffle 1.0/0.0 for whether
the query tuple is derived. Binaries come from the environment that
setup.sh writes, so local and CI runs use the same ones.
"""

import csv
import json
import os
import re
import shutil
import subprocess
import time

from suites import Var

HERE = os.path.dirname(os.path.abspath(__file__))
TIMEOUT = 10
COMPILE_TIMEOUT = 120


def bench_home():
    return os.environ.get("PROBALOG_BENCH_HOME", os.path.expanduser("~/.cache/probalog-bench"))


def load_env():
    """The variables setup.sh exported, without needing to source it."""
    path = os.path.join(bench_home(), "env.sh")
    env = {}
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                m = re.match(r'export (\w+)="(.*)"$', line.strip())
                if m:
                    env[m.group(1)] = m.group(2)
    return env


ENV = load_env()


def prepend(env, var, value):
    if value:
        env[var] = value + (":" + env[var] if env.get(var) else "")


def tool_env(*libs):
    """The environment for a system built against setup.sh's toolchain:
    its binaries, libraries and headers ahead of the system's."""
    env = dict(os.environ)
    prepend(env, "PATH", ENV.get("BENCH_PATH", ""))
    for lib in (ENV.get("BENCH_LIB", ""), *libs):
        prepend(env, "LD_LIBRARY_PATH", lib)
        prepend(env, "LIBRARY_PATH", lib)
    prepend(env, "CPATH", ENV.get("BENCH_INCLUDE", ""))
    return env


def tool(name, default):
    return os.environ.get(name) or ENV.get(name) or default


def timed(cmd, timeout=TIMEOUT, cwd=None, env=None):
    t0 = time.perf_counter()
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           cwd=cwd, env=env)
    except subprocess.TimeoutExpired:
        return "timeout", None, ""
    except OSError:
        return "not found", None, ""
    elapsed = time.perf_counter() - t0
    if r.returncode != 0:
        return "error", None, (r.stdout + r.stderr).strip()[-1000:]
    return "ok", elapsed, r.stdout


def version(cmd, pattern=None):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=30, env=tool_env())
    except (OSError, subprocess.TimeoutExpired):
        return None
    lines = [l.strip() for l in (out.stdout + out.stderr).splitlines() if l.strip()]
    if pattern:
        lines = [l for l in lines if re.search(pattern, l)]
    return lines[0] if out.returncode == 0 and lines else None


# --------------------------------------------------------------------------
# Syntax

def lower(pred):
    return pred.lower()


def term_probalog(t):
    if isinstance(t, Var):
        return str(t)
    return f'"{t}"' if isinstance(t, str) else str(t)


def term_prolog(t):
    if isinstance(t, Var):
        return str(t).upper()
    if isinstance(t, str):
        return t if re.fullmatch(r"[a-z][A-Za-z0-9_]*", t) else "'" + t.replace("'", "\\'") + "'"
    return str(t)


def term_souffle(t):
    if isinstance(t, Var):
        return str(t)
    return f'"{t}"' if isinstance(t, str) else str(t)


def render(a, name, term):
    return f"{name(a[0])}({', '.join(term(t) for t in a[1])})"


def probalog_source(m, certain=False):
    out = ["#lang probalog"]
    for pred, args, pr in m.facts:
        fact = render((pred, args), str, term_probalog)
        out.append(f"{fact}." if certain or pr == 1 else f"{fact} :: {pr}.")
    for head, body in m.rules:
        out.append(f"{render(head, str, term_probalog)} :- "
                   + ", ".join(render(a, str, term_probalog) for a in body) + ".")
    out.append(f"? {render(m.query, str, term_probalog)}.")
    return "\n".join(out) + "\n"


def prolog_clauses(m):
    out = []
    for pred, args, pr in m.facts:
        fact = render((pred, args), lower, term_prolog)
        out.append(f"{fact}." if pr == 1 else f"{pr}::{fact}.")
    for head, body in m.rules:
        out.append(f"{render(head, lower, term_prolog)} :- "
                   + ", ".join(render(a, lower, term_prolog) for a in body) + ".")
    return out


def souffle_decls(m):
    return [f".decl {lower(pred)}({', '.join(f'a{i}:{t}' for i, t in enumerate(ts))})"
            for pred, ts in m.types.items()]


def souffle_rules(m):
    return [f"{render(head, lower, term_souffle)} :- "
            + ", ".join(render(a, lower, term_souffle) for a in body) + "."
            for head, body in m.rules]


def query_tuple(m):
    return tuple(str(t) for t in m.query[1])


def probalog_answer(out):
    """#t / #f, or the probability that the queried fact holds."""
    last = (out or "").strip().splitlines()[-1:] or [""]
    last = last[0]
    m = re.search(r"#t ([0-9.eE+-]+)", last)
    if m:
        return float(m.group(1))
    if last.endswith(": #t"):
        return 1.0
    if last.endswith(": #f"):
        return 0.0
    return None


def first_float(text):
    for line in (text or "").splitlines():
        try:
            return float(line.strip())
        except ValueError:
            continue
    return None


def failure(status, out):
    return dict(detail=out[-500:]) if status == "error" else {}


# --------------------------------------------------------------------------
# Systems

class System:
    name = None

    def available(self):
        return None

    def run(self, m, case_dir):
        raise NotImplementedError


class Probalog(System):
    def __init__(self, certain=False):
        self.certain = certain
        self.name = "probalog-certain" if certain else "probalog"
        self.racket = tool("RACKET", "racket")

    def available(self):
        return version([self.racket, "-e", "(display (version))"])

    def run(self, m, case_dir):
        path = os.path.join(case_dir, f"{self.name}.rkt")
        with open(path, "w") as fh:
            fh.write(probalog_source(m, self.certain))
        status, t, out = timed([self.racket, path])
        return status, t, probalog_answer(out) if status == "ok" else None, failure(status, out)


class ProbLog(System):
    name = "problog"

    def __init__(self):
        self.bin = tool("PROBLOG", "problog")
        # The interpreter of ProbLog's own environment, next to its command.
        python = os.path.join(os.path.dirname(self.bin), "python")
        self.cmd = ([python, os.path.join(HERE, "run-problog.py")]
                    if os.path.exists(python) else [self.bin])

    def available(self):
        return version([*self.cmd, "--version"])

    def run(self, m, case_dir):
        path = os.path.join(case_dir, "problog.pl")
        with open(path, "w") as fh:
            fh.write("\n".join(prolog_clauses(m) + [f"query({render(m.query, lower, term_prolog)})."]) + "\n")
        status, t, out = timed([*self.cmd, "-k", "sdd", path])
        if status != "ok":
            return status, None, None, failure(status, out)
        answer = None
        if status == "ok":
            hit = re.search(r":\s*([0-9.eE+-]+)\s*$", out.strip().splitlines()[-1]) if out.strip() else None
            answer = float(hit.group(1)) if hit else None
        return status, t, answer, {}


class Pita(System):
    name = "pita"

    def __init__(self):
        self.bin = tool("SWIPL", "swipl")
        self.packs = tool("CPLINT_PACKS", "")
        self.env = tool_env()

    def attach(self):
        return f"attach_packs('{self.packs}', [])," if self.packs else ""

    def available(self):
        ok = subprocess.run([self.bin, "-g", f"{self.attach()}use_module(library(pita))", "-t", "halt"],
                            capture_output=True, env=self.env).returncode == 0 if shutil.which(self.bin) or os.path.exists(self.bin) else False
        return version([self.bin, "--version"]) if ok else None

    def run(self, m, case_dir):
        path = os.path.join(case_dir, "pita.pl")
        with open(path, "w") as fh:
            fh.write("\n".join([":- use_module(library(pita)).", ":- pita.", ":- begin_lpad."]
                               + prolog_clauses(m) + [":- end_lpad."]) + "\n")
        q = render(m.query, lower, term_prolog)
        goal = f"{self.attach()}consult('{path}'), ((prob({q},P)->true;P=0.0), format('~w~n',[P]))"
        status, t, out = timed([self.bin, "-g", goal, "-t", "halt"], env=self.env)
        return status, t, first_float(out) if status == "ok" else None, failure(status, out)


class Souffle(System):
    name = "souffle"

    def __init__(self):
        self.bin = tool("SOUFFLE", "souffle")

    def available(self):
        return version([self.bin, "--version"], r"[Vv]ersion")

    def run(self, m, case_dir):
        path = os.path.join(case_dir, "souffle.dl")
        out_dir = os.path.join(case_dir, "souffle-out")
        os.makedirs(out_dir, exist_ok=True)
        qrel = lower(m.query[0])
        lines = souffle_decls(m) + [f".output {qrel}"]
        lines += [f"{render((pred, args), lower, term_souffle)}." for pred, args, _ in m.facts]
        lines += souffle_rules(m)
        with open(path, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        status, t, out = timed([self.bin, "-D", out_dir, path], env=tool_env())
        if status != "ok":
            return status, None, None, failure(status, out)
        answer = None
        if status == "ok":
            with open(os.path.join(out_dir, f"{qrel}.csv")) as fh:
                tuples = {tuple(row) for row in csv.reader(fh, delimiter="\t") if row}
            answer = 1.0 if query_tuple(m) in tuples else 0.0
        return status, t, answer, {}


PSOUFFLE_ANSWER = re.compile(r"^(\w+)\((.*)\)\s*:\s*([0-9.eE+-]+)\s*$")


class PSouffle(System):
    name = "psouffle"

    def __init__(self):
        self.bin = tool("PSOUFFLE", "")
        self.env = tool_env(tool("CUDD_LIB_DIR", ""))

    def available(self):
        return version([self.bin, "--version"], r"[Vv]ersion") if self.bin and os.access(self.bin, os.X_OK) else None

    def run(self, m, case_dir):
        work = os.path.join(case_dir, "psouffle")
        in_dir, out_dir = os.path.join(work, "input"), os.path.join(work, "output")
        os.makedirs(in_dir, exist_ok=True)
        os.makedirs(out_dir, exist_ok=True)
        qrel = lower(m.query[0])
        base = {pred for pred, _, _ in m.facts}
        lines = []
        for decl, pred in zip(souffle_decls(m), m.types):
            lines.append(decl)
            if pred in base:
                lines.append(f".input {lower(pred)}")
        lines.append(f".output {qrel}")
        lines += souffle_rules(m)
        lines.append(f"query({qrel}({', '.join('_' * len(m.query[1]))})).")
        prog = os.path.join(work, "compute.dl")
        with open(prog, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        rows = {}
        for pred, args, pr in m.facts:
            rows.setdefault(pred, []).append((args, pr))
        for pred, rs in rows.items():
            with open(os.path.join(in_dir, f"{lower(pred)}.facts"), "w") as fh:
                fh.write("".join("\t".join(str(a) for a in args) + "\n" for args, _ in rs))
            with open(os.path.join(in_dir, f"{lower(pred)}.prob"), "w") as fh:
                fh.write("".join(f"{pr}\n" for _, pr in rs))
        exe = os.path.join(work, "compute")
        cstatus, ct, cout = timed([self.bin, "-F", in_dir, "-D", out_dir, prog, "-o", exe],
                                  timeout=COMPILE_TIMEOUT, cwd=work, env=self.env)
        extra = dict(compile_status=cstatus, compile_seconds=ct)
        if cstatus != "ok":
            extra["compile_error"] = cout[-500:]
            return "compile " + cstatus, None, None, extra
        status, t, out = timed([exe, "-F", in_dir, "-D", out_dir, "--det-opt", "--rewrite",
                                "--logfile", "run"], env=self.env)
        if status != "ok":
            return status, None, None, dict(extra, **failure(status, out))
        answer = None
        if status == "ok":
            path = os.path.join(out_dir, "facts.prob")
            if os.path.exists(path):
                with open(path) as fh:
                    for line in fh:
                        hit = PSOUFFLE_ANSWER.match(line.strip())
                        if hit and tuple(a.strip().strip('"') for a in hit.group(2).split(",")
                                         if a.strip()) == query_tuple(m):
                            answer = float(hit.group(3))
            answer = 0.0 if answer is None else answer
        return status, t, answer, extra


class Engine(System):
    """probalog in-process, with magic sets, and the timing split."""

    def __init__(self, mode):
        self.mode = mode
        self.name = "engine"
        self.racket = tool("RACKET", "racket")

    def available(self):
        return version([self.racket, "-e", "(display (version))"])

    def run(self, m, case_dir):
        path = os.path.join(case_dir, "engine.rkt")
        if not os.path.exists(path):
            with open(path, "w") as fh:
                fh.write(probalog_source(m))
        status, _, out = timed([self.racket, os.path.join(HERE, "collect-engine.rkt"),
                                "mode", self.mode, path], timeout=TIMEOUT * 4 + 30)
        if status != "ok":
            return "error", None, None, dict(detail=out)
        r = json.loads(out)
        extra = {k: val for k, val in r.items() if k not in ("status", "ms", "runs_ms", "answers")}
        answer = probalog_answer("x: " + r["answers"][0]) if r.get("answers") else None
        runs = [ms / 1000 for ms in r.get("runs_ms", [])]
        return r["status"], (r["ms"] / 1000 if r["status"] == "ok" else None), answer, dict(extra, runs=runs)


def all_systems():
    return [Probalog(), Probalog(certain=True), ProbLog(), Pita(), Souffle(), PSouffle(),
            Engine("magic")]
