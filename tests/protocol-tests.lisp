(in-package #:palimpsest.tests)
(in-suite :palimpsest)

(test reads-the-last-fenced-block
  (is (equal '(:eval (+ 1 2))
             (read-action (format nil "First I add.~%```lisp~%(:eval (+ 1 2))~%```~%Done.")))))

(test reads-an-unfenced-reply
  (is (equal '(:done "ok") (read-action "(:done \"ok\")"))))

(test rejects-two-forms
  (signals palimpsest.kernel::protocol-error (read-action "(:eval 1) (:eval 2)")))

(test reports-unbalanced-parentheses
  (signals palimpsest.kernel::protocol-error (read-action "(:eval (+ 1 2)")))

(test read-eval-is-off
  (signals palimpsest.kernel::protocol-error (read-action "(:eval #.(+ 1 2))")))

(test rejects-unknown-actions
  (signals palimpsest.kernel::protocol-error (read-action "(:launch-rockets)")))

(test rejects-non-actions
  (signals palimpsest.kernel::protocol-error (read-action "42")))
