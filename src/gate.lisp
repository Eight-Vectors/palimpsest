;;;; gate.lisp -- every persistent change passes through here:
;;;; lint, evaluate, run the whole test suite, then write and commit.
;;;; Any failure restores the previous definition and writes nothing.

(in-package #:palimpsest.kernel)

(defun run-test-form (form)
  "Evaluate test FORM quietly. Returns (values passed-p message)."
  (handler-case
      (let ((*standard-output* (make-broadcast-stream))
            (*error-output* (make-broadcast-stream)))
        (handler-bind ((warning #'quiet-warning))
          (if (with-eval-timeout (*test-timeout*)
                (with-layer-syntax (eval form)))
              (values t nil)
              (values nil "returned NIL"))))
    (serious-condition (c) (values nil (condition-text c)))))

(defun run-test-file (path)
  (handler-case (run-test-form (read-form-file path))
    (error (e) (values nil (format nil "unreadable test file: ~a" (condition-text e))))))

(defun all-test-files ()
  "Every stored test as (module . path)."
  (alexandria:mappend (lambda (meta)
                        (mapcar (lambda (path) (cons (getf meta :name) path))
                                (test-files (getf meta :name))))
                      (list-modules)))

(defun test-failure (entry)
  "Run the test at ENTRY, a (module . path). NIL if it passes, else (module test message)."
  (destructuring-bind (module . path) entry
    (multiple-value-bind (passed message) (run-test-file path)
      (unless passed
        (list module (pathname-name path) message)))))

(defun run-tests ()
  "Run every stored test. Returns (values failures total); each failure is (module test message)."
  (let ((entries (all-test-files)))
    (values (remove nil (mapcar #'test-failure entries))
            (length entries))))

(defun restore-previous (operator name previous result)
  "Put back PREVIOUS (a stored form, or NIL if there was none) after a rejected change.
RESULT is what evaluating the rejected form returned."
  (handler-case
      (handler-bind ((warning #'quiet-warning))
        (cond ((null previous)
               (undefine operator name result))
              (t
               (when (and (member operator '(defun defmacro defgeneric))
                          (not (eq (car previous) operator)))
                 (fmakunbound name))
               (when (member (car previous) '(defparameter defvar))
                 (makunbound name))
               (with-layer-syntax (eval previous)))))
    (error (e)
      (log-event :restore-failed :name (prin1-to-string name) :error (condition-text e)))))

(defun propose-definition (module form)
  "Try to add or replace FORM in MODULE. Returns a result plist with :STATUS :ACCEPTED or :REJECTED."
  (let ((meta (or (read-module-meta module)
                  (protocol-fail "There is no module ~s. Create it first: ~a"
                                 module (action-usage :module)))))
    (multiple-value-bind (operator name key) (definition-key form)
      (let ((violations (lint-form form (getf meta :kind))))
        (when violations
          (return-from propose-definition
            (list :status :rejected :stage "lint" :violations violations))))
      (let* ((existing (fset:lookup (definition-index) key))
             (owner (car existing)))
        (when (and owner (string/= owner module))
          (return-from propose-definition
            (list :status :rejected :stage "ownership"
                  :violations (list (format nil "~a is already defined in module ~s; redefine it there."
                                            key owner)))))
        (let ((path (if existing
                        (cdr existing)
                        (uiop:subpathname (module-dir module)
                                          (definition-filename operator name key))))
              (previous (and existing (ignore-errors (read-form-file (cdr existing))))))
          ;; 1. Apply.
          (multiple-value-bind (result warnings)
              (handler-case
                  (collecting-warnings (collected)
                    (when (and previous
                               (member operator '(defun defmacro defgeneric))
                               (not (eq (car previous) operator)))
                      (fmakunbound name))
                    (let ((value (with-layer-syntax (with-eval-timeout () (eval form)))))
                      (values value (reverse collected))))
                (serious-condition (c)
                  (restore-previous operator name previous nil)
                  (return-from propose-definition
                    (list :status :rejected :stage "evaluation"
                          :violations (list (condition-text c))))))
            ;; 2. Test everything.
            (multiple-value-bind (failures total) (run-tests)
              (when failures
                (restore-previous operator name previous result)
                (return-from propose-definition
                  (list :status :rejected :stage "tests" :failures failures
                        :total total :warnings warnings)))
              ;; 3. Persist.
              (write-form-file path form (format nil "module ~a -- managed by palimpsest" module))
              (git-commit (format nil "~a: ~:[define~;redefine~] ~a" module previous key))
              (log-event :definition-accepted :module module :key key)
              (list :status :accepted :what key
                    :file (enough-namestring path (ensure-root))
                    :replaced (and previous t) :total total :warnings warnings))))))))

(defun propose-test (module name form)
  "Add regression test NAME to MODULE. Tests are append-only and must pass when added."
  (unless (read-module-meta module)
    (protocol-fail "There is no module ~s." module))
  (unless (and (stringp name) (plusp (length name)) (string= name (filename-safe name)))
    (protocol-fail "Test names are lowercase strings of letters, digits, - and _. Got ~a."
                   (render name 100)))
  (let ((path (uiop:subpathname (module-dir module) (format nil "tests/~a.lisp" name))))
    (when (probe-file path)
      (return-from propose-test
        (list :status :rejected :stage "append-only"
              :violations (list (format nil "Test ~a/~a already exists. Tests are append-only for the agent: add a new test instead, or ask the operator to change this one."
                                        module name)))))
    (let ((violations (lint-form form :test)))
      (when violations
        (return-from propose-test (list :status :rejected :stage "lint" :violations violations))))
    (multiple-value-bind (passed message) (run-test-form form)
      (unless passed
        (return-from propose-test
          (list :status :rejected :stage "test run"
                :violations (list (format nil "The test does not pass now (~a). Tests must pass when added."
                                          message))))))
    (write-form-file path form (format nil "test ~a/~a -- append-only" module name))
    (git-commit (format nil "~a: add test ~a" module name))
    (list :status :accepted :what (format nil "test ~a/~a" module name)
          :file (enough-namestring path (ensure-root)))))

(defun create-module (name kind doc &optional depends-on)
  "Create a layer module. Its kind is fixed once created."
  (unless (valid-module-name-p name)
    (protocol-fail "Module names are lowercase strings of letters, digits and hyphens, starting with a letter, at most 40 characters. Got ~a."
                   (render name 100)))
  (unless (member kind '(:pure :effect))
    (protocol-fail "Module kind must be :pure or :effect. Got ~a." (render kind 100)))
  (unless (stringp doc)
    (protocol-fail "The module's purpose must be a string."))
  (unless (and (alexandria:proper-list-p depends-on) (every #'stringp depends-on))
    (protocol-fail "DEPENDS-ON must be a list of module names."))
  (when (read-module-meta name)
    (return-from create-module
      (list :status :rejected :stage "exists"
            :violations (list (format nil "Module ~s already exists. Its kind cannot be changed by the agent."
                                      name)))))
  (let ((missing (remove-if #'read-module-meta depends-on)))
    (when missing
      (return-from create-module
        (list :status :rejected :stage "dependencies"
              :violations (list (format nil "No such module~p: ~{~a~^, ~}."
                                        (length missing) missing))))))
  (write-form-file (module-meta-path name) (list :kind kind :doc doc :depends-on depends-on))
  (git-commit (format nil "create module ~a (~(~a~))" name kind))
  (list :status :accepted :what (format nil "module ~a" name)))

(defun render-gate-result (result)
  (with-output-to-string (out)
    (ecase (getf result :status)
      (:accepted
       (format out "ACCEPTED: ~a~@[ -> ~a~]~:[~; (replaced the previous definition)~]."
               (getf result :what) (getf result :file) (getf result :replaced))
       (when (getf result :total)
         (format out " All ~d test~:p pass." (getf result :total)))
       (when *use-git* (format out " Committed."))
       (terpri out))
      (:rejected
       (format out "REJECTED at the ~a stage. Nothing was changed.~%" (getf result :stage))
       (dolist (violation (getf result :violations))
         (format out "- ~a~%" violation))
       (dolist (failure (getf result :failures))
         (format out "- test ~a/~a failed: ~a~%" (first failure) (second failure) (third failure)))))
    (when (getf result :warnings)
      (format out "Compiler warnings:~%~{- ~a~%~}" (getf result :warnings)))))
