#lang racket/base

;; Engine measurements for collect.py, as JSON on stdout.
;;
;;   racket collect-engine.rkt programs DIR      write the benchmark programs
;;   racket collect-engine.rkt engine FILE ...   saturation with magic sets
;;   racket collect-engine.rkt mode MODE FILE    saturation in one mode
;;   racket collect-engine.rkt reference FILE ...  ground-truth check

(require racket/match racket/list racket/port racket/string racket/file racket/path json
         probalog/core
         (only-in probalog/lang/parser parse-probalog)
         (only-in probalog/rsdd rsdd-nodes)
         (file "../../reference.rkt"))

(define here (let-values ([(dir _n _d) (split-path (syntax-source #'here))]) dir))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Programs

(define ns (make-base-namespace))
(namespace-attach-module (current-namespace) 'probalog/core ns)
(parameterize ([current-namespace ns]) (namespace-require 'probalog/core))

;; Facts, rules, and the statements in order: (query f) or (observe f present?).
(define (load-program path)
  (define forms
    (call-with-input-file path
      (lambda (in) (read-line in) (map syntax->datum (parse-probalog in path)))))
  (for/fold ([fs '()] [rs '()] [ss '()]
             #:result (values (reverse fs) (reverse rs) (reverse ss)))
            ([f (in-list forms)])
    (match f
      [`(#%probalog-fact-entry ,a ,p) (values (cons (cons (eval a ns) (eval p ns)) fs) rs ss)]
      [`(#%probalog-rule-entry ,r . ,_) (values fs (cons (eval r ns) rs) ss)]
      [`(#%probalog-query-entry ,a) (values fs rs (cons (list 'query (eval a ns)) ss))]
      [`(#%probalog-observe-entry ,a ,neg) (values fs rs (cons (list 'observe (eval a ns) (not neg)) ss))]
      [_ (values fs rs ss)])))

(define (write-program path facts rules goals)
  (with-output-to-file path #:exists 'replace
    (lambda ()
      (printf "#lang probalog\n")
      (for ([fp (in-list facts)]) (printf "~a :: ~a.\n" (car fp) (cdr fp)))
      (for ([r (in-list rules)])
        (printf "~a :- ~a.\n" (rule-head r)
                (string-join (for/list ([b (in-list (rule-body r))]) (format "~a" b)) ", ")))
      (for ([g (in-list goals)]) (printf "? ~a.\n" g)))))

(define (instantiate path)
  (parameterize ([current-output-port (open-output-nowhere)])
    (dynamic-require path #f))
  (module->namespace path))

(define (dump-programs dir)
  (make-directory* dir)
  (define ci (instantiate (build-path here "probalog-examples.rkt")))
  (for ([b (in-list (eval 'benchmarks ci))])
    (define-values (facts rules) ((cadr b)))
    (write-program (build-path dir (format "ci-~a.rkt" (car b))) facts rules (list (caddr b))))
  (define tp (instantiate (build-path here "timing-plot.rkt")))
  (for ([b (in-list (eval 'benchmarks tp))])
    (define-values (facts rules goal) ((cadr b)))
    (write-program (build-path dir (format "timing-~a.rkt" (car b))) facts rules (list goal))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Engine

(define timeout-s 10)
(define memory-limit (* 3 1024 1024 1024))

(define (stat key) (cdr (assq key (guard-stats))))

;; Runs the statements against a result, as a module would.
(define (replay result stmts)
  (with-handlers ([exn:fail? (lambda (e) (list (string-append "error: " (exn-message e))))])
    (for/list ([s (in-list stmts)])
      (match s
        [(list 'query f) (query-result->string (query-fact result f))]
        [(list 'observe f #t) (observe-fact result f) "observed"]
        [(list 'observe f #f) (observe-not-fact result f) "observed absent"]))))

;; One saturation in its own thread, under a time and memory limit.
(define (run-once facts rules stmts kw)
  (reset-guards!)
  (collect-garbage)
  (define ch (make-channel))
  (define cust (make-custodian))
  (custodian-limit-memory cust memory-limit cust)
  (parameterize ([current-custodian cust])
    (thread
     (lambda ()
       (define before (list total-find-bindings-time total-guard-build-time
                            total-set-union-time total-index-time total-bdd-time))
       (define t0 (current-inexact-monotonic-milliseconds))
       (define r (keyword-apply run-datalog (map car kw) (map cdr kw) (list facts rules)))
       (define ms (- (current-inexact-monotonic-milliseconds) t0))
       (define after (list total-find-bindings-time total-guard-build-time
                           total-set-union-time total-index-time total-bdd-time))
       (define split (map - after before))
       (define goals (for/list ([s (in-list stmts)]) (cadr s)))
       (channel-put
        ch
        (hasheq 'status "ok"
                'ms ms
                'find_bindings_ms (list-ref split 0)
                'guard_build_ms (list-ref split 1)
                'set_union_ms (list-ref split 2)
                'index_ms (list-ref split 3)
                'rsdd_ms (list-ref split 4)
                'guard_ops (stat 'guard-ops)
                'apply_calls (stat 'apply-calls)
                'variables (stat 'variables)
                'tuples (for/sum ([(k g) r]) 1)
                'goal_bdd_nodes
                (with-handlers ([exn:fail? (lambda (e) 'null)])
                  (for/list ([g (in-list goals)]) (rsdd-nodes (set-member? r g))))
                'answers (replay r stmts))))))
  (define result (sync/timeout timeout-s ch (thread-dead-evt-of cust)))
  (custodian-shutdown-all cust)
  (cond
    [(hash? result) result]
    [result (hasheq 'status "memory limit")]
    [else (hasheq 'status "timeout")]))

;; Fires if the custodian is shut down by its memory limit.
(define (thread-dead-evt-of cust)
  (wrap-evt (make-custodian-box cust #t) (lambda (_) 'killed)))

(define (median xs) (list-ref (sort xs <) (quotient (length xs) 2)))

;; Up to three runs, fewer when one is slow; the reported run is the median.
(define (measure facts rules stmts kw)
  (define first (run-once facts rules stmts kw))
  (cond
    [(not (equal? (hash-ref first 'status) "ok")) first]
    [else
     (define runs
       (if (> (hash-ref first 'ms) 2000)
           (list first)
           (cons first (for/list ([_ 2]) (run-once facts rules stmts kw)))))
     (define ok (filter (lambda (r) (equal? (hash-ref r 'status) "ok")) runs))
     (define mid (median (map (lambda (r) (hash-ref r 'ms)) ok)))
     (define chosen (findf (lambda (r) (= (hash-ref r 'ms) mid)) ok))
     (hash-set chosen 'runs_ms (map (lambda (r) (hash-ref r 'ms)) ok))]))

(define (mode-keywords mode goals)
  (define g (if (null? goals) #f goals))
  (case mode
    [("full") '()]
    [("relevance") (list (cons '#:goals g) (cons '#:magic? #f))]
    [("magic") (list (cons '#:goals g) (cons '#:magic? #t))]))

(define (engine path)
  (define-values (facts rules stmts) (load-program path))
  (define goals (for/list ([s (in-list stmts)]) (cadr s)))
  (for/fold ([h (hasheq 'program (path->string (file-name-from-path path))
                        'base_facts (length facts)
                        'uncertain_facts (count (lambda (fp) (< 0 (cdr fp) 1)) facts)
                        'rules (length rules)
                        'statements (length stmts))])
            ([mode (in-list '("magic"))])
    (hash-set h (string->symbol mode) (measure facts rules stmts (mode-keywords mode goals)))))

(define (one-mode mode path)
  (define-values (facts rules stmts) (load-program path))
  (measure facts rules stmts (mode-keywords mode (for/list ([s (in-list stmts)]) (cadr s)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Reference

(define (number->json x) (if (exact? x) (exact->inexact x) x))

(define (reference path)
  (define name (path->string (file-name-from-path path)))
  (define t0 (current-inexact-monotonic-milliseconds))
  (with-handlers ([(lambda (e) (and (exn:fail? e) (regexp-match? #rx"uncertain facts, limit" (exn-message e))))
                   (lambda (e) (hasheq 'program name 'status "skipped" 'reason (exn-message e)))])
    (define ref (reference-answers path))
    (define eng (engine-answers path))
    (define rows
      (for/list ([i (in-range (max (length ref) (length eng)))])
        (define r (and (< i (length ref)) (list-ref ref i)))
        (define e (and (< i (length eng)) (list-ref eng i)))
        (define (side x)
          (cond [(not x) 'null]
                [(eq? (car x) 'error) (hasheq 'error (cdr x))]
                [else (hasheq 'label (car x) 'probability (number->json (cdr x)))]))
        (hasheq 'reference (side r) 'engine (side e)
                'agree (and r e
                            (if (eq? (car r) 'error)
                                (eq? (car e) 'error)
                                (and (equal? (car r) (car e))
                                     (<= (abs (- (cdr r) (cdr e))) 1e-9)))))))
    (hasheq 'program name
            'status (if (andmap (lambda (r) (hash-ref r 'agree)) rows) "agree" "disagree")
            'ms (- (current-inexact-monotonic-milliseconds) t0)
            'rows rows)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(module+ main
  (match (vector->list (current-command-line-arguments))
    [(list "programs" dir) (dump-programs dir)]
    [(list "mode" mode file) (write-json (one-mode mode (path->complete-path file)))]
    [(list "engine" files ...)
     (write-json (for/list ([f (in-list files)]) (engine (path->complete-path f))))]
    [(list "reference" files ...)
     (write-json (for/list ([f (in-list files)]) (reference (path->complete-path f))))]))
