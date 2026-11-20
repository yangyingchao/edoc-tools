;;; edoc-dev.el --- Mother's little development helper  -*- lexical-binding: t; -*-

;; Copyright (C) 2015  Andreas Politz

;; Author: Andreas Politz <politza@hochschule-trier.de>
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; This file is only meant for developers.  The entry point is
;; edoc-dev-minor-mode, which see.

;;; Code:

(defvar edoc-dev-root-directory
  (file-name-directory
   (directory-file-name
    (file-name-directory load-file-name))))

(defun edoc-dev-reload ()
  "Reload Lisp files from source."
  (interactive)
  (let ((default-directory (expand-file-name
                            "lisp"
                            edoc-dev-root-directory))
        loaded)
    (dolist (file (directory-files default-directory nil "\\\\`edoc-\\\\w*\\\\.el\\\\'"))
      (push file loaded)
      (load-file file))
    (message "Loaded %s" (mapconcat 'identity loaded " "))))

(define-minor-mode edoc-dev-minor-mode
  "Make developing edoc-tools easier.

It does the following:

Sets up `load-path' and reloads all PDF Tools Lisp files.

The kc server binary is provided by PATH, so there is no local
build step to trigger."
  :group 'edoc-dev
  (let ((lisp-dir (expand-file-name "lisp" edoc-dev-root-directory)))
    (setq load-path (remove lisp-dir load-path))
    (cond
     (edoc-dev-minor-mode
      (add-to-list 'load-path lisp-dir)
      (edoc-info-quit)
      (edoc-dev-reload)))))

(provide 'edoc-dev)
;;; edoc-dev.el ends here
