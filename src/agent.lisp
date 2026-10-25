;;;; agent.lisp -- the step loop: assemble context, ask the model, act.

(in-package #:palimpsest.kernel)

(defun default-assemble-context (transcript max-chars)
  "Kernel fallback for ASSEMBLE-CONTEXT: the task, the latest exchange, and as many
earlier entries as fit in MAX-CHARS, cutting only at assistant boundaries."
  (labels ((keep (newest-first budget forced acc)
             ;; Take entries while they fit in BUDGET, always the first FORCED of them.
             (let ((size (length (getf (first newest-first) :text))))
               (if (or (null newest-first) (and (<= forced 0) (> size budget)))
                   acc
                   (keep (rest newest-first) (- budget size) (1- forced)
                         (cons (first newest-first) acc))))))
    (let* ((task (first transcript))
           (kept (keep (reverse (rest transcript))
                       (- max-chars (length (getf task :text)))
                       2
                       '())))
      (cons task (member :assistant kept :key (lambda (entry) (getf entry :role)))))))

(defun valid-context-p (entries)
  (and entries
       (alexandria:proper-list-p entries)
       (every (lambda (entry)
                (and (alexandria:proper-list-p entry)
                     (evenp (length entry))
                     (member (getf entry :role) '(:user :assistant))
                     (stringp (getf entry :text))
                     (plusp (length (getf entry :text)))))
              entries)
       (eq (getf (first entries) :role) :user)
       (eq (getf (car (last entries)) :role) :user)
       (loop for (a b) on entries
             while b
             always (not (eq (getf a :role) (getf b :role))))))

(defun call-hook (session name fallback &rest args)
  "Call layer function NAME with ARGS if it exists; on any failure note it and use FALLBACK."
  (let ((symbol (find-symbol name (layer-package))))
    (if (and symbol (fboundp symbol) (not (macro-function symbol)))
        (handler-case
            (handler-bind ((warning #'quiet-warning))
              (let ((*standard-output* (make-broadcast-stream)))
                (with-layer-syntax
                  (with-eval-timeout (*hook-timeout*)
                    (apply symbol args)))))
          (serious-condition (c)
            (session-notice session "Hook ~a failed (~a); the kernel default was used instead."
                            name (condition-text c))
            (apply fallback args)))
        (apply fallback args))))

(defun context-messages (session)
  (let* ((transcript (session-entries session))
         (from-hook (call-hook session "ASSEMBLE-CONTEXT" #'default-assemble-context
                               (copy-tree transcript) *context-max-chars*))
         (chosen (if (valid-context-p from-hook)
                     from-hook
                     (progn
                       (session-notice session "ASSEMBLE-CONTEXT returned a malformed context; the kernel default was used instead.")
                       (default-assemble-context transcript *context-max-chars*)))))
    (mapcar (lambda (entry) (cons (getf entry :role) (getf entry :text))) chosen)))

(defun system-prompt (session mode)
  (let* ((from-hook (call-hook session "SYSTEM-ADDENDUM" (lambda () nil)))
         (addendum (if (or (null from-hook) (stringp from-hook))
                       from-hook
                       (progn
                         (session-notice session "SYSTEM-ADDENDUM returned ~a, not a string; it was ignored."
                                         (render from-hook 100))
                         nil))))
    (format nil *system-prompt*
            (if (eq mode :debugger) *debugger-actions-text* *top-level-actions-text*)
            *api-text*
            (manifest-text)
            (and addendum (plusp (length addendum)) (truncate-string addendum 8000))
            (reverse (session-notices session))
            (1+ (session-steps session))
            (session-budget session))))

(defun next-action (session mode)
  "Ask the model for its next action. Returns the action, or NIL after reporting a
protocol error back to the model. MODE is :TOP-LEVEL or :DEBUGGER."
  (let* ((messages (context-messages session))
         (system (system-prompt session mode))
         (raw-reply (llm-complete system messages))
         (reply (if (stringp raw-reply) raw-reply (princ-to-string raw-reply))))
    (incf (session-steps session))
    (setf (session-notices session) '())
    (session-say session :assistant reply)
    (handler-case
        (let ((action (parse-action reply (if (eq mode :debugger)
                                              *debugger-actions*
                                              *top-level-actions*))))
          (log-event :step :n (session-steps session) :mode mode :action (car action))
          action)
      (protocol-error (e)
        (session-say session :user
                     (format nil "PROTOCOL ERROR: ~a~%Reply with a short note and then exactly one action in a ```lisp block."
                             (protocol-error-message e)))
        nil))))

(defun dispatch-top-level (action session)
  "Carry out one top-level ACTION. Returns :DONE when the task is finished."
  (handler-case
      (ecase (car action)
        (:eval
         (check-arity action 1 1)
         (session-say session :user (render-eval-result (eval-action (second action) 0))))
        (:define
         (check-arity action 2 2)
         (session-say session :user
                      (render-gate-result (propose-definition (second action) (third action)))))
        (:module
         (check-arity action 3 4)
         (session-say session :user (render-gate-result (apply #'create-module (rest action)))))
        (:test
         (check-arity action 3 3)
         (session-say session :user (render-gate-result (apply #'propose-test (rest action)))))
        (:done
         (check-arity action 1 1)
         (setf (session-result session) (second action))
         (return-from dispatch-top-level :done)))
    (protocol-error (e)
      (session-say session :user (format nil "PROTOCOL ERROR: ~a" (protocol-error-message e)))))
  nil)

(defun run-task (task &key (budget *step-budget*))
  "Work on TASK until the agent sends :done or the step budget runs out.
Returns (values result status session), STATUS being :DONE or :BUDGET-EXHAUSTED.
Kernel failures (an unreachable API, say) land in your own REPL debugger."
  (ensure-root)
  (let* ((session (make-session task budget))
         (*session* session)
         (*toplevel-restarts* (compute-restarts)))
    (session-say session :user (format nil "TASK:~%~a" task))
    (loop
      (when (session-exhausted-p session)
        (log-event :budget-exhausted :steps (session-steps session))
        (return (values nil :budget-exhausted session)))
      (let ((action (next-action session :top-level)))
        (when (and action (eq (dispatch-top-level action session) :done))
          (log-event :done :steps (session-steps session))
          (return (values (session-result session) :done session)))))))
