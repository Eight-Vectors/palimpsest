;;;; manifest.lisp -- what the model is told about the layer, built from source.

(in-package #:palimpsest.kernel)

(defun body-docstring (body)
  "The docstring among the declarations at the start of BODY, if any."
  (loop for (x . more) on body
        while (or (stringp x) (and (consp x) (eq (car x) 'declare)))
        when (and (stringp x) more) return x))

(defun option-documentation (options)
  (loop for option in options
        when (and (consp option) (eq (car option) :documentation))
          return (second option)))

(defun first-line (string)
  (let ((end (position #\Newline string)))
    (if end (subseq string 0 end) string)))

(defun describe-definition (form)
  "Return (values signature docstring) for a stored definition FORM."
  (with-layer-syntax
    (let ((*print-pretty* nil)
          (operator (first form))
          (name (second form)))
      (case operator
        ((defun defmacro)
         (values (format nil "(~(~a~) ~s ~s)" operator name (third form))
                 (body-docstring (cdddr form))))
        (defgeneric
         (values (format nil "(defgeneric ~s ~s)" name (third form))
                 (option-documentation (cdddr form))))
        (defmethod
         (multiple-value-bind (qualifiers specializers lambda-list) (method-signature form)
           (declare (ignore specializers))
           (values (format nil "(defmethod ~s~{ ~s~} ~s)" name qualifiers lambda-list)
                   (body-docstring (cdr (member lambda-list (cddr form) :test #'eq))))))
        (defclass
         (values (format nil "(defclass ~s ~s (~{~s~^ ~}))" name (third form)
                         (mapcar (lambda (slot) (if (consp slot) (car slot) slot))
                                 (fourth form)))
                 (option-documentation (nthcdr 4 form))))
        ((defparameter defvar)
         (values (format nil "(~(~a~) ~s)" operator name)
                 (let ((doc (fourth form))) (and (stringp doc) doc))))
        (t (values (format nil "~s" form) nil))))))

(defun module-manifest (meta &key (detail :normal))
  "Describe one module. DETAIL is :NAMES, :NORMAL or :FULL."
  (let ((name (getf meta :name)))
    (with-output-to-string (out)
      (format out "~&## ~a [~(~s~)]~@[  depends on: ~{~a~^, ~}~]~%"
              name (getf meta :kind) (getf meta :depends-on))
      (when (plusp (length (getf meta :doc)))
        (format out "~a~%" (getf meta :doc)))
      (dolist (entry (module-forms name))
        (multiple-value-bind (signature doc) (describe-definition (cdr entry))
          (format out "  ~a~%" signature)
          (when doc
            (case detail
              (:normal (format out "      ~a~%" (first-line doc)))
              (:full (dolist (line (split-lines doc))
                       (format out "      ~a~%" line)))))))
      (let ((tests (test-files name)))
        (format out "  tests: ~d~@[ (~{~a~^, ~})~]~%"
                (length tests)
                (and tests (not (eq detail :names)) (mapcar #'pathname-name tests)))))))

(defun manifest-text ()
  "The whole layer as the model sees it each step."
  (let* ((modules (topo-sort-modules (list-modules)))
         (full (format nil "~{~a~}" (mapcar #'module-manifest modules))))
    (cond ((null modules) "(The layer is empty.)")
          ((<= (length full) *manifest-max-chars*) full)
          (t (truncate-string
              (format nil "~{~a~}~%(Abbreviated to signatures. Evaluate (describe-module \"name\") for docstrings.)~%"
                      (mapcar (lambda (meta) (module-manifest meta :detail :names)) modules))
              (* 2 *manifest-max-chars*))))))

(defun describe-module (name)
  "A full description of layer module NAME: every definition with its docstring, and its tests."
  (let ((meta (read-module-meta name)))
    (if meta
        (module-manifest meta :detail :full)
        (format nil "There is no module named ~s." name))))
