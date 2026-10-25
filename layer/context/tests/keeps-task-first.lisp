;;; test context/keeps-task-first -- append-only
(let ((context (assemble-context (list (list :role :user :text "the task")
                                       (list :role :assistant :text "thinking")
                                       (list :role :user :text "a result"))
                                 1000)))
  (and (= (length context) 3)
       (equal (getf (first context) :text) "the task")
       (eq (getf (car (last context)) :role) :user)))
