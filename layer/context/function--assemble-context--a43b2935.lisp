;;; module context -- managed by palimpsest
(defun assemble-context (transcript max-chars)
  "Choose which transcript entries the model sees. TRANSCRIPT is a list of
(:role <:user|:assistant> :text <string>) plists, oldest first, starting with the
task. Keeps the task, always the latest exchange, and as many earlier entries as
fit in MAX-CHARS, cutting only at assistant boundaries so roles alternate."
  (let* ((task (first transcript))
         (budget (- max-chars (length (getf task :text))))
         (kept (keep-recent (reverse (rest transcript)) budget 2 '())))
    (cons task (member :assistant kept :key (lambda (entry) (getf entry :role))))))
