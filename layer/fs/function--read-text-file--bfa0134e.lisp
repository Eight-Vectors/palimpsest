;;; module fs -- managed by palimpsest
(defun read-text-file (path &key (max-chars 20000))
  "Return up to MAX-CHARS characters of the text file at PATH, a string or pathname."
  (let ((text (uiop:read-file-string path)))
    (if (> (length text) max-chars)
        (subseq text 0 max-chars)
        text)))
