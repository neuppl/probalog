#lang racket/base

;; Ground-truth probalog: the distribution semantics computed literally.
;; Every world -- every subset of the uncertain base facts -- is
;; enumerated, its least model is computed by Soufflé, and a query's
;; probability is the weight of the worlds deriving it, conditioned on
;; the observations before it.
;;
;; All worlds go to Soufflé in one run: every relation gains a world
;; column, and base fact i holds in world w when bit i of w is set.
;;
;; Exponential in the number of uncertain facts, so this is for checking
;; the engine on small programs. It shares only the parser with it.
;;
;;   racket reference.rkt FILE ...        compare the engine against it
;;
;; Needs `souffle` on the PATH, or SOUFFLE set to it.

(provide reference-answers engine-answers check-file)

(require racket/match racket/list racket/string racket/port
         racket/file racket/system racket/vector
         "lang/parser.rkt")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Reading a program

;; An atom is (name . args). In a rule an argument may be a variable,
;; represented as a symbol; constants are strings or numbers.
(define (form->atom d)
  (match d
    [`(fact ',name (list ,args ...))
     (cons name (for/list ([a (in-list args)])
                  (match a [`',v v] [c c])))]))

;; Returns base-fact events (atom . probability) in declaration order,
;; rules (head . body), and the queries and observations in source order.
;; Each declaration is its own event, as in the engine: declaring a fact
;; twice makes it hold if either independent declaration does.
(define (read-program path)
  (define forms
    (call-with-input-file path
      (lambda (in)
        (read-line in)                    ; the #lang line
        (map syntax->datum (parse-probalog in path)))))
  (for/fold ([events '()] [rules '()] [stmts '()]
             #:result (values (reverse events) (reverse rules) (reverse stmts)))
            ([f (in-list forms)])
    (match f
      [`(#%probalog-fact-entry ,a ,p)
       (values (cons (cons (form->atom a) (inexact->exact p)) events) rules stmts)]
      [`(#%probalog-rule-entry (rule ,h (list ,b ...)) . ,_)
       (values events (cons (cons (form->atom h) (map form->atom b)) rules) stmts)]
      [`(#%probalog-query-entry ,a)
       (values events rules (cons (list 'query (form->atom a)) stmts))]
      [`(#%probalog-observe-entry ,a ,negated?)
       (values events rules (cons (list 'observe (form->atom a) (not negated?)) stmts))]
      [_ (values events rules stmts)])))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Least models, by Soufflé

;; A predicate becomes one relation per arity, with the world first.
;; Constants become symbols tagged by type, so "1" and 1 stay distinct.
(define (relation atom) (format "r_~a_~a" (car atom) (length (cdr atom))))

(define (term t)
  (cond
    [(symbol? t) (format "v_~a" t)]
    [(string? t) (format "\"s:~a\"" (regexp-replace* #rx"[\"\\\\]" t "\\\\&"))]
    [else (format "\"n:~a\"" t)]))

(define (literal atom)
  (format "~a(~a)" (relation atom)
          (string-join (cons "w" (map term (cdr atom))) ", ")))

;; Uncertain event i holds in world w when bit i of w is set; certain
;; facts hold in every world. `hit(w, k)` records that statement k's
;; atom is in world w's least model, and `hits` packs those into a mask.
(define (souffle-program certain uncertain rules targets)
  (define atoms
    (append certain (map car uncertain) targets
            (append* (for/list ([r (in-list rules)]) (cons (car r) (cdr r))))))
  (define relations
    (remove-duplicates (for/list ([a (in-list atoms)])
                         (cons (relation a) (length (cdr a))))))
  (with-output-to-string
    (lambda ()
      (printf ".decl world(w: number)\n")
      (printf "world(w) :- w = range(0, ~a).\n" (expt 2 (length uncertain)))
      (for ([r (in-list relations)])
        (printf ".decl ~a(~a)\n" (car r)
                (string-join (cons "w: number"
                                   (for/list ([i (in-range (cdr r))]) (format "a~a: symbol" i)))
                             ", ")))
      (printf ".decl hit(w: number, k: number)\n")
      (printf ".decl hits(w: number, m: number)\n.output hits\n")
      (printf "hits(w, m) :- world(w), hit(w, _), m = sum (1 bshl k) : { hit(w, k) }.\n")
      (for ([a (in-list certain)])
        (printf "~a :- world(w).\n" (literal a)))
      (for ([e (in-list uncertain)] [i (in-naturals)])
        (printf "~a :- world(w), (w bshr ~a) band 1 = 1.\n" (literal (car e)) i))
      (for ([r (in-list rules)])
        (printf "~a :- ~a.\n" (literal (car r))
                (string-join (if (null? (cdr r)) (list "world(w)") (map literal (cdr r))) ", ")))
      (for ([t (in-list targets)] [k (in-naturals)])
        (printf "hit(w, ~a) :- ~a.\n" k (literal t))))))

;; For each world, a bitmask of which targets its least model contains.
(define (least-models certain uncertain rules targets)
  (define souffle
    (or (find-executable-path (or (getenv "SOUFFLE") "souffle"))
        (error 'reference "souffle not found (set SOUFFLE to its path)")))
  (define dir (make-temporary-directory))
  (dynamic-wind
   void
   (lambda ()
     (define dl (build-path dir "program.dl"))
     (call-with-output-file dl
       (lambda (o) (write-string (souffle-program certain uncertain rules targets) o)))
     (define err (open-output-string))
     (unless (parameterize ([current-output-port (open-output-nowhere)]
                            [current-error-port err])
               (system* souffle "-w" "-j" "auto" "-D" dir dl))
       (error 'reference "souffle failed:\n~a" (get-output-string err)))
     (define hits (make-vector (expt 2 (length uncertain)) 0))
     (for ([line (in-lines (open-input-file (build-path dir "hits.csv")))])
       (match-define (list w m) (map string->number (string-split line "\t")))
       (vector-set! hits w m))
     hits)
   (lambda () (delete-directory/files dir))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; The distribution semantics

;; Raised when a program has too many uncertain facts to enumerate, so the
;; checker can skip it without masking a real failure.
(struct exn:too-big exn:fail ())

;; P(w) for every world w, indexed the way Soufflé numbers them.
(define (world-weights uncertain)
  (for/fold ([ws (vector 1)]) ([e (in-list uncertain)])
    (define p (cdr e))
    (vector-append (for/vector ([w (in-vector ws)]) (* w (- 1 p)))
                   (for/vector ([w (in-vector ws)]) (* w p)))))

;; Answers in the engine's order: (label . P(fact)) per query, and a final
;; (error . message) if an observation is impossible, where the engine
;; stops. Probabilities are exact.
(define (reference-answers path #:max-facts [max-facts 16])
  (define-values (events rules stmts) (read-program path))
  (define certain (for/list ([e (in-list events)] #:when (= (cdr e) 1)) (car e)))
  (define uncertain (filter (lambda (e) (< 0 (cdr e) 1)) events))
  (when (> (length uncertain) max-facts)
    (raise (exn:too-big (format "~a uncertain facts, limit ~a (see --max-facts)"
                                (length uncertain) max-facts)
                        (current-continuation-marks))))
  (define targets (map cadr stmts))
  ;; Worlds that derive the same targets are indistinguishable from here
  ;; on, so their weights are summed once.
  (define by-hits
    (for/fold ([acc (hash)])
              ([h (in-vector (least-models certain uncertain rules targets))]
               [w (in-vector (world-weights uncertain))])
      (hash-update acc h (lambda (v) (+ v w)) 0)))
  ;; Observations so far are a mask of statements and the bits they need.
  (define (mass mask want)
    (for/sum ([(h w) (in-hash by-hits)]
              #:when (= (bitwise-and h mask) want))
      w))
  (let loop ([stmts stmts] [k 0] [mask 0] [want 0] [acc '()])
    (match stmts
      ['() (reverse acc)]
      [(cons (list 'query q) rest)
       (define bit (arithmetic-shift 1 k))
       (define p (/ (mass (bitwise-ior mask bit) (bitwise-ior want bit)) (mass mask want)))
       (loop rest (add1 k) mask want (cons (cons (atom->string q) p) acc))]
      [(cons (list 'observe a present?) rest)
       (define bit (arithmetic-shift 1 k))
       (define mask* (bitwise-ior mask bit))
       (define want* (if present? (bitwise-ior want bit) want))
       (if (zero? (mass mask* want*))
           (reverse (cons (cons 'error (format "cannot observe ~a~a"
                                               (if present? "" "~") (atom->string a)))
                          acc))
           (loop rest (add1 k) mask* want* acc))])))

;; Printed the way a fact prints in the engine's output.
(define (atom->string a)
  (format "~a(~a)" (car a)
          (string-join (for/list ([x (in-list (cdr a))])
                         (if (string? x) (format "~s" x) (format "~a" x)))
                       ", ")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; The engine, for comparison

;; The engine's answers in the same shape, read off what it prints. Each
;; run gets a fresh namespace, so it gets its own guard manager.
(define (engine-answers path)
  (define out (open-output-string))
  (define err
    (parameterize ([current-namespace (make-base-namespace)]
                   [current-output-port out])
      (with-handlers ([exn:fail? exn-message])
        (dynamic-require (simplify-path (path->complete-path path)) #f)
        #f)))
  (define answers
    (for/list ([line (in-list (string-split (get-output-string out) "\n"))]
               #:when (regexp-match? #rx": (#t|#f|#<pmf: .*>)$" line))
      (match-define (list _ label result) (regexp-match #rx"^(.*): (#t|#f|#<pmf: .*>)$" line))
      (cons label
            (cond
              [(equal? result "#t") 1]
              [(equal? result "#f") 0]
              [(regexp-match #rx"\\[#t ([^]]+)\\]" result)
               => (lambda (m) (string->number (cadr m)))]
              [else 0]))))
  (if err (append answers (list (cons 'error err))) answers))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Comparing

;; Prints a per-query comparison; returns #t if everything agrees.
(define (check-file path #:max-facts [max-facts 16] #:tolerance [tol 1e-9])
  (printf "~a\n" path)
  (with-handlers ([exn:too-big? (lambda (e) (printf "  skipped: ~a\n\n" (exn-message e)) #t)])
    (define ref (reference-answers path #:max-facts max-facts))
    (define eng (engine-answers path))
    (define rows (max (length ref) (length eng)))
    (define ok
      (for/fold ([ok #t]) ([i (in-range rows)])
        (define r (and (< i (length ref)) (list-ref ref i)))
        (define e (and (< i (length eng)) (list-ref eng i)))
        (define agree?
          (and r e
               (if (eq? (car r) 'error)
                   (eq? (car e) 'error)
                   (and (equal? (car r) (car e))
                        (<= (abs (- (cdr r) (cdr e))) tol)))))
        (printf "  ~a  ~a\n"
                (if agree? "ok  " "DIFF")
                (cond
                  [(and r (eq? (car r) 'error))
                   (format "reference: ~a | engine: ~a" (cdr r) (if e (cdr e) "(nothing)"))]
                  [r (format "~a  reference ~a  engine ~a" (car r)
                             (exact->inexact (cdr r)) (if e (cdr e) "(missing)"))]
                  [else (format "engine only: ~a" e)]))
        (and agree? ok)))
    (printf "  ~a\n\n" (if ok "agree" "DISAGREE"))
    ok))

(module+ main
  (require racket/cmdline)
  (define max-facts 16)
  (define files
    (command-line
     #:once-each
     [("--max-facts") n "Largest number of uncertain facts to enumerate (default 16)"
                      (set! max-facts (string->number n))]
     #:args files files))
  (define all-ok
    (for/fold ([ok #t]) ([f (in-list files)])
      (and (check-file f #:max-facts max-facts) ok)))
  (exit (if all-ok 0 1)))
