# Probalog: A Probabilistic Datalog implementation

Probalog is a probabilistic logic programming language. It is identical in syntax to standard datalog, except that facts can be annotated with probabilities. 

Like datalog, it performs bottom-up evalutation with a base set of facts that are extended on every iteration of an immediate-consequence operator, until a fixpoint is reached.

In addition to deriving the saturated factset, we also compute the probability of each fact by using the probabilities of relavant facts in the original factset.


## Ground truth semantics
Probalog's semantics is a probabilistic distribution over standard datalog semantics, where each program is ground as standard datalog programs with each initial fact either present or removed, instead of having a probability. A fact's resulting probability is then the total probability of the programs that derive it.

In a given probalog program, Let `F` be the set of initial facts, each `f ∈ F` annotated with a probability `p_f` (an unannotated fact has `p_f = 1`), and let `R` be the set of rules.


**Worlds** 

A world is a subset of the base facts, with the probabilities stripped. A *world* `w ⊆ F` is one outcome: the set of base facts
that hold. There are `2^|F|` worlds, and the probability of each world is the product of probabilities of facts that belong in the world being true and probabiilies of the ommitted facts being false. 

`P(w) = ∏_{f ∈ w} p_f · ∏_{f ∈ F∖w} (1 − p_f)`

**Derivation.**

Within a world the program is plain Datalog: the facts `w`
together with the rules `R`. Let `M(w, R)` be its _least model_, the set of facts
derivable from `w` using `R`. It always exists and is finite.


**Marginals.** 

A fact's probability is the total probability of the worlds
that derive it:

`P(q) = Σ_{w ⊆ F, q ∈ M(w, R)} P(w)`


**Conditioning.**

An observation `! e` or `! ~e` restricts the set of worlds only to ones where the observation holds (e must exist with `! e` and must not with `! ~e`). 

Let `E` be the set of worlds whose least model agrees with every observation made so far: `evidence` (the conjunction of all observations is ). 

The probability of a fact is the total probability of all the worlds in `E` in which it belongs to the least model, normalized by dividing by the total probability of all worlds in `E`.

`P(q | evidence) = Σ_{w ∈ E, q ∈ M(w, R)} P(w) / Σ_{w ∈ E} P(w)`.

This is undefined when no world agrees, which probalog reports as an error.

## Implementation

Probalog is implemented using [rsdd](https://github.com/neuppl/rsdd) ffi bindings used in the [Roulette](https://github.com/neuppl/roulette) probabilistic programming language.

Each base fact and derived fact is associated with a guard formula: a boolean formula with symbolic variables. This is so facts with overlapping guards are represented correctly, since derived facts need not be independent. 

The set of fact-guard pairs form a _symbolic set_, which represents a set with elements that only exist under a guard formula. set membership is therefore, symbolic under guards for each element. This is explained in more detail in `README.md`.

An immediate consequence-style operator then matches the set of rules against the factset on every iteration to either introduce new facts into the set, __or__ to disjoin _new_ clauses onto fact guards, expanding the probability in which an existing fact is true.

This is repeatedly applied to the factset until a fixpoint is reached: This is detected when the set of facts remains the same after a round. This means no new facts are added, __and the guards for each fact remain unchanged__ (logically equivalent)

To efficiently represent and manipulate the fact guards, they are represented as Binary Decision Diagrams (BDDs). Using BDDs for fact guards means that fixpoint detection becomes pointer equality over the guards, querying for probabilities reduces to weighted model counting (WMC), which is a fast operation, and guards are canonical and don't grow unnecessarily large with redundant disjunctions.


## Performance evaluation

Probalog is compared against a few other publicly available datalog/probabilistic datalog languages for correctness and efficiency/speed.

There also is a reference implementation of probalog in `reference.rkt` that computes the ground truth semantics as is for use as a correctness test. It uses Souffle as a known good implementation for standard datalog to compute the individual worlds' least model. 

The following 5 major examples are compared among the different implementations. 

- `ring`: a directed cycle with one path per derivation.
- `chordring`: a cycle with chords, which is dense and cyclic, so the same fact is re-derived many ways.
- `dag`: a layered DAG with many converging derivations.
- `smokers`: friends-and-smokers, with recursion around a cyclic relation.
- `sg` and `pointsto`: same-generation, and Andersen's points-to
  analysis.

Each example is translated, by claude, to the other languages for comparison.

These are some of the important findings.

### Correctness

| check                                  | runs | agree | disagree | timed out |
| -------------------------------------- | ---: | ----: | -------: | --------: |
| vs ProbLog                             |   19 |    17 |        0 | 2 (ProbLog) |
| vs cplint/PITA                         |   19 |    16 |        0 | 3 (PITA)  |
| vs Soufflé (probability-1 programs)    |   20 |    20 |        0 |         0 |
| vs PSoufflé (CI)                       |   10 |     8 |        2 |         0 |
| vs ground-truth enumeration (`reference.rkt`) | 177 queries, 13 files | 177 | 0 | 2 files over the size limit |

### Against exact probabilistic logic programming

Wall time in seconds, including about 0.3s of Racket startup; "—" is the
10s timeout. "PITA (all)" asks PITA for every tuple, which is the work
probalog always does.

| program     | size   | ProbLog | PITA | PITA (all) | probalog |
| ----------- | ------ | ------: | ---: | ---------: | -------: |
| `ring`      | 160    |    0.11 | 0.44 |            |     2.96 |
| `smokers`   | 15     |    0.08 | 0.30 |            |     0.30 |
|             | 40     |    0.12 | 1.36 |          — |     0.46 |
| `chordring` | 16     |    0.08 | 0.19 |       9.55 |     0.58 |
|             | 22     |    0.16 | 0.42 |          — |     3.41 |
| `dag`       | (6, 6) |       — |    — |          — |     3.86 |
|             | (7, 6) |       — |    — |          — |     9.08 |

- On a single query, ProbLog and PITA only derive what that query needs.
  They stay nearly flat on `ring` and `chordring`, while probalog computes
  the whole relation and grows, reaching 20× slower on `chordring` at 22.
- On `dag`, ProbLog and PITA build a structure per proof or per subgoal
  and time out at every size shown, while probalog merges each derivation
  into one canonical BDD per fact. PITA's single-query time also grows on
  `smokers`, where probalog is 3× faster at size 40.
- Asked for every tuple, PITA times out on `chordring` from size 18 and on
  `smokers` from size 30.

### The cost of uncertainty

The same program with every fact certain (`@1`, plain Datalog) and with
every fact `:: 0.5` (`@0.5`).

| program     | size   | tuples | Soufflé | probalog@1 | probalog@0.5 | cost |
| ----------- | ------ | -----: | ------: | ---------: | -----------: | ---: |
| `ring`      | 120    |  14400 |    0.05 |       1.22 |         1.36 | 1.1× |
|             | 200    |  40000 |    0.36 |       5.23 |         5.67 | 1.1× |
| `pointsto`  | 250    |  63001 |    0.13 |       6.42 |         8.09 | 1.3× |
| `chordring` | 22     |    484 |    0.04 |       0.35 |         3.16 | 9.1× |
|             | 26     |    676 |    0.05 |       0.31 |         8.26 |  27× |
| `dag`       | (7, 6) |    841 |    0.06 |       0.37 |         9.19 |  25× |

- With few derivations per tuple, probabilities add 10–30% at every size.
- With many overlapping derivations, the guards dominate, and their cost
  grows with how entangled the derivations are rather than with the
  number of tuples.
- On large sparse programs the limit is the Datalog engine, not the BDDs.
  probalog@1 times out on `ring` at 300 (90,000 tuples) and `pointsto` at
  400 (160,801), which Soufflé, a C++ engine, runs in 0.1–0.3s.

### Against PSoufflé

Run in CI at small sizes, PSoufflé takes 0.05–1s once compiled, which is
faster than probalog except on `dag`. Compiling each program takes
13–18s, though, and its `chordring` answers are wrong.

### Where the time goes

The in-process benchmarks (`examples/bench/run-benchmarks.rkt`, run on
every commit in CI) take 6–88ms per program without startup. About 55%
of that is building BDDs in rsdd and about 30% is matching rule bodies.
Set operations and indexing take the remaining 10%.

### Summary

- Probalog agrees with ProbLog, PITA and the ground truth everywhere they
  could be compared. The only disagreement is a PSoufflé bug.
- It finishes on `dag`, where ProbLog and PITA time out, and beats PITA
  when every tuple is needed beyond the smallest sizes.
- It is slower than goal-directed systems on single queries, because it
  always computes the whole relation.
- Its limits are guard size on densely entangled programs, which depends
  on the BDD variable order, and plain Datalog throughput on large sparse
  ones.
