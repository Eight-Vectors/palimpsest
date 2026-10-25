;;;; palimpsest.asd

(asdf:defsystem #:palimpsest
  :description "A self-evolving agent harness on a live Common Lisp image."
  :author "Palimpsest contributors"
  :license "MIT"
  :version "0.1.0"
  :depends-on (#:alexandria #:fset #:dexador #:com.inuoe.jzon)
  :serial t
  :pathname "src/"
  :components ((:file "packages")
               (:file "config")
               (:file "util")
               (:file "session")
               (:file "llm")
               (:file "protocol")
               (:file "lint")
               (:file "store")
               (:file "manifest")
               (:file "gate")
               (:file "prompts")
               (:file "debugger")
               (:file "agent")
               (:file "main"))
  :in-order-to ((asdf:test-op (asdf:test-op #:palimpsest/tests))))

(asdf:defsystem #:palimpsest/tests
  :description "Kernel tests. They use a scripted model, so no API key is needed."
  :depends-on (#:palimpsest #:fiveam)
  :serial t
  :pathname "tests/"
  :components ((:file "package")
               (:file "protocol-tests")
               (:file "lint-tests")
               (:file "gate-tests")
               (:file "debugger-tests"))
  ;; Signal on failure, so that `sbcl --non-interactive` exits nonzero in CI.
  :perform (asdf:test-op (o c)
             (unless (uiop:symbol-call :fiveam :run! :palimpsest)
               (error "Palimpsest tests failed."))))
