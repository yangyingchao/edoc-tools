;;; edoc-tools.el --- Support library for PDF documents -*- lexical-binding:t -*-

;; Copyright (C) 2013, 2014  Andreas Politz

;; Author: Andreas Politz <mail@andreas-politz.de>
;; Maintainer: Vedang Manerikar <vedang.manerikar@gmail.com>
;; URL: http://github.com/vedang/pdf-tools/
;; Keywords: files, multimedia
;; Package: edoc-tools
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
;; (edoc-tools-install)
;;
;; somewhere in your .emacs.el .
;;
;; M-x edoc-tools-help RET
;;
;; gives some help on using the package and
;;
;; M-x edoc-tools-customize RET
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

(require 'edoc-view)
(require 'edoc-util)
(require 'edoc-info)
(require 'cus-edit)
(require 'compile)
(require 'cl-lib)
(require 'package)



;; * ================================================================== *
;; * Customizables
;; * ================================================================== *

(defgroup edoc-tools nil
  "Support library for PDF documents."
  :group 'data)

(defgroup edoc-tools-faces nil
  "Faces determining the colors used in the edoc-tools package.

In order to customize dark and light colors use
`edoc-tools-customize-faces', or set `custom-face-default-form' to
'all."
  :group 'edoc-tools)

(defconst edoc-tools-modes
  '(edoc-history-minor-mode
    edoc-isearch-minor-mode
    edoc-links-minor-mode
    edoc-misc-minor-mode
    edoc-outline-minor-mode
    edoc-misc-size-indication-minor-mode
    edoc-misc-menu-bar-minor-mode
    edoc-annot-minor-mode
    edoc-sync-minor-mode
    edoc-misc-context-menu-minor-mode
    edoc-cache-prefetch-minor-mode
    edoc-view-auto-slice-minor-mode
    edoc-occur-global-minor-mode
    edoc-virtual-global-minor-mode
    edoc-keynav-minor-mode))

(defcustom edoc-tools-enabled-modes
  '(edoc-history-minor-mode
    edoc-isearch-minor-mode
    edoc-links-minor-mode
    edoc-misc-minor-mode
    edoc-outline-minor-mode
    edoc-misc-size-indication-minor-mode
    edoc-misc-menu-bar-minor-mode
    edoc-annot-minor-mode
    edoc-sync-minor-mode
    edoc-misc-context-menu-minor-mode
    edoc-cache-prefetch-minor-mode
    edoc-occur-global-minor-mode)
  "A list of automatically enabled minor-modes.

PDF Tools is build as a series of minor-modes.  This variable and
the function `edoc-tools-install' merely serve as a convenient
wrapper in order to load these modes in current and newly created
PDF buffers."
  :group 'edoc-tools
  :type `(set ,@(mapcar (lambda (mode)
                          `(function-item ,mode))
                        edoc-tools-modes)))

(defcustom edoc-tools-enabled-hook nil
  "A hook ran after PDF Tools is enabled in a buffer."
  :group 'edoc-tools
  :type 'hook)

(defconst edoc-tools-auto-mode-alist-entry
  '("\\.[pP][dD][fF]\\'" . edoc-view-mode)
  "The entry to use for `auto-mode-alist'.")

(defconst edoc-tools-magic-mode-alist-entry
  '("%PDF" . edoc-view-mode)
  "The entry to use for `magic-mode-alist'.")

(defun edoc-tools-customize ()
  "Customize Pdf Tools."
  (interactive)
  (customize-group 'edoc-tools))

(defun edoc-tools-customize-faces ()
  "Customize PDF Tool's faces."
  (interactive)
  (let ((buffer (format "*Customize Group: %s*"
                        (custom-unlispify-tag-name 'edoc-tools-faces))))
    (when (buffer-live-p (get-buffer buffer))
      (with-current-buffer (get-buffer buffer)
        (rename-uniquely)))
    (customize-group 'edoc-tools-faces)
    (with-current-buffer buffer
      (set (make-local-variable 'custom-face-default-form) 'all))))


;; * ================================================================== *
;; * Installation
;; * ================================================================== *

;;;###autoload
(defcustom edoc-tools-handle-upgrades t
  "Whether PDF Tools should handle upgrading itself."
  :group 'edoc-tools
  :type 'boolean)

(make-obsolete-variable 'edoc-tools-handle-upgrades
                        "Not used anymore" "0.90")

(defconst edoc-tools-directory
  (or (and load-file-name
           (file-name-directory load-file-name))
      default-directory)
  "The directory from where this library was first loaded.")

;;;###autoload
(defun edoc-tools-install (&optional no-query-p skip-dependencies-p
                                    no-error-p force-dependencies-p)
  "Install edoc-tools in all current and future PDF buffers.

The kc server must already exist.  Provide it on PATH or set
`edoc-info-kc-program' to an existing executable; the server is built by
the knowcraft project and is not part of this repository.  This function
does not compile the server itself; NO-QUERY-P, SKIP-DEPENDENCIES-P,
NO-ERROR-P and FORCE-DEPENDENCIES-P are accepted for backward
compatibility and ignored.

See `edoc-view-mode' and `edoc-tools-enabled-modes'."
  (interactive)
  (ignore no-query-p skip-dependencies-p no-error-p force-dependencies-p)
  (if (or (edoc-info-running-p)
          (ignore-errors (edoc-info-check-kc) t))
      (edoc-tools-install-noverify)
    (user-error
     "No working kc program; put it on PATH or set `edoc-info-kc-program'")))

(defun edoc-tools-install-noverify ()
  "Like `edoc-tools-install', but skip checking `edoc-info-kc-program'."
  (add-to-list 'auto-mode-alist edoc-tools-auto-mode-alist-entry)
  (add-to-list 'magic-mode-alist edoc-tools-magic-mode-alist-entry)
  ;; FIXME: Generalize this sometime.
  (when (memq 'edoc-occur-global-minor-mode
              edoc-tools-enabled-modes)
    (edoc-occur-global-minor-mode 1))
  (when (memq 'edoc-virtual-global-minor-mode
              edoc-tools-enabled-modes)
    (edoc-virtual-global-minor-mode 1))
  (add-hook 'edoc-view-mode-hook #'edoc-tools-enable-minor-modes)
  (dolist (buf (buffer-list))
    ;; This when check should not be necessary, but somehow dead
    ;; buffers are showing up here. See
    ;; https://github.com/vedang/edoc-tools/pull/93
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and (not (derived-mode-p 'edoc-view-mode))
                   (edoc-tools-edoc-buffer-p)
                   (buffer-file-name))
          (edoc-view-mode))))))

(defun edoc-tools-uninstall ()
  "Uninstall edoc-tools in all current and future PDF buffers."
  (interactive)
  (edoc-info-quit)
  (setq-default auto-mode-alist
    (remove edoc-tools-auto-mode-alist-entry auto-mode-alist))
  (setq-default magic-mode-alist
    (remove edoc-tools-magic-mode-alist-entry magic-mode-alist))
  (edoc-occur-global-minor-mode -1)
  (edoc-virtual-global-minor-mode -1)
  (remove-hook 'edoc-view-mode-hook #'edoc-tools-enable-minor-modes)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (edoc-util-edoc-buffer-p buf)
        (edoc-tools-disable-minor-modes edoc-tools-modes)
        (normal-mode)))))

(defun edoc-tools-edoc-buffer-p (&optional buffer)
  "Check if the current buffer is a PDF document.

Optionally, take BUFFER as an argument and check if it is a PDF document."
  (save-current-buffer
    (when buffer (set-buffer buffer))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char 1)
        (looking-at "%PDF")))))

(defun edoc-tools-assert-edoc-buffer (&optional buffer)
  "Throw an error if the current BUFFER does not contain a PDF document."
  (unless (edoc-tools-edoc-buffer-p buffer)
    (error "Buffer does not contain a PDF document")))

(defun edoc-tools-set-modes-enabled (enable &optional modes)
  "Enable/Disable all the edoc-tools modes on the current buffer based on ENABLE.

Accepts MODES as a optional argument to enable/disable specific modes."
  (dolist (m (or modes edoc-tools-enabled-modes))
    (let ((enabled-p (and (boundp m)
                          (symbol-value m))))
      (unless (or (and enabled-p enable)
                  (and (not enabled-p) (not enable)))
        (funcall m (if enable 1 -1))))))

;;;###autoload
(defun edoc-tools-enable-minor-modes (&optional modes)
  "Enable MODES in the current buffer.

MODES defaults to `edoc-tools-enabled-modes'."
  (interactive)
  (edoc-util-assert-edoc-buffer)
  (edoc-tools-set-modes-enabled t modes)
  (run-hooks 'edoc-tools-enabled-hook))

(defun edoc-tools-disable-minor-modes (&optional modes)
  "Disable MODES in the current buffer.

MODES defaults to `edoc-tools-enabled-modes'."
  (interactive)
  (edoc-tools-set-modes-enabled nil modes))

(declare-function edoc-occur-global-minor-mode "edoc-occur.el")
(declare-function edoc-virtual-global-minor-mode "edoc-virtual.el")

;;;###autoload
(defun edoc-tools-help ()
  "Show a Help buffer for `edoc-tools'."
  (interactive)
  (help-setup-xref (list #'edoc-tools-help)
                   (called-interactively-p 'interactive))
  (with-help-window (help-buffer)
    (princ "edoc-tools Help\n\n")
    (princ "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n")
    (dolist (m (cons 'edoc-view-mode
                     (sort (copy-sequence edoc-tools-modes) #'string<)))
      (princ (format "`%s' is " m))
      (describe-function-1 m)
      (terpri) (terpri)
      (princ "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n"))))


;; * ================================================================== *
;; * Debugging
;; * ================================================================== *

(defvar edoc-tools-debug nil
  "Non-nil, if debugging PDF Tools.")

(defun edoc-tools-toggle-debug ()
  "Turn debugging on/off for edoc-tools."
  (interactive)
  (setq edoc-tools-debug (not edoc-tools-debug))
  (when (called-interactively-p 'any)
    (message "Toggled debugging %s" (if edoc-tools-debug "on" "off"))))

(provide 'edoc-tools)

;;; edoc-tools.el ends here
