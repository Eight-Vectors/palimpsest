;;; module fs -- managed by palimpsest
(defun list-directory (path)
  "Return the native namestrings of the subdirectories and files directly inside PATH."
  (let ((dir (uiop:ensure-directory-pathname path)))
    (mapcar #'uiop:native-namestring
            (append (uiop:subdirectories dir) (uiop:directory-files dir)))))
