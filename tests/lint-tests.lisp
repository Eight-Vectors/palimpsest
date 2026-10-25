(in-package #:palimpsest.tests)
(in-suite :palimpsest)

(test pure-modules-reject-mutation
  (is (lint "(defun bump (x) (setf x 1))" :pure))
  (is (lint "(defun order (xs) (sort xs #'<))" :pure)))

(test pure-modules-accept-pure-code
  (is (null (lint "(defun twice (x) \"Double X.\" (* 2 x))" :pure))))

(test pure-modules-reject-io
  (is (lint "(defun slurp (p) (uiop:read-file-string p))" :pure))
  (is (null (lint "(defun slurp (p) (uiop:read-file-string p))" :effect))))

(test eval-may-not-define
  (is (lint "(defun helper () 1)" :eval))
  (is (null (lint "(flet ((helper () 1)) (helper))" :eval))))

(test kernel-internals-are-off-limits
  (is (lint "(palimpsest.kernel::git \"status\")" :eval))
  (is (lint "(sb-ext:exit)" :eval))
  (is (lint "(find-symbol \"GIT\" \"PALIMPSEST.KERNEL\")" :effect)))

(test the-api-is-allowed
  (is (null (lint "(retryable (\"add\") (+ 1 2))" :eval)))
  (is (null (lint "(describe-module \"context\")" :eval))))

(test pure-modules-reject-fset-mutation
  (is (lint "(defun grow (s) (fset:appendf s (fset:seq 1)) s)" :pure))
  (is (lint "(defun put (m) (fset:includef m 1) m)" :pure))
  (is (null (lint "(defun grown (s) (fset:concat s (fset:seq 1)))" :pure))))
