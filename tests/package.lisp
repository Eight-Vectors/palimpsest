;;;; Kernel tests. Run with (asdf:test-system :palimpsest). No API key needed:
;;;; the debugger test drives a scripted model.

(defpackage #:palimpsest.tests
  (:use #:cl #:fiveam))

(in-package #:palimpsest.tests)

(def-suite :palimpsest :description "Palimpsest kernel tests.")
(in-suite :palimpsest)

(defun layer-read (string)
  "Read STRING the way the kernel reads the model's forms."
  (palimpsest.kernel::with-layer-syntax (read-from-string string)))

(defun layer-symbol (name)
  (find-symbol (string-upcase name) '#:palimpsest.layer))

(defun read-action (text)
  (palimpsest.kernel::parse-action text palimpsest.kernel::*top-level-actions*))

(defun lint (string context)
  (palimpsest.kernel::lint-form (layer-read string) context))

(defvar *random* (make-random-state t))

(defmacro with-temp-layer (() &body body)
  "Run BODY against a fresh copy of the seed layer in a temporary directory."
  (let ((dir (gensym "DIR")))
    `(let* ((,dir (uiop:ensure-directory-pathname
                   (uiop:subpathname (uiop:temporary-directory)
                                     (format nil "palimpsest-test-~36r/"
                                             (random (expt 36 8) *random*)))))
            (palimpsest.kernel:*use-git* nil)
            (palimpsest.kernel:*verbose* nil)
            (palimpsest.kernel:*layer-root* nil))
       (unwind-protect
            (progn (palimpsest.kernel:init-layer ,dir)
                   (palimpsest.kernel:start ,dir)
                   ,@body)
         (uiop:delete-directory-tree ,dir :validate t :if-does-not-exist :ignore)))))
