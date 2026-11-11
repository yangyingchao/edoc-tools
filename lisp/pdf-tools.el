;;; pdf-tools.el --- Support library for PDF documents -*- lexical-binding:t -*-

;; Copyright (C) 2013, 2014  Andreas Politz

;; Author: Andreas Politz <mail@andreas-politz.de>
;; Maintainer: Vedang Manerikar <vedang.manerikar@gmail.com>
;; URL: http://github.com/vedang/pdf-tools/
;; Keywords: files, multimedia
;; Package: pdf-tools
;; Version: 1.1.0
;; Package-Requires: ((emacs "26.3") (tablist "1.0") (let-alist "1.0.4") (dash "2.18.0") (s "1.11.0"))

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
;; PDF Tools is, among other things, a replacement of DocView for PDF
;; files.  The key difference is, that pages are not prerendered by
;; e.g. ghostscript and stored in the file-system, but rather created
;; on-demand and stored in memory.
;;
;; Note: This package is built and tested on GNU/Linux systems. It
;; works on macOS and Windows, but is officially supported only on
;; GNU/Linux systems. This package will not make macOS or Windows
;; specific functionality changes, behaviour on these systems is
;; provided as-is.
;;
;; Note: If you ever update it, you need to restart Emacs afterwards.
;;
;; To activate the package put
;;
;; (pdf-tools-install)
;;
;; somewhere in your .emacs.el .
;;
;; M-x pdf-tools-help RET
;;
;; gives some help on using the package and
;;
;; M-x pdf-tools-customize RET
;;
;; offers some customization options.

;; Features:
;;
;; * View
;;   View PDF documents in a buffer with DocView-like bindings.
;;
;; * Isearch
;;   Interactively search PDF documents like any other buffer. (Though
;;   there is currently no regexp support.)
;;
;; * Follow links
;;   Click on highlighted links, moving to some part of a different
;;   page, some external file, a website or any other URI.  Links may
;;   also be followed by keyboard commands.
;;
;; * Annotations
;;   Display and list text and markup annotations (like underline),
;;   edit their contents and attributes (e.g. color), move them around,
;;   delete them or create new ones and then save the modifications
;;   back to the PDF file.
;;
;; * Attachments
;;   Save files attached to the PDF-file or list them in a Dired buffer.
;;
;; * Outline
;;   Use imenu or a special buffer to examine and navigate the PDF's
;;   outline.
;;
;; * SyncTeX
;;   Jump from a position on a page directly to the TeX source and
;;   vice-versa.
;;
;; * Keyboard navigation
;;   Navigate pdf files using the keyboard like standard Emacs buffers.
;;
;; * Misc
;;    + Display PDF's metadata.
;;    + Mark a region and kill the text from the PDF.
;;    + Search for occurrences of a string.
;;    + Keep track of visited pages via a history.

;;; Code:

(require 'pdf-view)
(require 'pdf-util)
(require 'pdf-info)
(require 'cus-edit)
(require 'compile)
(require 'cl-lib)
(require 'package)



;; * ================================================================== *
;; * Customizables
;; * ================================================================== *

(defgroup pdf-tools nil
  "Support library for PDF documents."
  :group 'data)

(defgroup pdf-tools-faces nil
  "Faces determining the colors used in the pdf-tools package.

In order to customize dark and light colors use
`pdf-tools-customize-faces', or set `custom-face-default-form' to
'all."
  :group 'pdf-tools)

(defconst pdf-tools-modes
  '(pdf-history-minor-mode
    pdf-isearch-minor-mode
    pdf-links-minor-mode
    pdf-misc-minor-mode
    pdf-outline-minor-mode
    pdf-misc-size-indication-minor-mode
    pdf-misc-menu-bar-minor-mode
    pdf-annot-minor-mode
    pdf-sync-minor-mode
    pdf-misc-context-menu-minor-mode
    pdf-cache-prefetch-minor-mode
    pdf-view-auto-slice-minor-mode
    pdf-occur-global-minor-mode
    pdf-virtual-global-minor-mode
    pdf-keynav-minor-mode))

(defcustom pdf-tools-enabled-modes
  '(pdf-history-minor-mode
    pdf-isearch-minor-mode
    pdf-links-minor-mode
    pdf-misc-minor-mode
    pdf-outline-minor-mode
    pdf-misc-size-indication-minor-mode
    pdf-misc-menu-bar-minor-mode
    pdf-annot-minor-mode
    pdf-sync-minor-mode
    pdf-misc-context-menu-minor-mode
    pdf-cache-prefetch-minor-mode
    pdf-occur-global-minor-mode)
  "A list of automatically enabled minor-modes.

PDF Tools is build as a series of minor-modes.  This variable and
the function `pdf-tools-install' merely serve as a convenient
wrapper in order to load these modes in current and newly created
PDF buffers."
  :group 'pdf-tools
  :type `(set ,@(mapcar (lambda (mode)
                          `(function-item ,mode))
                        pdf-tools-modes)))

(defcustom pdf-tools-enabled-hook nil
  "A hook ran after PDF Tools is enabled in a buffer."
  :group 'pdf-tools
  :type 'hook)

(defconst pdf-tools-auto-mode-alist-entry
  '("\\.[pP][dD][fF]\\'" . pdf-view-mode)
  "The entry to use for `auto-mode-alist'.")

(defconst pdf-tools-magic-mode-alist-entry
  '("%PDF" . pdf-view-mode)
  "The entry to use for `magic-mode-alist'.")

(defun pdf-tools-customize ()
  "Customize Pdf Tools."
  (interactive)
  (customize-group 'pdf-tools))

(defun pdf-tools-customize-faces ()
  "Customize PDF Tool's faces."
  (interactive)
  (let ((buffer (format "*Customize Group: %s*"
                        (custom-unlispify-tag-name 'pdf-tools-faces))))
    (when (buffer-live-p (get-buffer buffer))
      (with-current-buffer (get-buffer buffer)
        (rename-uniquely)))
    (customize-group 'pdf-tools-faces)
    (with-current-buffer buffer
      (set (make-local-variable 'custom-face-default-form) 'all))))


;; * ================================================================== *
;; * Installation
;; * ================================================================== *

;;;###autoload
(defcustom pdf-tools-handle-upgrades t
  "Whether PDF Tools should handle upgrading itself."
  :group 'pdf-tools
  :type 'boolean)

(make-obsolete-variable 'pdf-tools-handle-upgrades
                        "Not used anymore" "0.90")

(defconst pdf-tools-directory
  (or (and load-file-name
           (file-name-directory load-file-name))
      default-directory)
  "The directory from where this library was first loaded.")

;;;###autoload
(defun pdf-tools-install (&optional no-query-p skip-dependencies-p
                                    no-error-p force-dependencies-p)
  "Install PDF-Tools in all current and future PDF buffers.

The epdfinfo server must already exist.  Build it with `make' in
the pdf-tools source tree, or set `pdf-info-epdfinfo-program' to
an existing executable.  This function no longer compiles the
server itself; NO-QUERY-P, SKIP-DEPENDENCIES-P, NO-ERROR-P and
FORCE-DEPENDENCIES-P are accepted for backward compatibility and
ignored.

See `pdf-view-mode' and `pdf-tools-enabled-modes'."
  (interactive)
  (ignore no-query-p skip-dependencies-p no-error-p force-dependencies-p)
  (if (or (pdf-info-running-p)
          (ignore-errors (pdf-info-check-epdfinfo) t))
      (pdf-tools-install-noverify)
    (user-error
     "No working epdfinfo program; build it with `make' or set `pdf-info-epdfinfo-program'")))

(defun pdf-tools-install-noverify ()
  "Like `pdf-tools-install', but skip checking `pdf-info-epdfinfo-program'."
  (add-to-list 'auto-mode-alist pdf-tools-auto-mode-alist-entry)
  (add-to-list 'magic-mode-alist pdf-tools-magic-mode-alist-entry)
  ;; FIXME: Generalize this sometime.
  (when (memq 'pdf-occur-global-minor-mode
              pdf-tools-enabled-modes)
    (pdf-occur-global-minor-mode 1))
  (when (memq 'pdf-virtual-global-minor-mode
              pdf-tools-enabled-modes)
    (pdf-virtual-global-minor-mode 1))
  (add-hook 'pdf-view-mode-hook #'pdf-tools-enable-minor-modes)
  (dolist (buf (buffer-list))
    ;; This when check should not be necessary, but somehow dead
    ;; buffers are showing up here. See
    ;; https://github.com/vedang/pdf-tools/pull/93
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and (not (derived-mode-p 'pdf-view-mode))
                   (pdf-tools-pdf-buffer-p)
                   (buffer-file-name))
          (pdf-view-mode))))))

(defun pdf-tools-uninstall ()
  "Uninstall PDF-Tools in all current and future PDF buffers."
  (interactive)
  (pdf-info-quit)
  (setq-default auto-mode-alist
    (remove pdf-tools-auto-mode-alist-entry auto-mode-alist))
  (setq-default magic-mode-alist
    (remove pdf-tools-magic-mode-alist-entry magic-mode-alist))
  (pdf-occur-global-minor-mode -1)
  (pdf-virtual-global-minor-mode -1)
  (remove-hook 'pdf-view-mode-hook #'pdf-tools-enable-minor-modes)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (pdf-util-pdf-buffer-p buf)
        (pdf-tools-disable-minor-modes pdf-tools-modes)
        (normal-mode)))))

(defun pdf-tools-pdf-buffer-p (&optional buffer)
  "Check if the current buffer is a PDF document.

Optionally, take BUFFER as an argument and check if it is a PDF document."
  (save-current-buffer
    (when buffer (set-buffer buffer))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char 1)
        (looking-at "%PDF")))))

(defun pdf-tools-assert-pdf-buffer (&optional buffer)
  "Throw an error if the current BUFFER does not contain a PDF document."
  (unless (pdf-tools-pdf-buffer-p buffer)
    (error "Buffer does not contain a PDF document")))

(defun pdf-tools-set-modes-enabled (enable &optional modes)
  "Enable/Disable all the pdf-tools modes on the current buffer based on ENABLE.

Accepts MODES as a optional argument to enable/disable specific modes."
  (dolist (m (or modes pdf-tools-enabled-modes))
    (let ((enabled-p (and (boundp m)
                          (symbol-value m))))
      (unless (or (and enabled-p enable)
                  (and (not enabled-p) (not enable)))
        (funcall m (if enable 1 -1))))))

;;;###autoload
(defun pdf-tools-enable-minor-modes (&optional modes)
  "Enable MODES in the current buffer.

MODES defaults to `pdf-tools-enabled-modes'."
  (interactive)
  (pdf-util-assert-pdf-buffer)
  (pdf-tools-set-modes-enabled t modes)
  (run-hooks 'pdf-tools-enabled-hook))

(defun pdf-tools-disable-minor-modes (&optional modes)
  "Disable MODES in the current buffer.

MODES defaults to `pdf-tools-enabled-modes'."
  (interactive)
  (pdf-tools-set-modes-enabled nil modes))

(declare-function pdf-occur-global-minor-mode "pdf-occur.el")
(declare-function pdf-virtual-global-minor-mode "pdf-virtual.el")

;;;###autoload
(defun pdf-tools-help ()
  "Show a Help buffer for `pdf-tools'."
  (interactive)
  (help-setup-xref (list #'pdf-tools-help)
                   (called-interactively-p 'interactive))
  (with-help-window (help-buffer)
    (princ "PDF Tools Help\n\n")
    (princ "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n")
    (dolist (m (cons 'pdf-view-mode
                     (sort (copy-sequence pdf-tools-modes) #'string<)))
      (princ (format "`%s' is " m))
      (describe-function-1 m)
      (terpri) (terpri)
      (princ "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n"))))


;; * ================================================================== *
;; * Debugging
;; * ================================================================== *

(defvar pdf-tools-debug nil
  "Non-nil, if debugging PDF Tools.")

(defun pdf-tools-toggle-debug ()
  "Turn debugging on/off for pdf-tools."
  (interactive)
  (setq pdf-tools-debug (not pdf-tools-debug))
  (when (called-interactively-p 'any)
    (message "Toggled debugging %s" (if pdf-tools-debug "on" "off"))))

(provide 'pdf-tools)

;;; pdf-tools.el ends here
