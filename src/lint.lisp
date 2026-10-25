;;;; lint.lisp -- static checks on forms before they are evaluated.
;;;;
;;;; This is a guardrail against accidents and drift, not a security boundary.
;;;; Lisp is reflective enough that determined code can always reach around a
;;;; syntactic check. Run the image in a container with only the access it needs.

(in-package #:palimpsest.kernel)

(defparameter *definition-operators*
  '(defun defmacro defgeneric defmethod defclass defparameter defvar)
  "The only forms (:define ...) accepts, and forms that :eval and tests may not contain.")

(defparameter *mutators*
  '(("COMMON-LISP"
     "SETF" "SETQ" "PSETF" "PSETQ" "INCF" "DECF" "PUSH" "POP" "PUSHNEW" "REMF"
     "ROTATEF" "SHIFTF" "SET" "RPLACA" "RPLACD" "NCONC" "NRECONC" "NREVERSE"
     "NSUBST" "NSUBST-IF" "NSUBSTITUTE" "NSUBSTITUTE-IF" "NSUBLIS" "NINTERSECTION"
     "NUNION" "NSET-DIFFERENCE" "NSET-EXCLUSIVE-OR" "NBUTLAST" "NSTRING-UPCASE"
     "NSTRING-DOWNCASE" "NSTRING-CAPITALIZE" "DELETE" "DELETE-IF" "DELETE-IF-NOT"
     "DELETE-DUPLICATES" "SORT" "STABLE-SORT" "FILL" "REPLACE" "MAP-INTO" "REMHASH"
     "CLRHASH" "VECTOR-PUSH" "VECTOR-PUSH-EXTEND" "VECTOR-POP" "MAKUNBOUND" "FMAKUNBOUND")
    ("FSET" "INCLUDEF" "EXCLUDEF" "ADJOINF" "REMOVEF" "UNIONF" "INTERSECTF"
     "SET-DIFFERENCEF" "IMAGEF" "COMPOSEF" "APPENDF" "PREPENDF" "INSERTF" "SPLICEF"
     "UPDATEF" "MAP-UNIONF" "MAP-INTERSECTF" "HASH-MIXF"
     "PUSH-FIRST" "PUSH-LAST" "POP-FIRST" "POP-LAST"))
  "Forbidden in :pure modules. Names a package does not have are ignored.")

(defparameter *effect-symbols*
  '(("COMMON-LISP"
     "OPEN" "WITH-OPEN-FILE" "WITH-OPEN-STREAM" "DELETE-FILE" "RENAME-FILE"
     "ENSURE-DIRECTORIES-EXIST" "LOAD" "COMPILE-FILE" "DIRECTORY" "PROBE-FILE"
     "FILE-WRITE-DATE" "SLEEP")
    ("PALIMPSEST.KERNEL" "LLM-COMPLETE"))
  "Forbidden in :pure modules, in addition to the packages in *EFFECT-PACKAGE-PREFIXES*.")

(defparameter *effect-package-prefixes*
  '("UIOP" "DEXADOR" "USOCKET" "CL+SSL" "BORDEAUX-THREADS" "BT2")
  "Packages whose every symbol counts as an effect in :pure modules.")

(defparameter *reflective-symbols*
  '(("COMMON-LISP"
     "INTERN" "UNINTERN" "FIND-SYMBOL" "FIND-ALL-SYMBOLS" "DO-SYMBOLS"
     "DO-EXTERNAL-SYMBOLS" "DO-ALL-SYMBOLS" "FIND-PACKAGE" "MAKE-PACKAGE"
     "DELETE-PACKAGE" "RENAME-PACKAGE" "DEFPACKAGE" "IN-PACKAGE" "USE-PACKAGE"
     "UNUSE-PACKAGE" "IMPORT" "EXPORT" "UNEXPORT" "SHADOW" "SHADOWING-IMPORT"
     "SYMBOL-FUNCTION" "FDEFINITION" "SYMBOL-PLIST" "MACRO-FUNCTION"
     "COMPILER-MACRO-FUNCTION"))
  "Forbidden everywhere: they reach around the package boundary the lint relies on.")

(defparameter *forbidden-package-prefixes* '("SB-")
  "Implementation packages the layer may not touch at all.")

(defun resolve-symbols (spec)
  "The symbols named by SPEC, a list of (package-name . symbol-names), skipping missing ones."
  (remove nil (alexandria:mappend
               (lambda (entry)
                 (let ((package (find-package (car entry))))
                   (and package
                        (mapcar (lambda (name) (find-symbol name package)) (cdr entry)))))
               spec)))

(defun prefix-match-p (name prefixes)
  (some (lambda (prefix)
          (and (>= (length name) (length prefix))
               (string= prefix name :end2 (length prefix))))
        prefixes))

(defun kernel-internal-p (symbol)
  "True if SYMBOL lives in the kernel and is not part of PALIMPSEST.API."
  (and (eq (symbol-package symbol) (find-package '#:palimpsest.kernel))
       (multiple-value-bind (found status) (find-symbol (symbol-name symbol) '#:palimpsest.api)
         (not (and (eq found symbol) (eq status :external))))))

(defun form-symbols (form)
  "Every symbol appearing anywhere in FORM, including quoted data."
  (let ((seen (make-hash-table :test 'eq))
        (symbols '()))
    (labels ((walk (x)
               (cond ((symbolp x) (pushnew x symbols))
                     ((consp x)
                      (unless (gethash x seen)
                        (setf (gethash x seen) t)
                        (walk (car x))
                        (walk (cdr x))))
                     ((and (vectorp x) (not (stringp x)))
                      (unless (gethash x seen)
                        (setf (gethash x seen) t)
                        (map nil #'walk x))))))
      (walk form))
    symbols))

(defun lint-form (form context)
  "Return a list of violation messages for FORM, or NIL if it is acceptable.
CONTEXT is :EVAL, :TEST, :PURE or :EFFECT."
  (let ((mutators (resolve-symbols *mutators*))
        (effects (resolve-symbols *effect-symbols*))
        (reflective (resolve-symbols *reflective-symbols*)))
    (flet ((violation (symbol)
             "The message for SYMBOL in CONTEXT, or NIL if it is allowed."
             (let* ((package (symbol-package symbol))
                    (package-name (and package (package-name package))))
               (cond ((null package) nil)
                     ((kernel-internal-p symbol)
                      (format nil "~s is internal to the kernel; only PALIMPSEST.API symbols may be used."
                              symbol))
                     ((prefix-match-p package-name *forbidden-package-prefixes*)
                      (format nil "~s belongs to the implementation package ~a, which the layer may not touch."
                              symbol package-name))
                     ((member symbol reflective)
                      (format nil "~s reaches around packages or function cells, which the layer may not do."
                              symbol))
                     ((and (member context '(:eval :test)) (member symbol *definition-operators*))
                      (format nil "~(~s~) is not allowed in ~(~a~): persistent definitions go through (:define \"module\" form), which lints, tests and commits them. Use flet or labels for throwaway helpers."
                              symbol context))
                     ((and (eq context :pure) (member symbol mutators))
                      (format nil "~s mutates state, and this module is :pure. Build fresh structure or use FSet."
                              symbol))
                     ((and (eq context :pure)
                           (or (member symbol effects)
                               (prefix-match-p package-name *effect-package-prefixes*)))
                      (format nil "~s performs I/O or another effect, and this module is :pure. Put it in an :effect module."
                              symbol))))))
      (remove nil (mapcar #'violation (form-symbols form))))))
