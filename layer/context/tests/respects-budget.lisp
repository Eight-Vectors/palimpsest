;;; test context/respects-budget -- append-only
(let ((context (assemble-context
                (list (list :role :user :text "the task")
                      (list :role :assistant :text (make-string 500 :initial-element #\a))
                      (list :role :user :text (make-string 500 :initial-element #\b))
                      (list :role :assistant :text "short")
                      (list :role :user :text "short too"))
                100)))
  (and (= (length context) 3)
       (eq (getf (second context) :role) :assistant)
       (equal (getf (third context) :text) "short too")))
