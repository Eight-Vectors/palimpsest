;;;; packages.lisp -- the kernel, the API the layer may use, and the layer itself.

#-sbcl (error "Palimpsest currently requires SBCL: it relies on package locks and live backtraces.")

(defpackage #:palimpsest.kernel
  (:use #:cl)
  (:nicknames #:palimpsest)
  (:export
   ;; Operator API
   #:init-layer #:start #:run-task #:reload-layer #:rollback #:history
   #:print-transcript #:protect-kernel #:unprotect-kernel
   #:anthropic-backend #:make-scripted-backend
   ;; Configuration
   #:*layer-root* #:*model* #:*max-tokens* #:*llm-backend* #:*step-budget*
   #:*eval-timeout* #:*hook-timeout* #:*test-timeout* #:*debugger-max-depth*
   #:*context-max-chars* #:*result-max-chars* #:*manifest-max-chars*
   #:*use-git* #:*verbose* #:*locked-packages*
   ;; Re-exported to the layer through PALIMPSEST.API
   #:retryable #:llm-complete #:log-event #:describe-module #:current-task #:layer-root))

(defpackage #:palimpsest.api
  (:use)
  (:import-from #:palimpsest.kernel
                #:retryable #:llm-complete #:log-event #:describe-module #:current-task #:layer-root)
  (:export #:retryable #:llm-complete #:log-event #:describe-module #:current-task #:layer-root)
  (:documentation "Everything code in the layer may use from the kernel."))

(defpackage #:palimpsest.layer
  (:use #:cl #:palimpsest.api)
  (:documentation "Where the agent's definitions live. Rebuilt from the layer directory by START."))
