(in-package #:palimpsest.tests)
(in-suite :palimpsest)

(defun fenced (note form-text)
  (format nil "~a~%```lisp~%~a~%```" note form-text))

(defun alternates-p (entries)
  (loop for (a b) on entries
        while b
        always (not (eq (getf a :role) (getf b :role)))))

(test debugger-fix-and-resume
  ;; The agent calls a broken function inside RETRYABLE, lands in the debugger,
  ;; redefines the function, invokes RETRY and gets the right answer without
  ;; re-running anything outside the retryable step.
  (with-temp-layer ()
    (palimpsest.kernel::create-module "demo" :effect "Debugger demo.")
    (palimpsest.kernel::propose-definition
     "demo" (layer-read "(defun flaky (x) (error \"flaky is broken for ~a\" x))"))
    (let ((palimpsest.kernel:*llm-backend*
            (palimpsest.kernel:make-scripted-backend
             (list (fenced "Try it." "(:eval (retryable (\"call flaky\") (flaky 21)))")
                   (fenced "Fix FLAKY." "(:define \"demo\" (defun flaky (x) (* 2 x)))")
                   (fenced "Resume." "(:restart retry)")
                   (fenced "Finished." "(:done \"got 42\")")))))
      (multiple-value-bind (result status session)
          (palimpsest.kernel:run-task "Call flaky on 21." :budget 10)
        (is (eq :done status))
        (is (equal "got 42" result))
        (is (= 42 (funcall (layer-symbol "flaky") 21)))
        (let ((entries (palimpsest.kernel::session-entries session)))
          (is (alternates-p entries))
          (is (some (lambda (e) (search "DEBUGGER" (getf e :text))) entries))
          (is (some (lambda (e) (and (search "RESULT" (getf e :text))
                                     (search "42" (getf e :text))))
                    entries)))))))

(test giving-up-returns-the-error
  (with-temp-layer ()
    (let ((palimpsest.kernel:*llm-backend*
            (palimpsest.kernel:make-scripted-backend
             (list (fenced "Divide." "(:eval (/ 1 0))")
                   (fenced "Not worth fixing." "(:give-up \"division by zero is expected\")")
                   (fenced "Done." "(:done \"saw the error\")")))))
      (multiple-value-bind (result status session)
          (palimpsest.kernel:run-task "Divide one by zero." :budget 10)
        (is (eq :done status))
        (is (equal "saw the error" result))
        (is (some (lambda (e) (search "division-by-zero" (getf e :text) :test #'char-equal))
                  (palimpsest.kernel::session-entries session)))))))

(test protocol-errors-are-reported-not-fatal
  (with-temp-layer ()
    (let ((palimpsest.kernel:*llm-backend*
            (palimpsest.kernel:make-scripted-backend
             (list "I forgot the parenthesis: (:eval (+ 1 2)"
                   (fenced "Again." "(:done \"recovered\")")))))
      (multiple-value-bind (result status session)
          (palimpsest.kernel:run-task "Anything." :budget 5)
        (is (eq :done status))
        (is (equal "recovered" result))
        (is (some (lambda (e) (search "PROTOCOL ERROR" (getf e :text)))
                  (palimpsest.kernel::session-entries session)))))))

(test the-budget-is-enforced
  (with-temp-layer ()
    (let ((palimpsest.kernel:*llm-backend*
            (palimpsest.kernel:make-scripted-backend
             (loop repeat 5 collect (fenced "Again." "(:eval 1)")))))
      (is (eq :budget-exhausted
              (nth-value 1 (palimpsest.kernel:run-task "Loop forever." :budget 3)))))))

(test backtraces-show-only-the-agents-frames
  (with-temp-layer ()
    (palimpsest.kernel::create-module "demo" :effect "Backtrace demo.")
    ;; Not a tail call, so EXPLODE keeps its frame.
    (palimpsest.kernel::propose-definition
     "demo" (layer-read "(defun explode (x) (1+ (error \"exploded on ~a\" x)))"))
    (let ((palimpsest.kernel:*llm-backend*
            (palimpsest.kernel:make-scripted-backend
             (list (fenced "Try." "(:eval (explode 7))")
                   (fenced "Stop." "(:give-up)")
                   (fenced "Done." "(:done \"ok\")")))))
      (let* ((session (nth-value 2 (palimpsest.kernel:run-task "Explode." :budget 5)))
             (text (getf (find-if (lambda (e) (search "DEBUGGER" (getf e :text)))
                                  (palimpsest.kernel::session-entries session))
                         :text)))
        (is (search "exploded on 7" text))
        (is (search "0: " text))
        (is (search "EXPLODE" text))
        (is (not (search "%SIGNAL" text)))
        (is (not (search "CALL-WITH-EVAL-TIMEOUT" text)))
        (is (not (search "DISPATCH-TOP-LEVEL" text)))
        (is (not (search "RUN-TASK" text)))))))
