(in-package #:palimpsest.tests)
(in-suite :palimpsest)

(test seed-layer-is-green
  (with-temp-layer ()
    (multiple-value-bind (failures total) (palimpsest.kernel::run-tests)
      (is (null failures))
      (is (plusp total)))))

(test accepted-definitions-are-live-and-on-disk
  (with-temp-layer ()
    (is (eq :accepted (getf (palimpsest.kernel::create-module "math" :pure "Arithmetic.") :status)))
    (let ((result (palimpsest.kernel::propose-definition
                   "math" (layer-read "(defun twice (x) \"Double X.\" (* 2 x))"))))
      (is (eq :accepted (getf result :status)))
      (is (= 10 (funcall (layer-symbol "twice") 5)))
      (is (probe-file (merge-pathnames (getf result :file) palimpsest.kernel:*layer-root*))))))

(test lint-failures-change-nothing
  (with-temp-layer ()
    (palimpsest.kernel::create-module "math" :pure "Arithmetic.")
    (let ((result (palimpsest.kernel::propose-definition
                   "math" (layer-read "(defun counter (x) (incf x))"))))
      (is (eq :rejected (getf result :status)))
      (is (equal "lint" (getf result :stage))))))

(test failing-tests-restore-the-previous-definition
  (with-temp-layer ()
    (palimpsest.kernel::create-module "math" :pure "Arithmetic.")
    (palimpsest.kernel::propose-definition "math" (layer-read "(defun triple (x) (* 3 x))"))
    (is (eq :accepted (getf (palimpsest.kernel::propose-test
                             "math" "triple-of-two" (layer-read "(= (triple 2) 6)"))
                            :status)))
    (let ((result (palimpsest.kernel::propose-definition
                   "math" (layer-read "(defun triple (x) (+ x 3))"))))
      (is (eq :rejected (getf result :status)))
      (is (equal "tests" (getf result :stage))))
    (is (= 6 (funcall (layer-symbol "triple") 2)))))

(test tests-are-append-only-and-must-pass
  (with-temp-layer ()
    (palimpsest.kernel::create-module "math" :pure "Arithmetic.")
    (is (eq :accepted (getf (palimpsest.kernel::propose-test "math" "truth" (layer-read "(= 1 1)"))
                            :status)))
    (is (eq :rejected (getf (palimpsest.kernel::propose-test "math" "truth" (layer-read "t"))
                            :status)))
    (is (eq :rejected (getf (palimpsest.kernel::propose-test "math" "falsehood" (layer-read "(= 1 2)"))
                            :status)))))

(test module-kinds-are-fixed
  (with-temp-layer ()
    (is (eq :rejected (getf (palimpsest.kernel::create-module "context" :effect "Sneaky.")
                            :status)))))

(test definitions-belong-to-one-module
  (with-temp-layer ()
    (palimpsest.kernel::create-module "other" :pure "Another module.")
    (let ((result (palimpsest.kernel::propose-definition
                   "other" (layer-read "(defun system-addendum () \"hijacked\")"))))
      (is (eq :rejected (getf result :status)))
      (is (equal "ownership" (getf result :stage))))))

(test the-layer-reloads-from-disk
  (with-temp-layer ()
    (palimpsest.kernel::create-module "math" :pure "Arithmetic.")
    (palimpsest.kernel::propose-definition "math" (layer-read "(defun quadruple (x) (* 4 x))"))
    (fmakunbound (layer-symbol "quadruple"))
    (palimpsest.kernel:reload-layer)
    (is (= 8 (funcall (layer-symbol "quadruple") 2)))))

(test seed-filenames-match-their-keys
  ;; Lookup is by reading forms, but filenames should still agree with the definition key.
  (with-temp-layer ()
    (dolist (meta (palimpsest.kernel::list-modules))
      (dolist (path (palimpsest.kernel::definition-files (getf meta :name)))
        (multiple-value-bind (operator name key)
            (palimpsest.kernel::definition-key (palimpsest.kernel::read-form-file path))
          (is (equal (palimpsest.kernel::definition-filename operator name key)
                     (file-namestring path))))))))

(test modules-load-after-their-dependencies
  (let ((palimpsest.kernel:*verbose* nil))
    (is (equal '("a" "b" "c" "loop")
               (mapcar (lambda (meta) (getf meta :name))
                       (palimpsest.kernel::topo-sort-modules
                        (list (list :name "c" :depends-on '("b"))
                              (list :name "a" :depends-on '())
                              (list :name "b" :depends-on '("a" "missing"))
                              (list :name "loop" :depends-on '("loop")))))))))
