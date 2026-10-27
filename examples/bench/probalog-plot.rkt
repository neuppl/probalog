#lang racket
(require plot
         "probalog-examples.rkt")

;; Requiring probalog-examples.rkt runs the benchmarks. Its results
;; cross the module boundary as ordinary Racket lists and numbers, so
;; plotting them here needs no interaction with roulette.

;; `plot` called inside a function has its return value discarded, so
;; DrRacket never auto-displays it; this makes each call open a window.
(plot-new-window? #t)

;; Timing breakdown as one stacked horizontal bar: stacked-histogram
;; takes (vector label (list value ...)), one segment per value.
(define (plot-breakdown parts title)
  (define total (apply + (map cdr parts)))
  (plot (stacked-histogram
         (list (vector "" (map cdr parts)))
         #:invert? #t
         #:labels (for/list ([p parts])
                    (format "~a (~a%)"
                            (car p)
                            (~r (* 100 (/ (cdr p) total)) #:precision 1))))
        #:title title
        #:x-label "time (ms)"
        #:y-label #f
        #:legend-anchor 'outside-right-top))

;; "other" is wall-clock minus everything accounted for: GC and misc.
(define (show-timing-split [results benchmark-results])
  (define-values (wall bindings guard union index bdd)
    (aggregate-timing results))
  (define named
    (list (cons "find-bindings" bindings)
          (cons "deriving heads" guard)
          (cons "index construction" index)
          (cons "set-union" union)))
  (define parts
    (append named
            (list (cons "other" (max 0 (- wall (apply + (map cdr named))))))))
  (plot-breakdown (sort parts > #:key cdr)
                  (format "timing split across ~a benchmarks (~ams total, ~a% inside rsdd)"
                          (length results) (~r wall #:precision 0)
                          (~r (* 100 (/ bdd wall)) #:precision 0))))

(show-timing-split)
