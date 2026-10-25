;;; module context -- managed by palimpsest
(defun keep-recent (newest-first budget forced acc)
  "Take entries from NEWEST-FIRST while they fit in BUDGET characters, always taking
the first FORCED of them. Returns the taken entries oldest first, consed onto ACC."
  (let ((entry (first newest-first)))
    (if (or (null newest-first)
            (and (<= forced 0) (> (length (getf entry :text)) budget)))
        acc
        (keep-recent (rest newest-first)
                     (- budget (length (getf entry :text)))
                     (- forced 1)
                     (cons entry acc)))))
