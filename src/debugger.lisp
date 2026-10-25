;;;; debugger.lisp -- evaluation with a live-stack debugger the model drives.
;;;;
;;;; Errors in agent code are handled with HANDLER-BIND, so the handler runs
;;;; before anything unwinds. The handler holds a conversation with the model,
;;;; which can inspect, redefine and then invoke a restart to resume.

(in-package #:palimpsest.kernel)

(defmacro retryable ((&optional (description "Retry this operation from its start.")) &body body)
  "Run BODY with a RETRY restart around it. Invoking the restart re-runs BODY from
its start, so a step can fail, be fixed with :define, and resume where it was."
  (let ((block-name (gensym "RETRYABLE")))
    `(block ,block-name
       (loop
         (restart-case (return-from ,block-name (progn ,@body))
           (retry ()
             :report (lambda (stream) (write-string ,description stream))))))))

(defparameter *backtrace-print-variables*
  '((*print-pretty* . nil) (*print-length* . 6) (*print-level* . 3) (*print-circle* . t)
    (*print-readably* . nil))
  "Printer settings for backtraces. SBCL ignores the dynamic printer variables while
printing a backtrace and uses SB-DEBUG:*DEBUG-PRINT-VARIABLE-ALIST* instead.")

(defparameter *backtrace-frame-max-chars* 400
  "Longest single frame shown to the model.")

(defun raw-backtrace (count)
  "Up to COUNT frames of the current stack as SBCL prints them."
  (with-output-to-string (out)
    (handler-case
        (let ((sb-debug:*debug-print-variable-alist* *backtrace-print-variables*))
          (sb-debug:print-backtrace :stream out :from :current-frame :count count))
      (error (e)
        (format out "0: <backtrace unavailable: ~a>" (condition-text e))))))

(defun frame-start-p (line)
  "True if LINE starts a new frame, as \"12: (...)\"."
  (let ((colon (position #\: line)))
    (and colon (plusp colon) (every #'digit-char-p (subseq line 0 colon)))))

(defun backtrace-frames (raw)
  "Split print-backtrace output into one string per frame, innermost first, dropping
SBCL's frame numbers. A frame whose arguments contain newlines spans several lines."
  (reverse
   (reduce (lambda (frames line)
             (if (or (frame-start-p line) (null frames))
                 (cons (string-left-trim " " (subseq line (1+ (or (position #\: line) -1))))
                       frames)
                 (cons (format nil "~a~%~a" (first frames) line) (rest frames))))
           (split-lines raw)
           :initial-value '())))

(defun frame-mentions-p (frame &rest markers)
  (some (lambda (marker) (search marker frame)) markers))

(defun agent-frames (frames)
  "The frames of the agent's own evaluation. Drops the debugger's frames above the
error (everything up to AGENT-DEBUG, then the signalling machinery), and the kernel
and operator frames below the evaluation (from EVAL-WITH-DEBUGGER's timeout wrapper on)."
  (let* ((after-debugger (or (cdr (member-if (lambda (frame) (frame-mentions-p frame "AGENT-DEBUG"))
                                             frames))
                             frames))
         (from-signal (member-if-not (lambda (frame)
                                       (frame-mentions-p frame "SB-KERNEL::%SIGNAL"
                                                         ":IN PALIMPSEST.KERNEL::EVAL-WITH-DEBUGGER"))
                                     after-debugger))
         (end (position-if (lambda (frame)
                             (frame-mentions-p frame "PALIMPSEST.KERNEL::CALL-WITH-EVAL-TIMEOUT"))
                           from-signal)))
    (butlast (subseq from-signal 0 end)
             ;; The frame just above the timeout wrapper is the kernel's own thunk.
             (if (and end (plusp end)
                      (frame-mentions-p (nth (1- end) from-signal) "EVAL-WITH-DEBUGGER"))
                 1
                 0))))

(defun backtrace-text (count)
  "Up to COUNT frames of the agent's evaluation, innermost first, numbered from 0."
  (let ((frames (agent-frames (backtrace-frames (raw-backtrace (+ count 40))))))
    (truncate-string
     (format nil "~:{~d: ~a~%~}"
             (mapcar (lambda (index frame)
                       (list index (truncate-string frame *backtrace-frame-max-chars*)))
                     (alexandria:iota count)
                     frames))
     *result-max-chars*)))

(defun restart-lines (restarts)
  (or (loop for restart in restarts
            for index from 0
            collect (format nil "  ~d: [~a] ~a"
                            index
                            (if (restart-name restart)
                                (symbol-name (restart-name restart))
                                "unnamed")
                            (handler-case (princ-to-string restart)
                              (error () "(no description)"))))
      (list "  (none: you can only :give-up)")))

(defun debugger-entry-text (condition restarts backtrace depth)
  (format nil "DEBUGGER~a. Your evaluation signalled an error and nothing has been unwound yet.~%~%Condition: ~a~%~%Restarts:~%~{~a~%~}~%Backtrace, innermost frame first:~%~a~%Fix the cause with :define and resume with (:restart ...), or (:give-up \"why\")."
          (if (plusp depth) (format nil " (nested, depth ~d)" depth) "")
          (condition-text condition)
          (restart-lines restarts)
          backtrace))

(defun eval-with-debugger (form depth)
  "Evaluate FORM in the layer. An error enters the agent debugger with the stack live.
Returns a plist: (:status :ok :values ... :output ...) or (:status :error :error ... :output ...)."
  (let ((output (make-string-output-stream))
        (last-condition nil))
    (flet ((output-text ()
             (truncate-string (get-output-stream-string output) *result-max-chars*)))
      (handler-case
          (block evaluation
            (loop
              (restart-case
                  (let ((results
                          (let ((*standard-output* output)
                                (*error-output* output))
                            (with-layer-syntax
                              (handler-bind
                                  ((warning (lambda (w)
                                              (unless (redefinition-warning-p w)
                                                (format output "~&WARNING: ~a~%" (condition-text w)))
                                              (quiet-warning w)))
                                   (error (lambda (c)
                                            (setf last-condition c)
                                            (agent-debug c depth))))
                                (with-eval-timeout ()
                                  (multiple-value-list (eval form))))))))
                    (return-from evaluation
                      (list :status :ok :values results :output (output-text))))
                (retry-eval ()
                  :report "Re-run your whole evaluated form from the beginning."
                  nil)
                (abort-eval ()
                  :report "Abandon this evaluation; you get the error as its result."
                  (return-from evaluation
                    (list :status :error :aborted t :output (output-text)
                          :error (if last-condition (condition-text last-condition) "aborted")))))))
        (serious-condition (c)
          (list :status :error :error (condition-text c) :output (output-text)))))))

(defun eval-action (form depth)
  "Lint FORM as an :eval, then evaluate it with the debugger."
  (let ((violations (lint-form form :eval)))
    (if violations
        (list :status :rejected :violations violations)
        (eval-with-debugger form depth))))

(defun render-eval-result (result)
  (with-output-to-string (out)
    (ecase (getf result :status)
      (:ok
       (let ((results (getf result :values)))
         (if results
             (format out "RESULT (~d value~:p):~%~{~a~%~}"
                     (length results)
                     (mapcar (lambda (value) (render value (floor *result-max-chars* 2))) results))
             (format out "RESULT: no values.~%"))))
      (:error
       (format out "ERROR~:[~; (you aborted the evaluation)~]: ~a~%"
               (getf result :aborted) (getf result :error)))
      (:rejected
       (format out "REJECTED by the lint; nothing was evaluated.~%~{- ~a~%~}"
               (getf result :violations))))
    (let ((text (getf result :output)))
      (when (and text (plusp (length text)))
        (format out "OUTPUT:~%~a~%" text)))))

(defun agent-debug (condition depth)
  "Handler for errors in agent evaluations. Runs a debugging conversation while the
stack is live. Returns normally, declining the error, if the agent gives up or the
budget or nesting limit is reached; otherwise the agent invokes a restart."
  (let ((session *session*))
    (when (or (null session)
              (>= depth *debugger-max-depth*)
              (session-exhausted-p session))
      (return-from agent-debug nil))
    (let ((restarts (remove-if (lambda (restart) (member restart *toplevel-restarts*))
                               (compute-restarts condition))))
      (log-event :debugger :depth depth :condition (condition-text condition))
      (session-say session :user
                   (debugger-entry-text condition restarts (backtrace-text 25) depth))
      (let ((*paused-timeouts* (append *active-timeouts* *paused-timeouts*)))
        (loop
          (when (session-exhausted-p session)
            (return nil))
          (let ((action (next-action session :debugger)))
            (when (and action
                       (eq (dispatch-debugger action restarts depth) :give-up))
              (return nil))))))))

(defun invoke-chosen-restart (session restarts which arg-forms)
  "Invoke the restart WHICH (a name or an index into RESTARTS) with the values of ARG-FORMS.
Transfers control if it succeeds; otherwise reports the problem and returns."
  (let ((restart (cond ((and (integerp which) (>= which 0))
                        (nth which restarts))
                       ((or (symbolp which) (stringp which))
                        (find (string which) restarts
                              :key (lambda (r) (and (restart-name r) (symbol-name (restart-name r))))
                              :test #'equalp))
                       (t nil))))
    (unless restart
      (session-say session :user
                   (format nil "There is no restart ~a here. Choose one of:~%~{~a~%~}"
                           (render which 100) (restart-lines restarts)))
      (return-from invoke-chosen-restart nil))
    (let ((violations (alexandria:mappend (lambda (form) (lint-form form :eval)) arg-forms)))
      (when violations
        (session-say session :user
                     (format nil "REJECTED by the lint; the restart was not invoked.~%~{- ~a~%~}"
                             violations))
        (return-from invoke-chosen-restart nil)))
    (let ((args (handler-case (with-layer-syntax (mapcar #'eval arg-forms))
                  (serious-condition (c)
                    (session-say session :user
                                 (format nil "Evaluating the restart arguments failed: ~a"
                                         (condition-text c)))
                    (return-from invoke-chosen-restart nil)))))
      (log-event :restart :name (prin1-to-string (restart-name restart)))
      (apply #'invoke-restart restart args))))

(defun dispatch-debugger (action restarts depth)
  "Carry out one debugger ACTION. Returns :GIVE-UP when the agent stops debugging."
  (let ((session *session*))
    (handler-case
        (ecase (car action)
          (:restart
           (check-arity action 1 nil)
           (invoke-chosen-restart session restarts (second action) (cddr action)))
          (:eval
           (check-arity action 1 1)
           (session-say session :user (render-eval-result (eval-action (second action) (1+ depth)))))
          (:define
           (check-arity action 2 2)
           (session-say session :user
                        (render-gate-result (propose-definition (second action) (third action)))))
          (:backtrace
           (check-arity action 0 0)
           (session-say session :user (format nil "BACKTRACE:~%~a" (backtrace-text 80))))
          (:give-up
           (check-arity action 0 1)
           (return-from dispatch-debugger :give-up)))
      (protocol-error (e)
        (session-say session :user (format nil "PROTOCOL ERROR: ~a" (protocol-error-message e)))))
    nil))
