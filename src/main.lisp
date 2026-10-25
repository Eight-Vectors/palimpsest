;;;; main.lisp -- operator entry points.

(in-package #:palimpsest.kernel)

(defun protect-kernel ()
  "Lock the kernel's packages so code evaluated in the layer cannot redefine them."
  (dolist (name *locked-packages* t)
    (let ((package (find-package name)))
      (when package (sb-ext:lock-package package)))))

(defun unprotect-kernel ()
  "Unlock the kernel's packages, for working on the kernel itself."
  (dolist (name *locked-packages* t)
    (let ((package (find-package name)))
      (when package (sb-ext:unlock-package package)))))

(defun copy-directory-tree (from to)
  (ensure-directories-exist to)
  (dolist (file (uiop:directory-files from))
    (uiop:copy-file file (uiop:subpathname to (file-namestring file))))
  (dolist (dir (uiop:subdirectories from))
    (let ((name (car (last (pathname-directory dir)))))
      (unless (char= (char name 0) #\.)
        (copy-directory-tree dir (uiop:subpathname to (concatenate 'string name "/")))))))

(defun init-layer (target &key (seed (asdf:system-relative-pathname :palimpsest "layer/")))
  "Create a new layer at TARGET from the seed layer, as its own git repository."
  (let ((target (resolve-directory target)))
    (when (and (uiop:directory-exists-p target)
               (or (uiop:directory-files target) (uiop:subdirectories target)))
      (error "~a is not empty; refusing to overwrite an existing layer." target))
    (copy-directory-tree seed target)
    (let ((*layer-root* target))
      (when *use-git*
        (git "init" "-q")
        (git-commit "seed layer")))
    target))

(defun start (root &key (protect t))
  "Load the layer at ROOT into this image, run its tests and lock the kernel.
Returns a plist summarising what loaded and which tests fail, if any."
  (let ((root (resolve-directory root)))
    (unless (uiop:directory-exists-p root)
      (error "No layer at ~a. Create one with (palimpsest:init-layer ~s)." root (namestring root)))
    (setf *layer-root* root)
    (when (and *use-git* (not (git-repository-p)))
      (git "init" "-q")
      (git-commit "adopt existing layer"))
    (when protect (protect-kernel))
    (multiple-value-bind (loaded load-failures) (load-layer)
      (multiple-value-bind (test-failures total) (run-tests)
        (log-event :started :root (namestring root) :definitions loaded
                   :tests total :failing (length test-failures))
        (list :root root :definitions loaded :load-failures load-failures
              :tests total :test-failures test-failures)))))

(defun reload-layer ()
  "Re-evaluate every definition in the layer from disk."
  (ensure-root)
  (load-layer))

(defun history (&optional (count 20))
  "The layer's recent commits, newest first."
  (ensure-root)
  (nth-value 1 (git "log" "--oneline" "-n" (princ-to-string count))))

(defun rollback (&optional (count 1))
  "Revert the last COUNT commits to the layer and bring the image in line with the result."
  (ensure-root)
  (unless *use-git*
    (error "Rollback needs git, and *USE-GIT* is NIL."))
  (let ((base (format nil "HEAD~~~d" count)))
    (multiple-value-bind (status added) (git "diff" "--name-only" "--diff-filter=A" base "HEAD")
      (unless (zerop status)
        (error "git diff against ~a failed. Is there enough history to roll back ~d commit~:p?"
               base count))
      ;; Definitions created in the reverted commits must be removed from the image too.
      (dolist (relative (split-lines added))
        (let ((path (uiop:subpathname (ensure-root) relative)))
          (when (and (equal (pathname-type path) "lisp")
                     (not (search "/tests/" relative))
                     (probe-file path))
            (handler-case (undefine-form (read-form-file path))
              (error (e)
                (log-event :rollback-undefine-failed :file relative :error (condition-text e))))))))
    (multiple-value-bind (status out err) (git "revert" "--no-edit" (format nil "~a..HEAD" base))
      (declare (ignore out))
      (unless (zerop status)
        (error "git revert failed: ~a" err))))
  (load-layer))
