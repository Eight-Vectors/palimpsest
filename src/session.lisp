;;;; session.lisp -- the state of one task.

(in-package #:palimpsest.kernel)

(defstruct (session (:constructor make-session (task budget)))
  task
  budget
  (transcript '())   ; newest first; each entry is (:role <:user|:assistant> :text <string>)
  (steps 0)
  (notices '())      ; kernel messages for the next system prompt
  (result nil))

(defvar *session* nil "The session RUN-TASK is working on.")

(defvar *toplevel-restarts* '()
  "Restarts that existed before RUN-TASK began. They are never offered to the agent.")

(defun session-say (session role text)
  "Append TEXT to SESSION's transcript as ROLE. Consecutive entries with the same
role are merged, so the transcript always alternates."
  (let ((text (if (and (stringp text) (plusp (length text))) text "(empty)"))
        (latest (first (session-transcript session))))
    (if (and latest (eq (getf latest :role) role))
        (setf (first (session-transcript session))
              (list :role role :text (format nil "~a~%~%~a" (getf latest :text) text)))
        (push (list :role role :text text) (session-transcript session)))
    text))

(defun session-entries (session)
  "SESSION's transcript, oldest first."
  (reverse (session-transcript session)))

(defun session-exhausted-p (session)
  (>= (session-steps session) (session-budget session)))

(defun session-notice (session control &rest args)
  (push (apply #'format nil control args) (session-notices session)))

(defun current-task ()
  "The text of the task being worked on, or NIL outside a task."
  (and *session* (session-task *session*)))

(defun print-transcript (session &optional (stream *standard-output*))
  "Print SESSION's transcript, as returned by RUN-TASK, for the operator."
  (dolist (entry (session-entries session))
    (format stream "~&=== ~a ===~%~a~%" (getf entry :role) (getf entry :text)))
  (values))
