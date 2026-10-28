#lang racket
;; Standalone timing benchmark and plot: runs six programs, aggregates
;; where saturation spends its time, and renders a stacked bar. Uses
;; plot/no-gui, so `racket timing-plot.rkt` works as a script.
;;
;; The six press on different parts of the engine so none dominates:
;;
;;   ring        long sparse cycle          smokers   recursion, 3 clauses
;;   chordring   dense cycle, re-derived    pointsto  mutual recursion
;;   dag         wide converging, acyclic   sg        recursive atom in middle
;;
;; Only saturation is timed, so `dag` is a smaller slice: its cost is in
;; the query, not saturation. Cost grows steeply in the size parameters,
;; so re-calibrate rather than nudging blindly.
(require probalog/core
         plot/no-gui
         "timing-programs.rkt")
(provide probalog-timing-split-plot)

;; Timings come from subtracting the exported accumulators before and
;; after. Read-only access across modules is fine; set!-ing an imported
;; variable is not, which is why we subtract rather than reset.
(define (run-benchmark name make-program)
  (define-values (facts rules query-target) (make-program))
  (define bindings-before total-find-bindings-time)
  (define guard-before    total-guard-build-time)
  (define union-before    total-set-union-time)
  (define index-before    total-index-time)
  (define bdd-before      total-bdd-time)
  (define wall-start (current-inexact-monotonic-milliseconds))
  (define result (run-datalog facts rules))
  (define wall (- (current-inexact-monotonic-milliseconds) wall-start))
  (printf "~a: ~a facts, ~a rules, ~ams -- ~a: ~a\n"
          name (length facts) (length rules) (~r wall #:precision 0)
          query-target (query-fact result query-target))
  (flush-output)
  (list name wall
        (- total-find-bindings-time    bindings-before)
        (- total-guard-build-time      guard-before)
        (- total-set-union-time        union-before)
        (- total-index-time            index-before)
        (- total-bdd-time              bdd-before)))

(define (aggregate-timing results)
  (for/fold ([wall 0] [bind 0] [guard 0] [union 0] [idx 0] [bdd 0])
            ([r results])
    (values (+ wall  (list-ref r 1))
            (+ bind  (list-ref r 2))
            (+ guard (list-ref r 3))
            (+ union (list-ref r 4))
            (+ idx   (list-ref r 5))
            (+ bdd   (list-ref r 6)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Run benchmarks and build the chart

(define results
  (for/list ([b benchmarks])
    (run-benchmark (car b) (cadr b))))

(define-values (wall bind guard union idx bdd) (aggregate-timing results))

;; Each program's share of the total, so it is visible at a glance
;; whether any one of them is dictating the split.
(printf "\ninside rsdd: ~ams (~a% of total), spread across the phases below\n"
        (~r bdd #:precision 0) (~r (* 100 (/ bdd wall)) #:precision 1))

(printf "\nshare of total per benchmark:\n")
(for ([r results])
  (printf "  ~a ~a%\n"
          (~a (car r) #:width 12)
          (~r (* 100 (/ (list-ref r 1) wall)) #:precision 1)))

(define named
  (list (cons "find-bindings"      bind)
        (cons "deriving heads"     guard)
        (cons "index construction" idx)
        (cons "set-union"          union)))

(define parts
  (sort (append named
                (list (cons "other" (max 0 (- wall (apply + (map cdr named)))))))
        > #:key cdr))

(define total (apply + (map cdr parts)))

(define probalog-timing-split-plot (plot-pict
                                    (stacked-histogram
                                     (list (vector "" (map cdr parts)))
                                     #:invert? #t
                                     #:labels (for/list ([p parts])
                                                (format "~a (~a%)"
                                                        (car p)
                                                        (~r (* 100 (/ (cdr p) total)) #:precision 1))))
                                    #:title (format "timing split across ~a benchmarks (~ams total, ~a% inside rsdd)"
                                                    (length results) (~r wall #:precision 0)
                                                    (~r (* 100 (/ bdd wall)) #:precision 0))
                                    #:x-label "time (ms)"
                                    #:y-label #f
                                    #:legend-anchor 'outside-right-top
                                    #:width 800
                                    #:height 300))

probalog-timing-split-plot
