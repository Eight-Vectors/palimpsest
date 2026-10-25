;;; test fs/lists-the-layer -- append-only
(some (lambda (entry) (search "context" entry))
      (list-directory (layer-root)))
