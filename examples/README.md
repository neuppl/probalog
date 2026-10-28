# Probalog examples and benchmarks

Example programs for `#lang probalog`, a probabilistic Datalog with
exact inference by knowledge compilation, together with benchmarks
comparing it against ProbLog, cplint/PITA and Soufflé.

Install the language first, from the root of a probalog checkout:

```
raco pkg install --auto
```

Then run any example:

```
racket basics/network-example.rkt
```

Every query in these files carries the answer it should produce, worked
out by hand where that is feasible. A comment that stops matching the
output is a regression signal.

Or all of them:

```
for f in */*.rkt; do echo "== $f"; racket "$f"; done
```

These are examples, not tests. The correctness suite — expected query
probabilities, every read error, every run-time error — lives with the
implementation, at `test/probalog.rkt`, and runs with
`raco test test/probalog.rkt`.

## `basics/`

| file                                                     | what it shows                                                                                       |
| -------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| [network-example.rkt](basics/network-example.rkt)        | the smallest complete program: probabilistic facts, a recursive rule, queries                       |
| [family-example.rkt](basics/family-example.rkt)          | the classic family-relations program, with one uncertain parentage record                           |
| [edge-cases.rkt](basics/edge-cases.rkt)                  | a reference for the whole surface syntax: nullary predicates, numeric constants, layout, projection |

## `models/`

Realistic models, each ending in a set of observations and posteriors.

| file                                       | what it shows                                                                                    |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| [alarm.rkt](models/alarm.rkt)              | Pearl's burglary/earthquake network: nullary predicates, CPTs as noisy-or, **explaining away**    |
| [smokers.rkt](models/smokers.rkt)          | "friends and smokers": recursion around a cyclic relation, and how to write a probabilistic rule |
| [observation.rkt](models/observation.rkt)  | intrusion detection with unreliable sensors: false positives and false negatives in one model    |

## `semantics/`

What the language computes, in cases where the answer is easy to get
wrong.

| file                                          | what it shows                                                                                       |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| [correlation.rkt](semantics/correlation.rkt)  | the disjoint-sum problem: seven programs with hand-computable answers, next to what assuming independence would give |
| [cycles.rkt](semantics/cycles.rkt)            | recursion in every shape: cyclic graphs, self-loops, mutual recursion, non-linear recursion         |

## `ported/`

Standard examples from Soufflé and ProbLog, brought over unchanged
where the language allows it. Each file notes what had to be adapted:
probalog puts probabilities on facts rather than rules, and has no
negation, no disequality and no annotated disjunctions.

| file                                                            | ported from                                                            | what it shows                                                                          |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| [souffle-points-to.rkt](ported/souffle-points-to.rkt)           | Soufflé's tutorial (Andersen's analysis, the core of Doop)             | probabilistic program analysis: unresolved reflection and virtual dispatch as confidences, and why two candidates are *not* an exclusive choice here |
| [souffle-same-generation.rkt](ported/souffle-same-generation.rkt) | the classic `sg` benchmark, in Soufflé's test suite                    | the recursive atom in the middle of the body — bindings flowing in from `up` and out through `down` |
| [problog-biomine.rkt](ported/problog-biomine.rkt)               | ProbLog's flagship Biomine application                                 | connection probability in a biological network: exact 0.4153 against 0.5569 from treating paths as independent |
| [problog-genetics.rkt](ported/problog-genetics.rkt)             | ProbLog's genetics/bloodtype examples                                  | a pedigree where `:: 0.5` *is* meiosis; recovers the textbook 1/4 recurrence risk and 2/3 carrier probability |
| [problog-epidemic.rkt](ported/problog-epidemic.rkt)             | ProbLog's epidemic / viral-marketing examples                          | unrolling time without arithmetic, contact tracing backwards from a positive test        |
| [psouffle-side-channel.rkt](ported/psouffle-side-channel.rkt)   | PSoufflé's `language_side_channel_mini` regression case                | which observed events a hidden value explains; ports unchanged, and reproduces PSoufflé's 0.6552 / 0.153 exactly |
| [psouffle-taint.rkt](ported/psouffle-taint.rkt)                 | PSoufflé's `language_taint_mini` regression case                       | taint reaching a sink by two routes; encodes away negation and a weighted rule, and reproduces PSoufflé's 0.2904 / 0.26129241 exactly |

PSoufflé's third bundled example, `language_symbolization_mini`, is not
here. It sums a numeric column with `TotalBytes = sum Bytes : {...}`,
and probalog has neither aggregates nor arithmetic, so there is no
faithful encoding — only a rewrite into a different program, which
would not be a port. The other two are exact: their answers match
PSoufflé's own output digit for digit.

Two ProbLog staples are deliberately absent. The sprinkler/grass
network is the same noisy-or shape as [alarm.rkt](models/alarm.rkt),
which already covers it. A hidden Markov model is not expressible at
all: mutually exclusive states need negation or annotated
disjunctions, so [problog-epidemic.rkt](ported/problog-epidemic.rkt)
uses a monotone process instead, and says why.

## `bench/`

Every benchmark runs on every commit, in CI and locally, and writes one
data file, [data.json](../data.json) at the repository root.

| file                                             | what it does                                                                                   |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| [setup.sh](bench/setup.sh)                       | installs ProbLog, SWI-Prolog with cplint, Soufflé, CUDD and PSoufflé under one cache directory |
| [suites.py](bench/suites.py)                     | the benchmark models and their size ladders, independent of any system's syntax                |
| [systems.py](bench/systems.py)                   | one emitter and runner per system                                                              |
| [collect.py](bench/collect.py)                   | runs the tests, the ground-truth check, the examples and every system on every case            |
| [collect-engine.rkt](bench/collect-engine.rkt)   | probalog measured in-process: each evaluation mode, its timing split and rsdd time             |
| [report.py](bench/report.py)                     | agreement, speed and regression tables derived from `data.json`                                |
| [run-benchmarks.rkt](bench/run-benchmarks.rkt)   | the CI timing-split benchmarks                                                                 |
| [probalog-examples.rkt](bench/probalog-examples.rkt) | the four programs those benchmarks run                                                     |
| [timing-programs.rkt](bench/timing-programs.rkt) | the six programs the timing plot runs, loadable without graphics libraries |
| [timing-plot.rkt](bench/timing-plot.rkt), [probalog-plot.rkt](bench/probalog-plot.rkt) | stacked-bar plots of the timing split          |

```
./bench/setup.sh                       # once; later runs do nothing
python3 bench/collect.py               # everything, into ../data.json
python3 bench/collect.py --quick       # the first two sizes of each suite
python3 bench/report.py --table        # the derived tables
```

Each suite (`ring`, `chordring`, `dag`, `smokers`, `sg`, `pointsto`, and a
one-fact `startup` case) has one generator and a ladder of sizes running
past where probalog times out. Every system runs every size, interleaved
by case, under a 10s limit; runs under 2s are repeated three times and
the median kept. Once a system times out in a suite, its larger sizes
there are recorded as not run.

The systems are probalog end to end (with and without probabilities),
ProbLog with SDD, cplint/PITA, Soufflé, PSoufflé (whose compile step is
timed separately), and probalog in-process, where its timing split and
rsdd time are recorded.

`setup.sh` installs into `~/.cache/probalog-bench`, or
`$PROBALOG_BENCH_HOME`, which must not contain spaces because CUDD's
libtool splits paths at them. It writes `env.sh` there naming every
binary, which `collect.py` reads.

## Reading the output

A query prints as a distribution over `#t` and `#f`:

```
Path("a", "c"): #<pmf: [#t 0.3] [#f 0.7]>
```

unless the answer is certain, in which case it prints as `#t` or `#f`
alone. So `#f` means "provably never derivable, given the facts, the
rules and every observation so far", not "probability rounded to zero".
