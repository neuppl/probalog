#lang racket
(require probalog/core)
(provide benchmark-results aggregate-timing run-benchmarks)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Program generators
;;
;; Each returns (values facts rules), facts being a list of
;; (cons fact probability).

;; A layered DAG, fully connected between adjacent layers, with
;; width^layers distinct SRC->SINK paths -- stresses guard
;; construction over many converging derivations.
(define (make-layered-dag layers width [edge-prob 0.9])
  (define (node l i) (format "L~a_~a" l i))
  (define facts
    (append
     (for/list ([j (in-range width)])
       (cons (fact 'Edge (list "SRC" (node 0 j))) edge-prob))
     (for*/list ([i (in-range (sub1 layers))]
                 [j (in-range width)]
                 [k (in-range width)])
       (cons (fact 'Edge (list (node i j) (node (add1 i) k))) edge-prob))
     (for/list ([j (in-range width)])
       (cons (fact 'Edge (list (node (sub1 layers) j) "SINK")) edge-prob))))
  (define rules
    (list (rule (fact 'Path (list 'x 'y))
                (list (fact 'Edge (list 'x 'y))))
          (rule (fact 'Path (list 'x 'z))
                (list (fact 'Path (list 'x 'y))
                      (fact 'Edge (list 'y 'z))))))
  (values facts rules))

;; A ring of n nodes with chords k ahead. The cycles re-derive facts
;; many ways, so guards accumulate syntactically redundant disjuncts
;; that only a semantic check sees through -- stresses fixpoint
;; detection.
(define (make-cyclic-ring n [chord 3] [edge-prob 0.85])
  (define (node i) (format "N~a" i))
  (define facts
    (append
     (for/list ([i (in-range n)])
       (cons (fact 'Edge (list (node i) (node (modulo (add1 i) n)))) edge-prob))
     (for/list ([i (in-range n)])
       (cons (fact 'Edge (list (node i) (node (modulo (+ i chord) n)))) edge-prob))))
  (define rules
    (list (rule (fact 'Reach (list 'x 'y))
                (list (fact 'Edge (list 'x 'y))))
          (rule (fact 'Reach (list 'x 'z))
                (list (fact 'Reach (list 'x 'y))
                      (fact 'Edge (list 'y 'z))))))
  (values facts rules))

;; A balanced binary ancestry tree with derived relations on top:
;; many distinct predicates and three-clause bodies, so it stresses
;; the join across predicates rather than deep recursion.
(define (make-family depth [parent-prob 0.95])
  (define (person i) (format "P~a" i))
  (define size (sub1 (expt 2 depth)))
  (define facts
    (append
     ;; parent i -> children 2i+1, 2i+2
     (for*/list ([i (in-range size)]
                 [c (in-list (list (+ (* 2 i) 1) (+ (* 2 i) 2)))]
                 #:when (< c size))
       (cons (fact 'Parent (list (person i) (person c))) parent-prob))
     ;; alternating genders
     (for/list ([i (in-range size)])
       (cons (fact (if (even? i) 'Male 'Female) (list (person i))) 1))))
  (define rules
    (list (rule (fact 'Ancestor (list 'x 'y))
                (list (fact 'Parent (list 'x 'y))))
          (rule (fact 'Ancestor (list 'x 'z))
                (list (fact 'Ancestor (list 'x 'y))
                      (fact 'Parent (list 'y 'z))))
          (rule (fact 'Grandfather (list 'x 'y))
                (list (fact 'Parent (list 'x 'z))
                      (fact 'Parent (list 'z 'y))
                      (fact 'Male (list 'x))))
          (rule (fact 'Grandmother (list 'x 'y))
                (list (fact 'Parent (list 'x 'z))
                      (fact 'Parent (list 'z 'y))
                      (fact 'Female (list 'x))))
          (rule (fact 'Son (list 'x 'y))
                (list (fact 'Parent (list 'y 'x))
                      (fact 'Male (list 'x))))
          (rule (fact 'Daughter (list 'x 'y))
                (list (fact 'Parent (list 'y 'x))
                      (fact 'Female (list 'x))))))
  (values facts rules))

;; A layered dependency graph: a package is vulnerable if any
;; dependency is. Mixed base probabilities keep guards genuinely
;; symbolic rather than collapsing.
(define (make-supply-chain layers width)
  (define (pkg l i) (format "pkg~a_~a" l i))
  (define facts
    (append
     ;; each depends on two in the layer below
     (for*/list ([l (in-range (sub1 layers))]
                 [i (in-range width)]
                 [d (in-list (list i (modulo (add1 i) width)))])
       (cons (fact 'DependsOn (list (pkg l i) (pkg (add1 l) d))) 0.9))
     ;; leaves carry direct risk
     (for/list ([i (in-range width)])
       (cons (fact 'HasCVE (list (pkg (sub1 layers) i))) (if (even? i) 0.3 0.15)))
     ;; maintenance status
     (for*/list ([l (in-range layers)]
                 [i (in-range width)])
       (cons (fact 'Unmaintained (list (pkg l i))) 0.2))))
  (define rules
    (list (rule (fact 'Vulnerable (list 'p))
                (list (fact 'HasCVE (list 'p))))
          (rule (fact 'Vulnerable (list 'p))
                (list (fact 'DependsOn (list 'p 'q))
                      (fact 'Vulnerable (list 'q))))
          (rule (fact 'NeedsAudit (list 'p))
                (list (fact 'Vulnerable (list 'p))
                      (fact 'Unmaintained (list 'p))))))
  (values facts rules))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Benchmarks
;;
;; (name thunk query-fact), the fact being a sanity check that the run
;; did something. Cost does not grow smoothly in the size parameters --
;; supply-chain takes 10ms at (6 8), 3.9s at (8 8) and 169ms at (8 10) --
;; so re-measure after any change rather than assuming a bigger size
;; costs proportionally more.
(define benchmarks
  (list
   (list "layered-dag"
         (lambda () (make-layered-dag 6 3))
         (fact 'Path (list "SRC" "SINK")))
   (list "cyclic-ring"
         (lambda () (make-cyclic-ring 9 3))
         (fact 'Reach (list "N0" "N5")))
   (list "family"
         (lambda () (make-family 7))
         (fact 'Ancestor (list "P0" "P100")))
   (list "supply-chain"
         (lambda () (make-supply-chain 8 10))
         (fact 'NeedsAudit (list "pkg0_0")))))

;; Returns (name wall bindings guard union index bdd). Timings
;; subtract the exported accumulators before and after: set!-ing an
;; imported variable isn't allowed, so we subtract rather than reset.
(define (run-benchmark name make-program query-target)
  (define-values (facts rules) (make-program))
  (define bindings-before total-find-bindings-time)
  (define guard-before total-guard-build-time)
  (define union-before total-set-union-time)
  (define index-before total-index-time)
  (define bdd-before total-bdd-time)
  (define wall-start (current-inexact-monotonic-milliseconds))
  (define result (run-datalog facts rules))
  (define wall (- (current-inexact-monotonic-milliseconds) wall-start))
  (printf "~a: ~a facts, ~a rules, ~ams -- ~a: ~a\n"
          name (length facts) (length rules) wall
          query-target (query-fact result query-target))
  (flush-output)
  (list name wall
        (- total-find-bindings-time bindings-before)
        (- total-guard-build-time guard-before)
        (- total-set-union-time union-before)
        (- total-index-time index-before)
        (- total-bdd-time bdd-before)))

(define (run-benchmarks)
  (for/list ([b benchmarks])
    (run-benchmark (car b) (cadr b) (caddr b))))

;; Sums each timing category across every benchmark. The rsdd time
;; overlaps the others rather than adding to them.
(define (aggregate-timing results)
  (for/fold ([wall 0] [bindings 0] [guard 0] [union 0] [index 0] [bdd 0])
            ([r results])
    (values (+ wall (list-ref r 1))
            (+ bindings (list-ref r 2))
            (+ guard (list-ref r 3))
            (+ union (list-ref r 4))
            (+ index (list-ref r 5))
            (+ bdd (list-ref r 6)))))

(define benchmark-results (run-benchmarks))