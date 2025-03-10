(load "./flisp/aliases.scm")
(load "./flisp/profile.scm")
(load "utils.scm")
(load "ast.scm")
(load "match.scm")
(load "macroexpand.scm")
(load "julia-parser.scm")
(load "julia-syntax.scm")


;; exception handler to turn known errors into special expressions,
;; to prevent throwing an exception past a C caller.
(define (error-wrap thk)
  (with-exception-catcher
   (lambda (e)
     (if (and (pair? e) (memq (car e) '(error io-error)))
         (let ((msg (cadr e))
               (pfx "incomplete:"))
           (if (and (string? msg) (>= (string-length msg) (string-length pfx))
                    (equal? pfx
                            (substring msg 0 (string-length pfx))))
               `(incomplete ,msg)
               (cons 'error (cdr e))))
         (begin
           ;;(newline)
           ;;(display "unexpected error: ")
           ;;(prn e)
           ;;(print-stack-trace (stacktrace))
           '(error "malformed expression"))))
   thk))

;; this is overwritten when we run in actual julia
(define (defined-julia-global v) #f)
(define (julia-current-file) 'none)
(define (julia-current-line) 0)

;; parser entry points

;; parse one expression (if greedy) or atom, returning end position
(define (jl-parse-one str filename pos0 greedy (lineno 1))
  (let ((inp (open-input-string str)))
    (io.seek inp pos0)
    (io.set-lineno! inp lineno)
    (with-bindings ((current-filename (symbol filename)))
     (let ((expr (error-wrap (lambda ()
                               (if greedy
                                   (julia-parse inp parse-stmts)
                                   (julia-parse inp parse-atom))))))
       (cons expr (io.pos inp))))))

(define (parse-all- io filename)
  (unwind-protect
   (with-bindings ((current-filename (symbol filename)))
    (let ((stream (make-token-stream io)))
      (let loop ((exprs '()))
        (let ((lineno (error-wrap
                       (lambda ()
                         (skip-ws-and-comments io)
                         (input-port-line io)))))
          (if (pair? lineno)
              (cons 'toplevel
                    (reverse! (list* lineno
                                     `(line ,(input-port-line io) ,current-filename)
                                     exprs)))
              (let ((expr (error-wrap
                           (lambda ()
                             (julia-parse stream)))))
                (if (eof-object? expr)
                    (cons 'toplevel (reverse! exprs))
                    (let* ((iserr  (and (pair? expr) (eq? (car expr) 'error)))
                           ;; for error, get most recent line number (#16720)
                           (lineno (if iserr (input-port-line io) lineno))
                           (next   (list* expr
                                          `(line ,lineno ,current-filename)
                                          exprs)))
                      (if iserr
                          (cons 'toplevel (reverse! next))
                          (loop next))))))))))
   (io.close io)))

;; parse all expressions in a string, the same way files are parsed
(define (jl-parse-all str filename (lineno 1))
  (let ((io (open-input-string str)))
    (io.set-lineno! io lineno)
    (parse-all- io filename)))

(define (jl-parse-file filename (lineno 1))
  (trycatch
    (let ((io (open-input-string str)))
      (io.set-lineno! io lineno)
      (parse-all- io filename))
    (lambda (e) #f)))

;; lowering entry points

;; return a lambda expression representing a thunk for a top-level expression
;; note: expansion of stuff inside module is delayed, so the contents obey
;; toplevel expansion order (don't expand until stuff before is evaluated).
(define (expand-toplevel-expr-- e file line)
  (let ((ex0 (julia-expand-macroscope e)))
    (if (toplevel-only-expr? ex0)
        ex0
        (let* ((ex (julia-expand0 ex0 file line))
               (th (julia-expand1
                    `(lambda () ()
                             (scope-block
                              ,(blockify ex)))
                    file line)))
          (if (and (null? (cdadr (caddr th)))
                   (and (length= (lam:body th) 2)
                        ;; 1-element body might be `return` or `goto` (issue #33227)
                        (return? (cadr (lam:body th)))
                        (let ((retval (cadadr (lam:body th))))
                          (or (and (pair? retval) (eq? (car retval) 'lambda))
                              (simple-atom? retval)))))
              ;; generated functions use the pattern (body (return (lambda ...))), which
              ;; needs to be unwrapped to just the lambda (CodeInfo).
              (cadadr (lam:body th))
              `(thunk ,th))))))

(define (toplevel-only-expr? e)
  (and (pair? e)
       (or (memq (car e) '(toplevel line module import using export
                                    error incomplete))
           (and (memq (car e) '(global const)) (every symbol? (cdr e))))))

(define *in-expand* #f)

(define (expand-toplevel-expr e file line)
  (cond ((or (atom? e) (toplevel-only-expr? e))
         (if (underscore-symbol? e)
             (error "all-underscore identifier used as rvalue"))
         e)
        (else
         (let ((last *in-expand*))
           (if (not last)
               (begin (reset-gensyms)
                      (set! *in-expand* #t)))
           (begin0 (expand-toplevel-expr-- e file line)
                   (set! *in-expand* last))))))

;; used to collect warnings during lowering, which are usually discarded
;; unless logging is requested
(define lowering-warning (lambda lst (void)))

;; expand a piece of raw surface syntax to an executable thunk

(define (expand-to-thunk- expr file line)
  (error-wrap (lambda ()
                (expand-toplevel-expr expr file line))))

(define (expand-to-thunk-stmt- expr file line)
  (expand-to-thunk- (if (toplevel-only-expr? expr)
                        expr
                        `(block ,expr (null)))
                    file line))

(define (jl-expand-to-thunk-warn expr file line stmt)
  (let ((warnings '()))
    (with-bindings
     ;; Abuse scm_to_julia here to convert arguments to warn. This is meant for
     ;; `Expr`s but should be good enough provided we're only passing simple
     ;; numbers, symbols and strings.
     ((lowering-warning (lambda lst (set! warnings (cons (cons 'warn lst) warnings)))))
     (let ((thunk (if stmt
                      (expand-to-thunk-stmt- expr file line)
                      (expand-to-thunk- expr file line))))
       (if (pair? warnings) `(warn ,@(reverse warnings) ,thunk) thunk)))))

(define (jl-expand-to-thunk expr file line)
  (expand-to-thunk- expr file line))

(define (jl-expand-to-thunk-stmt expr file line)
  (expand-to-thunk-stmt- expr file line))

(define (jl-expand-macroscope expr)
  (error-wrap (lambda ()
                (julia-expand-macroscope expr))))

;; construct default definitions of `eval` for non-bare modules
;; called by jl_eval_module_expr
(define (module-default-defs name file line)
  (jl-expand-to-thunk
   (let* ((loc  (if (and (eq? file 'none) (eq? line 0)) '() `((line ,line ,file))))
          (x    (if (eq? name 'x) 'y 'x))
          (mex  (if (eq? name 'mapexpr) 'map_expr 'mapexpr)))
     `(block
       (= (call eval ,x)
          (block
           ,@loc
           (call (core eval) ,name ,x)))
       (= (call include ,x)
          (block
           ,@loc
           (call (core _call_latest) (top include) ,name ,x)))
       (= (call include (:: ,mex (top Function)) ,x)
          (block
           ,@loc
           (call (core _call_latest) (top include) ,mex ,name ,x)))))
   file line))

; run whole frontend on a string. useful for testing.
(define (fe str)
  (expand-toplevel-expr (julia-parse str) 'none 0))

(define (profile-e s)
  (with-exception-catcher
   (lambda (e)
           (newline)
           (prn e))
   (lambda () (profile s))))


; --- logging ---
; Utilities for logging messages from the frontend, in a way which can be
; controlled from julia code.

; Extract line and file from a line number node, defaulting to (0, none)
; respectively if lno is absent (`#f`) or doesn't contain a file
(define (extract-line-file lno)
  (cond ((or (not lno) (null? lno)) '(0 none))
        ((not (eq? (car lno) 'line)) (error "lno is not a line number node"))
        ((length= lno 2) `(,(cadr lno) none))
        (else (cdr lno))))

(define (format-loc lno)
  (let* ((lf (extract-line-file lno)) (line (car lf)) (file (cadr lf)))
    (format-file-line file line #f)))

(define (format-file-line file line exactloc)
  (if (or (= line 0) (eq? file 'none))
      ""
      (string (if exactloc " at " " around ") file ":" line)))

(define *scopewarn-opt* 1)
