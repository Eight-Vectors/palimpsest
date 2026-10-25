;;;; store.lisp -- the layer on disk.
;;;;
;;;;   <root>/<module>/MODULE.sexp         (:kind :pure|:effect :doc "..." :depends-on ("..."))
;;;;   <root>/<module>/<definition>.lisp   exactly one top-level definition per file
;;;;   <root>/<module>/tests/<name>.lisp   one form per file; passes if it returns true

(in-package #:palimpsest.kernel)

(defun ensure-root ()
  (or *layer-root*
      (error "No layer is loaded. Call (palimpsest:start \"/path/to/layer/\") first.")))

(defun valid-module-name-p (name)
  (and (stringp name)
       (<= 1 (length name) 40)
       (char<= #\a (char name 0) #\z)
       (every (lambda (c) (or (char<= #\a c #\z) (char<= #\0 c #\9) (char= c #\-))) name)))

(defun module-dir (name)
  (uiop:subpathname (ensure-root) (concatenate 'string name "/")))

(defun module-meta-path (name)
  (uiop:subpathname (module-dir name) "MODULE.sexp"))

(defun read-form-file (path)
  (with-open-file (stream path :external-format :utf-8)
    (with-layer-syntax (read stream))))

(defun write-form-file (path form &optional header)
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output :if-exists :supersede
                               :if-does-not-exist :create :external-format :utf-8)
    (with-layer-syntax
      (when header (format stream ";;; ~a~%" header))
      (write form :stream stream :pretty t :readably t)
      (terpri stream)))
  path)

;;; Modules

(defun normalize-meta (name plist)
  (let ((doc (getf plist :doc))
        (depends-on (getf plist :depends-on)))
    (list :name name
          ;; Anything unrecognised is treated as :pure, the stricter kind.
          :kind (if (eq (getf plist :kind) :effect) :effect :pure)
          :doc (if (stringp doc) doc "")
          :depends-on (remove-if-not #'stringp (if (alexandria:proper-list-p depends-on) depends-on '())))))

(defun read-module-meta (name)
  (when (valid-module-name-p name)
    (let ((path (module-meta-path name)))
      (when (probe-file path)
        (handler-case (normalize-meta name (read-form-file path))
          (error (e)
            (log-event :unreadable-module :module name :error (condition-text e))
            nil))))))

(defun list-modules ()
  (sort (loop for dir in (uiop:subdirectories (ensure-root))
              for name = (car (last (pathname-directory dir)))
              for meta = (and (stringp name) (read-module-meta name))
              when meta collect meta)
        #'string< :key (lambda (meta) (getf meta :name))))

(defun topo-sort-modules (metas)
  "Order METAS so every module follows the modules it depends on. A cycle is logged
and broken where it is found."
  (let ((by-name (fset:convert 'fset:map
                               (mapcar (lambda (meta) (cons (getf meta :name) meta)) metas))))
    (labels ((visit (state name visiting)
               ;; STATE is (done-names . ordered-metas-newest-first); VISITING is the path here.
               (let ((meta (fset:lookup by-name name)))
                 (cond ((or (null meta) (fset:contains? (car state) name)) state)
                       ((fset:contains? visiting name)
                        (log-event :module-cycle :module name)
                        state)
                       (t (let ((after-dependencies
                                  (reduce (lambda (state dependency)
                                            (visit state dependency (fset:with visiting name)))
                                          (getf meta :depends-on)
                                          :initial-value state)))
                            (cons (fset:with (car after-dependencies) name)
                                  (cons meta (cdr after-dependencies)))))))))
      (reverse (cdr (reduce (lambda (state meta) (visit state (getf meta :name) (fset:empty-set)))
                            metas
                            :initial-value (cons (fset:empty-set) '())))))))

(defun definition-files (module)
  (sort (uiop:directory-files (module-dir module) "*.lisp")
        #'string< :key #'file-namestring))

(defun test-files (module)
  (sort (uiop:directory-files (uiop:subpathname (module-dir module) "tests/") "*.lisp")
        #'string< :key #'file-namestring))

;;; Definitions

(defun definition-category (operator)
  (ecase operator
    ((defun defmacro defgeneric) "function")
    ((defparameter defvar) "variable")
    (defclass "class")
    (defmethod "method")))

(defun method-signature (form)
  "Qualifiers, specializers and lambda list of a DEFMETHOD form."
  (let* ((others (cddr form))
         (qualifiers (loop for x in others until (listp x) collect x))
         (lambda-list (find-if #'listp others))
         (specializers (loop for parameter in lambda-list
                             until (member parameter lambda-list-keywords)
                             collect (if (consp parameter) (second parameter) t))))
    (values qualifiers specializers lambda-list)))

(defun definition-key (form)
  "Validate FORM as a layer definition. Returns (values operator name key), where
KEY identifies what FORM defines, so two forms with the same key replace each other."
  (unless (and (consp form) (member (car form) *definition-operators*))
    (protocol-fail "The form to define must be one of ~(~{~a~^, ~}~). Got: ~a"
                   *definition-operators* (render form 200)))
  (let ((operator (first form))
        (name (second form)))
    (unless (and name (symbolp name) (eq (symbol-package name) (layer-package)))
      (protocol-fail "Definitions must be named by a symbol in PALIMPSEST.LAYER; got ~a."
                     (render name 200)))
    (values operator
            name
            (with-layer-syntax
              (if (eq operator 'defmethod)
                  (multiple-value-bind (qualifiers specializers) (method-signature form)
                    (format nil "method ~s ~s ~s" name qualifiers specializers))
                  (format nil "~a ~s" (definition-category operator) name))))))

(defun definition-filename (operator name key)
  (format nil "~a--~a--~a.lisp"
          (definition-category operator)
          (filename-safe (symbol-name name))
          (short-hash key)))

(defun definition-index ()
  "An FSet map from each definition key in the layer to (module . path), built by
reading every file."
  (flet ((index-entries (meta)
           (remove nil
                   (mapcar (lambda (path)
                             (handler-case
                                 (cons (nth-value 2 (definition-key (read-form-file path)))
                                       (cons (getf meta :name) path))
                               (error (e)
                                 (log-event :unreadable-definition :file (namestring path)
                                            :error (condition-text e))
                                 nil)))
                           (definition-files (getf meta :name))))))
    (fset:convert 'fset:map (alexandria:mappend #'index-entries (list-modules)))))

(defparameter *load-rank*
  '((defclass . 0) (defgeneric . 1) (defmacro . 2)
    (defparameter . 3) (defvar . 3) (defun . 4) (defmethod . 5))
  "Within a module, classes and macros load before the code that uses them.")

(defun module-forms (module)
  "MODULE's definitions as (path . form), in load order."
  (stable-sort (remove nil
                       (mapcar (lambda (path)
                                 (handler-case (cons path (read-form-file path))
                                   (error (e)
                                     (log-event :unreadable-definition :file (namestring path)
                                                :error (condition-text e))
                                     nil)))
                               (definition-files module)))
               #'<
               :key (lambda (entry)
                      (let ((form (cdr entry)))
                        (or (and (consp form) (cdr (assoc (car form) *load-rank*)))
                            9)))))

(defun load-entry (entry)
  "Evaluate one (path . form) ENTRY from MODULE-FORMS. Returns NIL on success, or
(file . error-text) on failure."
  (let ((file (enough-namestring (car entry) (ensure-root))))
    (handler-case
        (handler-bind ((warning #'quiet-warning))
          (with-layer-syntax (eval (cdr entry)))
          nil)
      (error (e)
        (log-event :load-failed :file file :error (condition-text e))
        (cons file (condition-text e))))))

(defun load-layer ()
  "Evaluate every definition in the layer, module by module in dependency order.
Returns (values definitions-loaded failures), FAILURES a list of (file . error)."
  (let ((outcomes (mapcar #'load-entry
                          (alexandria:mappend (lambda (meta) (module-forms (getf meta :name)))
                                              (topo-sort-modules (list-modules))))))
    (values (count nil outcomes) (remove nil outcomes))))

;;; Undoing definitions

(defun undefine (operator name &optional method)
  "Remove what a definition with OPERATOR and NAME created. METHOD is the method
object, for DEFMETHOD."
  (ecase operator
    ((defun defmacro defgeneric) (when (fboundp name) (fmakunbound name)))
    ((defparameter defvar) (makunbound name))
    (defclass (setf (find-class name) nil))
    (defmethod (when method
                 (remove-method (sb-mop:method-generic-function method) method)))))

(defun find-method-for-form (form)
  "The method object a stored DEFMETHOD form defined, if it is still installed."
  (let ((name (second form)))
    (when (and (fboundp name) (typep (fdefinition name) 'generic-function))
      (multiple-value-bind (qualifiers specializers) (method-signature form)
        (let ((classes (mapcar (lambda (specializer)
                                 (if (and (consp specializer) (eq (car specializer) 'eql))
                                     (sb-mop:intern-eql-specializer
                                      (with-layer-syntax (eval (second specializer))))
                                     (find-class specializer nil)))
                               specializers)))
          (unless (member nil classes)
            (find-method (fdefinition name) qualifiers classes nil)))))))

(defun undefine-form (form)
  (undefine (first form) (second form)
            (when (eq (first form) 'defmethod) (find-method-for-form form))))

;;; Version control

(defun git (&rest args)
  "Run git in the layer directory. Returns (values exit-status stdout stderr)."
  (handler-case
      (multiple-value-bind (out err status)
          (uiop:run-program (list* "git" "-C" (uiop:native-namestring (ensure-root))
                                   "-c" "user.name=palimpsest"
                                   "-c" "user.email=palimpsest@localhost.invalid"
                                   args)
                            :output :string :error-output :string
                            :ignore-error-status t)
        (values status out err))
    (error (e) (values 127 "" (condition-text e)))))

(defun git-repository-p ()
  (probe-file (uiop:subpathname (ensure-root) ".git/")))

(defun git-commit (message)
  (when *use-git*
    (git "add" "-A")
    (multiple-value-bind (status out err) (git "commit" "-q" "-m" message)
      (declare (ignore out))
      (unless (zerop status)
        (log-event :git-commit-failed :message message :error err))
      (zerop status))))
