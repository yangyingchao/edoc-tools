;;; test-helper --- Test helper for edoc-tools  -*- lexical-binding: t; -*-

;;; Commentary:
;; test helper inspired from https://github.com/tonini/overseer.el/blob/master/test/test-helper.el

;;; Code:

(require 'package)
(require 'ert)
(require 'cl-lib)

(unless (getenv "PACKAGE_TAR")
  (error "Missing package tar. Must be passed by PACKAGE_TAR env variable"))

(defvar edoc-tools-package (expand-file-name (getenv "PACKAGE_TAR")))

(unless (and (file-exists-p edoc-tools-package)
             (string-match "\\.tar\\'" edoc-tools-package))
  (error "Invalid tar package: %s" edoc-tools-package))

(unless load-file-name
  (error "load-file-name is unset"))

(cd (file-name-directory load-file-name))
(setq package-user-dir (expand-file-name "elpa" (make-temp-file "package" t)))

(defvar cask-elpa
  (cl-labels ((directory-if-exists-p (directory)
                (and (file-directory-p directory)
                     directory)))
    (or (directory-if-exists-p
         (format "../.cask/%s/elpa" emacs-version))
        (directory-if-exists-p
         (format "../.cask/%d.%d/elpa"
                 emacs-major-version emacs-minor-version))
        (error "Do `cask install' first"))))

(add-to-list 'package-directory-list cask-elpa)
(add-hook 'kill-emacs-hook (lambda nil
                             (when (file-exists-p package-user-dir)
                               (delete-directory package-user-dir t))))
(package-initialize)
(package-install-file edoc-tools-package)

;; FIXME: Move functions to new, loadable file.
;; Fake skipped as accepted failures if skip-unless is not available.
(unless (fboundp 'ert--skip-unless)
  (defun skip-unless (arg)
    (unless arg
      (setf (ert-test-expected-result-type
             (car ert--running-tests))
            :failed)
      (ert-fail (list nil)))))

(defun edoc-test-relative-edges-p (edges)
  (and (consp edges)
       (cl-every (lambda (x)
                   (and (numberp x)
                        (<= x 1)
                        (>= x 0)))
                 edges)))

(defmacro edoc-test-with-pdf (edoc-filename &rest body)
  (declare (indent 0) (debug t))
  (let ((buffer (make-symbol "buffer")))
    `(let ((,buffer (find-file-noselect
                     (expand-file-name ,edoc-filename)))
           (edoc-info-kc-error-filename (make-temp-file "kc.log")))
       (unwind-protect
           (progn
             (edoc-info-quit)
             (edoc-info-process-assert-running t)
             (with-current-buffer ,buffer ,@body))
         (when (buffer-live-p ,buffer)
           (with-current-buffer ,buffer
             (set-buffer-modified-p nil)
             (let (kill-buffer-hook)
               (kill-buffer))))
         (when (file-exists-p edoc-info-kc-error-filename)
           (with-temp-buffer
             (insert-file-contents edoc-info-kc-error-filename)
             (unless (= 1 (point-max))
               (message ">>> %s <<<" (buffer-string))))
           (delete-file edoc-info-kc-error-filename))
         (edoc-info-quit)))))

(defmacro edoc-test-with-test-pdf (&rest body)
  `(edoc-test-with-pdf "test.pdf" ,@body))

(defmacro edoc-test-with-encrypted-pdf (&rest body)
  `(edoc-test-with-pdf "encrypted.pdf" ,@body))

;; ---
(require 'undercover)
(undercover "lisp/*.el")
(require 'let-alist)
(require 'edoc-info)
(require 'ert)
(require 'edoc-tools)

;; FIXME: Can't be compiled with the Package-Requires dependencies alone.
;; Local Variables:
;; no-byte-compile: t
;; End:

;;; test-helper.el ends here
