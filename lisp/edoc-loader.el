;;; edoc-loader.el --- Minimal PDF Tools loader       -*- lexical-binding: t; -*-

;; Copyright (C) 2017  Andreas Politz

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

;;; Code:

(defconst edoc-loader--auto-mode-alist-item
  (copy-sequence "\\.[pP][dD][fF]\\'")
  "The item used in `auto-mode-alist'.")

(defconst edoc-loader--magic-mode-alist-item
  (copy-sequence "%PDF")
  "The item used in`magic-mode-alist'.")


(declare-function edoc-tools-install "edoc-tools.el")

;;;###autoload
(defun edoc-loader-install (&optional no-query-p skip-dependencies-p
                                     no-error-p force-dependencies-p)
  "Prepare Emacs for using PDF Tools.

This function acts as a replacement for `edoc-tools-install' and
makes Emacs load and use PDF Tools as soon as a PDF file is
opened, but not sooner.

The arguments are passed verbatim to `edoc-tools-install', which
see."
  (let ((args (list no-query-p skip-dependencies-p
                    no-error-p force-dependencies-p)))
    (if (featurep 'edoc-tools)
        (apply #'edoc-tools-install args)
      (edoc-loader--install
       (lambda ()
         (apply #'edoc-loader--load args))))))

(defun edoc-loader--load (&rest args)
  (edoc-loader--uninstall)
  (save-selected-window
    (apply #'edoc-tools-install args)))

(defun edoc-loader--install (loader)
  (edoc-loader--uninstall)
  (push (cons edoc-loader--auto-mode-alist-item loader)
        auto-mode-alist)
  (push (cons edoc-loader--magic-mode-alist-item loader)
        magic-mode-alist))

(defun edoc-loader--uninstall ()
  (let ((elt (assoc edoc-loader--auto-mode-alist-item
                    auto-mode-alist)))
    (when elt
      (setq auto-mode-alist (remove elt auto-mode-alist))))
  (let ((elt (assoc edoc-loader--magic-mode-alist-item
                    magic-mode-alist)))
    (when elt
      (setq magic-mode-alist (remove elt magic-mode-alist)))))

(provide 'edoc-loader)
;;; edoc-loader.el ends here
