#lang racket
(require "pmf.rkt"
         "hash-set.rkt"
         "guards.rkt")
(provide (all-defined-out)
         (all-from-out "pmf.rkt")
         (all-from-out "hash-set.rkt")
         (all-from-out "guards.rkt"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Program representation

;; name is the predicate identifier, and
;; args is a list of any (concrete) arguments supplied to the fact.

;; args can be symbols, which represent variables
(struct fact (name args)
  #:transparent
  #:methods gen:custom-write
  [(define (write-proc self port mode)
     (write-string (symbol->string (fact-name self)) port)
     (write-string "(" port)
     (for ([a (fact-args self)] [i (in-naturals)])
       (when (> i 0) (write-string ", " port))
       (if (string? a)
           (write-string (format "~s" a) port)
           (write a port)))
     (write-string ")" port))])

;; head is the derived fact, and body is a list of
;; facts (clauses) that must be satisfied.
(struct rule (head body) #:transparent)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Matching

;; Match a fact pattern against f, given existing bindings. Returns
;; extended bindings, or #f if the match fails.
(define (match-fact pattern f bindings)
  (and (equal? (fact-name pattern) (fact-name f))
       (= (length (fact-args pattern)) (length (fact-args f)))
       (match-args (fact-args pattern) (fact-args f) bindings)))

(define (match-args pattern-args fact-args bindings)
  (cond
    [(null? pattern-args) bindings]
    [else
     (define p (car pattern-args))
     (define a (car fact-args))
     (cond
       [(symbol? p)
        (cond
          [(hash-has-key? bindings p)
           (and (equal? (hash-ref bindings p) a)
                (match-args (cdr pattern-args) (cdr fact-args) bindings))]
          [else
           (match-args (cdr pattern-args) (cdr fact-args)
                       (hash-set bindings p a))])]
       [else
        (and (equal? p a)
             (match-args (cdr pattern-args) (cdr fact-args) bindings))])]))

(define (substitute head bindings)
  (fact (fact-name head)
        (map (lambda (a) (if (symbol? a) (hash-ref bindings a) a))
             (fact-args head))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Probabilistic fact database

;; Put base facts sharing a constant next to each other: this is the BDD
;; variable order, and facts that can meet in a derivation are the ones
;; that want to be adjacent. Breadth-first over constants (Cuthill-McKee),
;; so it is invariant under renaming the data.
(define (order-base-facts base-fact-probs)
  ;; constants that share a fact are adjacent
  (define adj (make-hash))
  (for ([fp base-fact-probs])
    (define as (fact-args (car fp)))
    (for ([a as])
      (unless (hash-has-key? adj a) (hash-set! adj a (make-hash))))
    (for* ([a as] [b as] #:unless (equal? a b))
      (hash-set! (hash-ref adj a) b #t)))
  ;; breadth-first visit order, restarting for each component
  (define idx (make-hash))
  (define counter 0)
  (define (visit! c)
    (unless (hash-has-key? idx c)
      (hash-set! idx c counter)
      (set! counter (add1 counter))))
  (for* ([fp base-fact-probs] [start (fact-args (car fp))])
    (unless (hash-has-key? idx start)
      (visit! start)
      (let loop ([queue (list start)])
        (unless (null? queue)
          (define fresh
            (for/fold ([acc '()]) ([(nb _) (in-hash (hash-ref adj (car queue)))])
              (cond
                [(hash-has-key? idx nb) acc]
                [else (visit! nb) (cons nb acc)])))
          (loop (append (cdr queue) (reverse fresh)))))))
  ;; a fact sits at its earliest-visited argument; nullary facts, which
  ;; share a constant with nothing, keep their declared order in front
  (define (rank fp)
    (for/fold ([m -1]) ([a (fact-args (car fp))])
      (define i (hash-ref idx a 0))
      (if (or (= m -1) (< i m)) i m)))
  ;; `sort` is stable, so declaration order breaks ties
  (sort base-fact-probs < #:key rank))

;; base-fact-probs : list of (cons fact probability). The only place a
;; base fact's guard is made, hence the only place the variable order is
;; decided.
(define (make-base-set base-fact-probs)
  (for/sym-set ([fp (order-base-facts base-fact-probs)])
    (values (car fp) (guard-var (cdr fp)))))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Immediate consequence operator (semi-naive)


;; all is a fallback for by-pos, which indexes arguments at every position.
;; Indexes hold facts, not guards: a fact's guard is read from the current
;; set when it is matched, so an index stays valid as guards grow and only
;; needs extending with facts that are new.
(struct pred-index (all count by-pos) #:transparent)
(define (empty-pred-index) (pred-index '() 0 (hash)))

;; by-pos maps a position to a hash from value to (cons count facts), so
;; a lookup can pick the smallest bucket among the bound positions.
(define (pred-index-add pi f)
  (define new-by-pos
    (for/fold ([bp (pred-index-by-pos pi)]) ([a (fact-args f)] [i (in-naturals)])
      (hash-update bp i
                   (lambda (inner)
                     (hash-update inner a
                                  (lambda (b) (cons (add1 (car b)) (cons f (cdr b))))
                                  (cons 0 '())))
                   (hash))))
  (pred-index (cons f (pred-index-all pi)) (add1 (pred-index-count pi)) new-by-pos))

;; predicate name -> pred-index
(define (index-add idx keys)
  (for/fold ([idx idx]) ([k keys])
    (hash-update idx (fact-name k)
                 (lambda (pi) (pred-index-add pi k))
                 empty-pred-index)))

(define (index-size idx name)
  (define pi (hash-ref idx name #f))
  (if pi (pred-index-count pi) 0))

;; The facts that could match `clause`: the smallest bucket over its
;; arguments already known, or every fact of the predicate if none are.
(define (candidates-for clause bindings idx)
  (define pi (hash-ref idx (fact-name clause) #f))
  (cond
    [(not pi) '()]
    [else
     (define best
       (for/fold ([best #f]) ([a (in-list (fact-args clause))] [i (in-naturals)])
         (define known? (or (not (symbol? a)) (hash-has-key? bindings a)))
         (cond
           [(not known?) best]
           [else
            (define v (if (symbol? a) (hash-ref bindings a) a))
            (define bucket (hash-ref (hash-ref (pred-index-by-pos pi) i (hash)) v '(0)))
            (if (or (not best) (< (car bucket) (car best))) bucket best)])))
     (if best (cdr best) (pred-index-all pi))]))

;; The smallest relation first (the delta on a tie), then at each step an
;; atom sharing a bound argument, fewest arguments still unbound first and
;; smaller relations breaking ties, so each step after the first is an
;; index lookup rather than a cross product. The delta atom's size is the
;; delta's.
(define (join-order body delta-pos full-idx delta-idx)
  (define (size ci)
    (- (index-size (if (= (cdr ci) delta-pos) delta-idx full-idx) (fact-name (car ci)))
       (if (= (cdr ci) delta-pos) 1/2 0)))
  (define (unbound ci bound)
    (define args (fact-args (car ci)))
    (define free (for/sum ([a (in-list args)])
                   (if (and (symbol? a) (not (hash-ref bound a #f))) 1 0)))
    (if (and (pair? args) (= free (length args))) (+ free 1000) free))
  (define (bind bound atom)
    (for/fold ([bound bound]) ([a (in-list (fact-args atom))] #:when (symbol? a))
      (hash-set bound a #t)))
  (define atoms (for/list ([c (in-list body)] [i (in-naturals)]) (cons c i)))
  (define start (argmin size atoms))
  (let loop ([order (list start)]
             [bound (bind (hasheq) (car start))]
             [rest (remq start atoms)])
    (cond
      [(null? rest) (reverse order)]
      [else
       (define next (argmin (lambda (ci) (+ (* (unbound ci bound) 1e9) (size ci))) rest))
       (loop (cons next order) (bind bound (car next)) (remq next rest))])))

;; Guards are read from `full`. Without `guards?`, every binding keeps
;; the guard true.
(define (find-bindings-prob/at body full full-idx delta-idx delta-pos [guards? #t])
  (for/fold ([worlds (list (cons (hash) (guard-true)))])
            ([ci (in-list (join-order body delta-pos full-idx delta-idx))])
    (define clause (car ci))
    (define idx (if (= (cdr ci) delta-pos) delta-idx full-idx))
    (for*/list ([w worlds]
                [f (candidates-for clause (car w) idx)]
                [b (in-value (match-fact clause f (car w)))]
                #:when b)
      (cons b (if guards? (guard-and (cdr w) (set-member? full f)) (cdr w))))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Timing instrumentation

(define total-find-bindings-time 0.0)
(define total-guard-build-time 0.0)
(define total-set-union-time 0.0)
(define total-index-time 0.0)

(define (time-it! updater! thunk)
  (define start (current-inexact-monotonic-milliseconds))
  (define result (thunk))
  (updater! (- (current-inexact-monotonic-milliseconds) start))
  result)

(define (add-find-bindings-time! dt) (set! total-find-bindings-time (+ total-find-bindings-time dt)))
(define (add-guard-build-time! dt) (set! total-guard-build-time (+ total-guard-build-time dt)))
(define (add-set-union-time! dt) (set! total-set-union-time (+ total-set-union-time dt)))
(define (add-index-time! dt) (set! total-index-time (+ total-index-time dt)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Immediate consequence operator

;; Keys among `keys` whose guard changed; a pointer comparison each.
(define (changed-keys old new keys)
  (for/list ([k keys] #:unless (guard-equiv? (set-member? new k) (set-member? old k))) k))

;; One round. Returns the new set and the facts derived in it, the only
;; ones whose guard can have changed.
(define (immediate-semi full full-idx delta-keys rules [deterministic (hasheq)])
  (define delta-idx
    (time-it! add-index-time! (lambda () (index-add (hash) delta-keys))))
  (for/fold ([acc full] [derived '()]) ([r rules])
    (define body (rule-body r))
    (define guards? (not (hash-ref deterministic (fact-name (rule-head r)) #f)))
    ;; Each clause position in turn draws from the delta; a derivation
    ;; with two changed facts is built twice, and the second is free. A
    ;; position whose predicate has no delta derives nothing new.
    (define bindings
      (time-it! add-find-bindings-time!
                (lambda ()
                  (for*/list ([(clause pos) (in-indexed body)]
                              #:when (hash-ref delta-idx (fact-name clause) #f)
                              [w (find-bindings-prob/at body full full-idx delta-idx pos guards?)])
                    w))))
    (define fresh
      (time-it! add-guard-build-time!
                (lambda ()
                  (for/sym-set ([w bindings])
                    (values (substitute (rule-head r) (car w)) (cdr w))))))
    (values (time-it! add-set-union-time! (lambda () (set-union acc fresh)))
            (for/fold ([derived derived]) ([(k g) fresh]) (cons k derived)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Saturation

;; Semi-naive fixpoint: the delta is the keys whose guard changed, and
;; guards are read from the accumulated set rather than the delta.
;; Predicates in `deterministic` are derived with the guard true.
(define (saturate-semi base rules [deterministic (hasheq)])
  (define base-keys (for/list ([(k g) base]) k))
  (define indexed (make-hash))
  (for ([k base-keys]) (hash-set! indexed k #t))
  (let loop ([full base] [full-idx (index-add (hash) base-keys)] [delta base-keys])
    (define-values (next derived) (immediate-semi full full-idx delta rules deterministic))
    (define changed (changed-keys full next (remove-duplicates derived)))
    (cond
      [(null? changed) full]
      [else
       (define new-keys
         (for/list ([k changed] #:unless (hash-ref indexed k #f))
           (hash-set! indexed k #t)
           k))
       (loop next
             (time-it! add-index-time! (lambda () (index-add full-idx new-keys)))
             changed)])))

;; Predicates the goals can depend on: their own, and those in the body
;; of any rule for one, transitively. Keyed by name alone, so a name used
;; at two arities keeps both.
(define (relevant-predicates goals rules)
  (define keep (make-hasheq))
  (let loop ([todo (map fact-name goals)])
    (unless (null? todo)
      (define p (car todo))
      (cond
        [(hash-ref keep p #f) (loop (cdr todo))]
        [else
         (hash-set! keep p #t)
         (loop (append (for*/list ([r (in-list rules)]
                                   #:when (eq? (fact-name (rule-head r)) p)
                                   [b (in-list (rule-body r))])
                         (fact-name b))
                       (cdr todo)))])))
  keep)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Magic sets
;;
;; Each rule is copied once per binding pattern (adornment) its head is
;; called with, guarded by a magic atom holding the bound arguments, and
;; magic rules pass bindings left to right into the body's derived atoms.
;; Every copy still derives into the original predicate, so a tuple the
;; magic atoms cover gets every derivation it has in the full program.
;;
;; Magic predicates are deterministic: their tuples are relevant in some
;; world, so they hold in all of them. That over-approximates each
;; world's relevant set, while the real body atoms keep their guards, so
;; every covered tuple's guard is exact.

;; An adornment is a list of booleans: #t where the argument is bound.
(define (adornment atom bound)
  (for/list ([a (fact-args atom)])
    (or (not (symbol? a)) (hash-ref bound a #f))))

(define (magic-name p ad)
  (string->symbol
   (format "magic:~a:~a" p (list->string (for/list ([b ad]) (if b #\b #\f))))))

(define (magic-atom atom ad)
  (fact (magic-name (fact-name atom) ad)
        (for/list ([a (fact-args atom)] [b ad] #:when b) a)))

(define (bind-vars bound atom)
  (for/fold ([bound bound]) ([a (fact-args atom)] #:when (symbol? a))
    (hash-set bound a #t)))

;; Returns the rewritten rules, the magic seeds as base facts, and a hash
;; from each derived predicate to the adornments it was called with.
(define (magic-rewrite goals rules)
  (define derived (for/hasheq ([r (in-list rules)]) (values (fact-name (rule-head r)) #t)))
  (define (derived? a) (hash-ref derived (fact-name a) #f))
  (define called (make-hasheq))
  (define todo '())
  (define (call! atom ad)
    (define ads (hash-ref called (fact-name atom) '()))
    (unless (member ad ads)
      (hash-set! called (fact-name atom) (cons ad ads))
      (set! todo (cons (cons (fact-name atom) ad) todo))))
  (define seeds
    (for/list ([g (in-list goals)] #:when (derived? g))
      (define ad (adornment g (hash)))
      (call! g ad)
      (cons (magic-atom g ad) 1)))
  (define out '())
  (let loop ()
    (unless (null? todo)
      (match-define (cons p ad) (car todo))
      (set! todo (cdr todo))
      (for ([r (in-list rules)]
            #:when (and (eq? (fact-name (rule-head r)) p)
                        (= (length (fact-args (rule-head r))) (length ad))))
        (define head (rule-head r))
        (define m (magic-atom head ad))
        (for/fold ([bound (for/fold ([bound (hash)])
                                    ([a (fact-args head)] [b ad] #:when (and b (symbol? a)))
                            (hash-set bound a #t))]
                   [prefix '()])
                  ([atom (in-list (rule-body r))])
          (when (derived? atom)
            (define ad* (adornment atom bound))
            (call! atom ad*)
            (define mh (magic-atom atom ad*))
            (unless (and (null? prefix) (equal? mh m))
              (set! out (cons (rule mh (cons m (reverse prefix))) out))))
          (values (bind-vars bound atom) (cons atom prefix)))
        (set! out (cons (rule head (cons m (rule-body r))) out)))
      (loop)))
  (values (reverse out) seeds called))

;; Results computed for particular goals, mapped to a predicate saying
;; which facts they cover, so a query outside them is an error rather
;; than a wrong #f.
(define pruned-results (make-weak-hasheq))

;; With #:goals, only what those facts can depend on is derived: first by
;; predicate, then, with #:magic?, by the constants the goals mention. A
;; pruned base fact is an independent variable no kept guard mentions, so
;; every goal's probability is unchanged.
(define (run-datalog base-fact-probs rules #:goals [goals #f] #:magic? [magic? #t])
  (cond
    [(not goals) (saturate-semi (make-base-set base-fact-probs) rules)]
    [else
     (define keep (relevant-predicates goals rules))
     (define (kept? f) (hash-ref keep (fact-name f) #f))
     (define base (filter (lambda (fp) (kept? (car fp))) base-fact-probs))
     (define kept-rules (filter (lambda (r) (kept? (rule-head r))) rules))
     (cond
       [magic?
        (define-values (magic-rules seeds called) (magic-rewrite goals kept-rules))
        (define deterministic
          (for*/hasheq ([(p ads) (in-hash called)] [ad (in-list ads)])
            (values (magic-name p ad) #t)))
        (define result
          ;; seeds are certain, so they take no variable, and are kept out
          ;; of the ordering, where their constants would reorder the rest
          (saturate-semi (set-union (make-base-set base) (make-base-set seeds))
                         magic-rules deterministic))
        (define (covered? f)
          (and (kept? f)
               (let ([ads (hash-ref called (fact-name f) #f)])
                 (or (not ads)
                     (for/or ([ad (in-list ads)]
                              #:when (= (length ad) (length (fact-args f))))
                       (guard-known-true? (set-member? result (magic-atom f ad))))))))
        (hash-set! pruned-results result covered?)
        result]
       [else
        (define result (saturate-semi (make-base-set base) kept-rules))
        (hash-set! pruned-results result kept?)
        result])]))

;; The guard of `f` in `result`.
(define (result-guard who where result f)
  (define covered? (hash-ref pruned-results result #f))
  (when (and covered? (not (covered? f)))
    (probalog-error
     who where
     (string-append
      "~a was not computed\n"
      "  only facts the module's queries and observations depend on are derived")
     f))
  (set-member? result f))

;; Reports a runtime failure the way the parser reports a syntax one:
;; prefixed with the source location of the statement responsible.
;; `where` is that location, already formatted, and is #f when these
;; are called directly from Racket rather than from a statement.
(define (probalog-error who where fmt . args)
  (raise (make-exn:fail (format "~a: ~a" (or where who) (apply format fmt args))
                        (current-continuation-marks))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Weighing and conditioning guards
;;
;; Roulette cannot see into a BDD, so its `query`/`observe!` are bypassed
;; and the same semantics computed directly: conditioning conjoins
;; evidence, a marginal is P(fact and evidence) / P(evidence).

(define evidence (box (guard-true)))
(define (current-evidence) (unbox evidence))

;; Guards do not survive a reset of the manager, so neither can the
;; evidence built out of them.
(add-reset-hook! (lambda () (set-box! evidence (guard-true))))

;; Whether a guard can hold in some world satisfying the evidence.
(define (satisfiable? g) (not (guard-known-false? g)))

;; A pmf over #t/#f for a guard, conditioned on the evidence so far, or
;; #f when no world satisfies the evidence at all -- matching what
;; Roulette's `query` returns in that case.
;;
;; An outcome is dropped only when it is impossible, which is what
;; leaves a certain answer as a single-outcome pmf for
;; `query-result->string` to print as #t or #f. An outcome that is
;; merely too unlikely for a double to distinguish from 0 is kept.
(define (guard->pmf g)
  (define ev (current-evidence))
  (define yes (guard-and g ev))
  (define no (guard-and (guard-not g) ev))
  (cond
    [(not (satisfiable? ev)) #f]
    [(not (satisfiable? no)) (for/pmf ([v (in-list '(#t))] [pr (in-list '(1))])
                               (values v pr))]
    [(not (satisfiable? yes)) (for/pmf ([v (in-list '(#f))] [pr (in-list '(1))])
                                (values v pr))]
    [else
     (define p (/ (guard-prob yes) (guard-prob ev)))
     (for/pmf ([value (in-list (list #t #f))]
               [prob (in-list (list p (- 1 p)))])
       (values value prob))]))

;; Condition all later queries on `g` holding.
(define (add-evidence! g)
  (set-box! evidence (guard-and (current-evidence) g)))

(define (query-fact result f #:where [where #f])
  (define pmf (guard->pmf (result-guard 'query-fact where result f)))
  (unless pmf
    (probalog-error
     'query-fact where
     (string-append
      "no possible world remains, so ~a has no probability\n"
      "  the observations made so far cannot all hold at once")
     f))
  pmf)

(define (query-result->string pmf)
  (define outcomes (for/list ([(value prob) (in-pmf pmf)]) value))
  (if (= (length outcomes) 1)
      (format "~a" (car outcomes))
      (format "~a" pmf)))

;; Whether `guard` can still take the given value in some world that
;; satisfies every observation made so far.
(define (possible? guard value)
  (define ev (current-evidence))
  (and (satisfiable? ev)
       (satisfiable? (guard-and (if value guard (guard-not guard)) ev))))

;; Conditioning on something impossible divides by zero, and every
;; later query would silently report nothing rather than fail. So an
;; observation is checked before it is made, while it can still be
;; blamed on the statement that caused it.
(define (check-observable! who where guard value what)
  (unless (possible? guard value)
    (probalog-error
     who where
     (string-append
      "cannot observe ~a: it has probability 0\n"
      "  given the base facts, the rules, and any earlier observations,\n"
      "  there is no possible world in which this holds")
     what)))

;; Condition on the fact being present (or absent); all later queries
;; see the posterior.
(define (observe-fact result f #:where [where #f])
  (define guard (result-guard 'observe-fact where result f))
  (check-observable! 'observe-fact where guard #t f)
  (add-evidence! guard))

(define (observe-not-fact result f #:where [where #f])
  (define guard (result-guard 'observe-not-fact where result f))
  (check-observable! 'observe-not-fact where guard #f
                     (format "the absence of ~a" f))
  (add-evidence! (guard-not guard)))

;; Lower-level: condition on an arbitrary guard formula, e.g. a
;; disjunction of several facts being present.
(define (observe-guard g #:where [where #f])
  (check-observable! 'observe-guard where g #t "this formula")
  (add-evidence! g))