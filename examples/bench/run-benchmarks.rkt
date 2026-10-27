#lang racket/base

;; CI entry point: runs the benchmark programs and writes one JSON record
;; describing the commit that produced them, so results from successive
;; commits can be compared.
;;
;;   racket run-benchmarks.rkt [-o results.json] [SHA] [MESSAGE]

(require json
         racket/cmdline
         racket/list
         racket/port
         (only-in "probalog-examples.rkt" benchmark-results aggregate-timing))

;; `probalog-examples.rkt` runs its benchmarks at module level and prints
;; a line per benchmark, so requiring it is what does the work. The
;; printing is useful in a CI log; the numbers come back through
;; `benchmark-results`.

(define (record->jsexpr r)
  (hasheq 'name             (list-ref r 0)
          'wall_ms          (exact->inexact (list-ref r 1))
          'find_bindings_ms (exact->inexact (list-ref r 2))
          'guard_build_ms   (exact->inexact (list-ref r 3))
          'set_union_ms     (exact->inexact (list-ref r 4))
          'index_ms         (exact->inexact (list-ref r 5))
          'bdd_ms           (exact->inexact (list-ref r 6))))

(define (main)
  (define out-path (box "results.json"))
  (define positional
    (parse-command-line
     "run-benchmarks" (current-command-line-arguments)
     `((once-each
        [("-o" "--output") ,(lambda (_ p) (set-box! out-path p))
                           ("Where to write the JSON record" "path")]))
     (lambda (_ . rest) rest)
     '("sha" "message")))

  (define sha (if (pair? positional) (first positional) "unknown"))
  (define message (if (> (length positional) 1) (second positional) ""))

  (define-values (wall bindings guard union index bdd)
    (aggregate-timing benchmark-results))

  (define record
    (hasheq 'commit     sha
            'message    message
            'timestamp  (current-seconds)
            'racket     (version)
            'benchmarks (map record->jsexpr benchmark-results)
            'total      (hasheq 'wall_ms          (exact->inexact wall)
                                'find_bindings_ms (exact->inexact bindings)
                                'guard_build_ms   (exact->inexact guard)
                                'set_union_ms     (exact->inexact union)
                                'index_ms         (exact->inexact index)
                                'bdd_ms           (exact->inexact bdd))))

  (call-with-output-file (unbox out-path)
    (lambda (o) (write-json record o) (newline o))
    #:exists 'replace)

  (printf "\ntotal wall: ~ams across ~a benchmarks -> ~a\n"
          (exact->inexact wall) (length benchmark-results) (unbox out-path)))

(module+ main (main))
