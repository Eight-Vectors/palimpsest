;;; test fs/reads-its-own-module-file -- append-only
(let ((text (read-text-file (merge-pathnames "fs/MODULE.sexp" (layer-root)))))
  (and (stringp text) (search ":effect" text) t))
