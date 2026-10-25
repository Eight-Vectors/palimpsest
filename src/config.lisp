;;;; config.lisp -- knobs. All are special variables, so they can be rebound per task.

(in-package #:palimpsest.kernel)

(defun env (name &optional default)
  (let ((value (uiop:getenv name)))
    (if (and value (plusp (length value))) value default)))

(defun env-int (name default)
  (let ((value (env name)))
    (or (and value (ignore-errors (parse-integer value))) default)))

(defvar *layer-root* nil
  "Directory holding the evolvable layer. Each module is a subdirectory, and the
whole tree is a git repository so every accepted change is a commit.")

(defvar *model* (env "PALIMPSEST_MODEL" "claude-sonnet-5-5")
  "Model id sent to the Anthropic Messages API.")

(defvar *max-tokens* (env-int "PALIMPSEST_MAX_TOKENS" 4096))

(defvar *anthropic-url* "https://api.anthropic.com/v1/messages")

(defvar *llm-backend* 'anthropic-backend
  "Function of (SYSTEM MESSAGES) returning the model's reply as a string.
MESSAGES is a list of (role . text) conses, role :USER or :ASSISTANT.")

(defvar *step-budget* (env-int "PALIMPSEST_STEP_BUDGET" 40)
  "Model calls allowed per task, debugger turns included.")

(defvar *eval-timeout* 120
  "Seconds before an agent evaluation is interrupted. NIL disables the limit.")

(defvar *hook-timeout* 10 "Seconds a layer hook may run before the kernel falls back.")

(defvar *test-timeout* 30 "Seconds a single layer test may run.")

(defvar *debugger-max-depth* 3
  "How many agent debuggers may nest before errors simply propagate.")

(defvar *context-max-chars* 80000
  "Character budget handed to ASSEMBLE-CONTEXT.")

(defvar *result-max-chars* 6000
  "Longest result, output or backtrace shown to the model in one message.")

(defvar *manifest-max-chars* 16000
  "Beyond this size the manifest switches to a signatures-only view.")

(defvar *use-git* t "Commit every accepted change to the layer's git repository.")

(defvar *verbose* t "Log kernel events to *TRACE-OUTPUT*.")

(defvar *locked-packages* '("PALIMPSEST.KERNEL" "PALIMPSEST.API")
  "Packages locked by PROTECT-KERNEL. Add third-party packages here to stop code
in the layer from redefining their functions as well.")
