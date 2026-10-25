;;;; util.lisp -- shared helpers.

(in-package #:palimpsest.kernel)

(defun layer-package ()
  (find-package '#:palimpsest.layer))

(defun layer-root ()
  "The directory holding the evolvable layer, as a pathname."
  *layer-root*)

(defmacro with-layer-syntax (&body body)
  "Standard reader and printer settings, with *PACKAGE* set to the layer and *READ-EVAL* off."
  `(with-standard-io-syntax
     (let ((*package* (layer-package))
           (*read-eval* nil)
           (*print-readably* nil)
           (*print-case* :downcase)
           (*print-circle* t)
           (*print-pretty* t)
           (*print-right-margin* 100))
       ,@body)))

(define-condition eval-timeout (serious-condition)
  ((seconds :initarg :seconds :reader eval-timeout-seconds))
  (:report (lambda (condition stream)
             (format stream "Evaluation exceeded its ~d second limit." (eval-timeout-seconds condition)))))

(defvar *active-timeouts* '()
  "Tokens of the evaluation timeouts currently in force, innermost first.")

(defvar *paused-timeouts* '()
  "Tokens of timeouts that must not fire, because the agent debugger is talking to the
model inside their evaluation. Time spent debugging does not count against an evaluation.")

(defun call-with-eval-timeout (seconds thunk)
  (if (not (and seconds (plusp seconds)))
      (funcall thunk)
      (let* ((token (list :timeout))
             (timer nil))
        (setf timer (sb-ext:make-timer
                     (lambda ()
                       (if (member token *paused-timeouts* :test #'eq)
                           (sb-ext:schedule-timer timer seconds)
                           (error 'eval-timeout :seconds seconds)))
                     :name "palimpsest eval timeout"))
        (let ((*active-timeouts* (cons token *active-timeouts*)))
          (unwind-protect
               (progn (sb-ext:schedule-timer timer seconds)
                      (funcall thunk))
            (sb-ext:unschedule-timer timer))))))

(defmacro with-eval-timeout ((&optional (seconds '*eval-timeout*)) &body body)
  "Run BODY, signalling EVAL-TIMEOUT after SECONDS unless paused. NIL means no limit."
  `(call-with-eval-timeout ,seconds (lambda () ,@body)))

(define-condition protocol-error (error)
  ((message :initarg :message :reader protocol-error-message))
  (:report (lambda (condition stream)
             (write-string (protocol-error-message condition) stream))))

(defun protocol-fail (control &rest args)
  "Signal a PROTOCOL-ERROR whose message is shown to the model."
  (error 'protocol-error :message (apply #'format nil control args)))

(defun truncate-string (string limit)
  (if (and limit (> (length string) limit))
      (format nil "~a~%...[~d more characters truncated]"
              (subseq string 0 limit) (- (length string) limit))
      string))

(defun condition-text (condition)
  (handler-case (format nil "~(~a~): ~a" (type-of condition) (princ-to-string condition))
    (error () (format nil "~a (unprintable)" (type-of condition)))))

(defun render (object &optional (limit *result-max-chars*))
  "Print OBJECT for the model: bounded, never signalling."
  (truncate-string
   (handler-case
       (with-layer-syntax
         (let ((*print-length* 50)
               (*print-level* 8))
           (prin1-to-string object)))
     (error () (format nil "#<unprintable ~a>" (ignore-errors (type-of object)))))
   limit))

(defun log-event (kind &rest plist)
  "Write a one-line event to *TRACE-OUTPUT* when *VERBOSE* is true. Callable from the layer."
  (when *verbose*
    (let ((*print-pretty* nil)
          (*print-length* 20)
          (*print-level* 4))
      (format *trace-output* "~&[palimpsest] ~(~a~)~{ ~(~a~)=~a~}~%"
              kind
              (alexandria:mappend (lambda (pair)
                                    (let ((value (cdr pair)))
                                      (list (car pair)
                                            (if (stringp value)
                                                (truncate-string value 300)
                                                (prin1-to-string value)))))
                                  (alexandria:plist-alist plist)))
      (force-output *trace-output*)))
  nil)

(defun quiet-warning (warning)
  "Muffle WARNING if it can be muffled."
  (let ((restart (find-restart 'muffle-warning warning)))
    (when restart (invoke-restart restart))))

(defun redefinition-warning-p (warning)
  (search "REDEFINITION" (symbol-name (type-of warning))))

(defmacro collecting-warnings ((var) &body body)
  "Run BODY with VAR bound to a list collecting the text of warnings BODY signals,
newest first. Warnings are muffled; redefinition notices are dropped."
  `(let ((,var '()))
     (handler-bind ((warning (lambda (w)
                               (unless (redefinition-warning-p w)
                                 (push (condition-text w) ,var))
                               (quiet-warning w))))
       ,@body)))

(defun short-hash (string)
  "Eight lowercase hex digits of the 32-bit FNV-1a hash of STRING. Stable across runs."
  (format nil "~(~8,'0x~)"
          (reduce (lambda (hash char)
                    (logand #xffffffff (* (logxor hash (char-code char)) #x01000193)))
                  string
                  :initial-value #x811c9dc5)))

(defun filename-safe (string)
  (let ((safe (map 'string
                   (lambda (c)
                     (if (or (and (char< c (code-char 128)) (alphanumericp c))
                             (find c "-_"))
                         (char-downcase c)
                         #\_))
                   string)))
    (if (plusp (length safe)) safe "_")))

(defun split-lines (string)
  (remove "" (uiop:split-string string :separator '(#\Newline)) :test #'string=))

(defun resolve-directory (designator)
  "Turn a string or pathname into an absolute directory pathname, expanding a leading ~/."
  (let* ((string (if (pathnamep designator) (namestring designator) designator))
         (expanded (if (and (>= (length string) 2) (string= "~/" string :end2 2))
                       (concatenate 'string
                                    (namestring (user-homedir-pathname))
                                    (subseq string 2))
                       string)))
    (uiop:ensure-directory-pathname
     (uiop:ensure-absolute-pathname (uiop:parse-native-namestring expanded)
                                    (uiop:getcwd)))))
