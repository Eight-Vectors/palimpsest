;;;; protocol.lisp -- turning a model reply into exactly one action.

(in-package #:palimpsest.kernel)

(defparameter *top-level-actions* '(:eval :define :module :test :done))

(defparameter *debugger-actions* '(:restart :eval :define :backtrace :give-up))

(defparameter *action-usage*
  '((:eval . "(:eval FORM)")
    (:define . "(:define \"module\" (defun name (args) \"docstring\" body...))")
    (:module . "(:module \"name\" :pure|:effect \"what it is for\" (\"dependency\" ...))")
    (:test . "(:test \"module\" \"test-name\" FORM-THAT-RETURNS-TRUE)")
    (:done . "(:done \"summary for the operator\")")
    (:restart . "(:restart name-or-index ARG-FORM...)")
    (:backtrace . "(:backtrace)")
    (:give-up . "(:give-up \"why\")")))

(defun action-usage (action)
  (or (cdr (assoc action *action-usage*))
      (format nil "~(~s~)" action)))

(defun last-fenced-block (text)
  "The body of the last ``` fenced block in TEXT, or NIL if there is none."
  (let ((pos 0)
        (found nil))
    (loop
      (let ((open (search "```" text :start2 pos)))
        (unless open (return found))
        (let* ((eol (or (position #\Newline text :start open) (return found)))
               (close (search "```" text :start2 (1+ eol))))
          (unless close (return found))
          (setf found (subseq text (1+ eol) close)
                pos (+ close 3)))))))

(defun read-single-form (text)
  "Read exactly one form from TEXT in the layer package, with *READ-EVAL* off."
  (handler-case
      (with-layer-syntax
        (with-input-from-string (stream text)
          (let* ((eof (make-symbol "EOF"))
                 (form (read stream nil eof)))
            (cond ((eq form eof)
                   (protocol-fail "Your reply contained no Lisp form."))
                  ((not (eq (read stream nil eof) eof))
                   (protocol-fail "Your reply contained more than one top-level form; send exactly one action."))
                  (t form)))))
    (protocol-error (e) (error e))
    (end-of-file ()
      (protocol-fail "Unbalanced parentheses or an unterminated string: the reader ran out of input inside a form."))
    (error (e)
      (protocol-fail "The reader rejected your form: ~a" (condition-text e)))))

(defun parse-action (reply allowed)
  "Extract and validate the single action in REPLY.
Signals PROTOCOL-ERROR with a message meant for the model."
  (let ((form (read-single-form (or (last-fenced-block reply) reply))))
    (unless (and (consp form) (keywordp (car form)) (alexandria:proper-list-p form))
      (protocol-fail "An action is a list that starts with a keyword. Available here: ~(~{~s~^ ~}~)."
                     allowed))
    (unless (member (car form) allowed)
      (protocol-fail "~(~s~) is not available here. Available: ~(~{~s~^ ~}~)."
                     (car form) allowed))
    form))

(defun check-arity (action min max)
  (let ((count (length (rest action))))
    (unless (and (>= count min) (or (null max) (<= count max)))
      (protocol-fail "Wrong number of arguments to ~(~s~). Usage: ~a"
                     (car action) (action-usage (car action))))))
