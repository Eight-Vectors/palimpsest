;;;; llm.lisp -- the model call. Swappable through *LLM-BACKEND*.

(in-package #:palimpsest.kernel)

(defun json-object (&rest keys-and-values)
  (alexandria:plist-hash-table keys-and-values :test 'equal))

(defun call-with-api-retries (thunk &key (attempts 4))
  "Call THUNK, retrying on rate limits and transient server errors."
  (loop for attempt from 1
        do (handler-case (return (funcall thunk))
             (dex:http-request-failed (e)
               (let ((status (dex:response-status e)))
                 (if (and (< attempt attempts)
                          (member status '(429 500 502 503 504 529)))
                     (progn (log-event :api-retry :status status :attempt attempt)
                            (sleep (expt 2 attempt)))
                     (error "Anthropic API request failed with HTTP ~a: ~a"
                            status
                            (truncate-string (let ((body (dex:response-body e)))
                                               (if (stringp body) body (format nil "~a" body)))
                                             800))))))))

(defun response-text (json raw)
  (let ((content (gethash "content" json)))
    (unless (vectorp content)
      (error "Unexpected API response: ~a" (truncate-string raw 800)))
    (format nil "~{~a~}"
            (mapcar (lambda (block) (gethash "text" block))
                    (remove "text" (coerce content 'list)
                            :key (lambda (block) (gethash "type" block))
                            :test-not #'equal)))))

(defun anthropic-backend (system messages)
  "Send SYSTEM and MESSAGES to the Anthropic Messages API and return the reply text.
Reads ANTHROPIC_API_KEY from the environment at call time."
  (let ((key (uiop:getenv "ANTHROPIC_API_KEY")))
    (unless (and key (plusp (length key)))
      (error "ANTHROPIC_API_KEY is not set."))
    (let* ((body (com.inuoe.jzon:stringify
                  (json-object
                   "model" *model*
                   "max_tokens" *max-tokens*
                   "system" system
                   "messages" (map 'vector
                                   (lambda (message)
                                     (json-object "role" (string-downcase (symbol-name (car message)))
                                                  "content" (cdr message)))
                                   messages))))
           (reply (call-with-api-retries
                   (lambda ()
                     (dex:post *anthropic-url*
                               :headers `(("x-api-key" . ,key)
                                          ("anthropic-version" . "2023-06-01")
                                          ("content-type" . "application/json"))
                               :content body))))
           (raw (if (stringp reply)
                    reply
                    (sb-ext:octets-to-string reply :external-format :utf-8))))
      (response-text (com.inuoe.jzon:parse raw) raw))))

(defun make-scripted-backend (replies)
  "A stand-in model for tests and demos: returns REPLIES in order.
Second value: a function returning everything the backend was sent, oldest first."
  (let ((queue (copy-list replies))
        (seen '()))
    (values (lambda (system messages)
              (push (cons system messages) seen)
              (if queue
                  (pop queue)
                  (error "The scripted backend ran out of replies.")))
            (lambda () (reverse seen)))))

(defun llm-complete (system messages)
  "Call the configured model. SYSTEM is a string; MESSAGES is a list of
(:user . text) and (:assistant . text) conses, starting and ending with :user."
  (funcall *llm-backend* system messages))
