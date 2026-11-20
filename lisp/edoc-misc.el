;;; edoc-misc.el --- Miscellaneous commands for PDF buffer.  -*- lexical-binding: t; -*-

;; Copyright (C) 2013, 2014  Andreas Politz

;; Author: Andreas Politz <politza@fh-trier.de>
;; Keywords: files, multimedia

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


(require 'edoc-view)
(require 'edoc-util)
(require 'imenu)



;;; Code:

(defvar edoc-misc-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "I") 'edoc-misc-display-metadata)
    (define-key map (kbd "C-c C-p") 'edoc-misc-print-document)
    map)
  "Keymap used in `edoc-misc-minor-mode'.")

;;;###autoload
(define-minor-mode edoc-misc-minor-mode
  "FIXME:  Not documented."
  :group 'edoc-misc)

;;;###autoload
(define-minor-mode edoc-misc-size-indication-minor-mode
  "Provide a working size indication in the mode-line."
  :group 'edoc-misc
  (edoc-util-assert-edoc-buffer)
  (cond
   (edoc-misc-size-indication-minor-mode
    (unless (assq 'edoc-misc-size-indication-minor-mode
                  mode-line-position)
      (setq mode-line-position
            `((edoc-misc-size-indication-minor-mode
               (:eval (edoc-misc-size-indication)))
              ,@mode-line-position))))
   (t
    (setq mode-line-position
          (cl-remove 'edoc-misc-size-indication-minor-mode
                     mode-line-position :key 'car-safe)))))

(defun edoc-misc-size-indication ()
  "Return size indication string for the mode-line."
  (let ((top (= (window-vscroll nil t) 0))
        (bot (>= (+ (- (nth 3 (window-inside-pixel-edges))
                       (nth 1 (window-inside-pixel-edges)))
                    (window-vscroll nil t))
                 (cdr (edoc-view-image-size t)))))
    (cond
     ((and top bot) " All")
     (top " Top")
     (bot " Bot")
     (t (format
         " %d%%%%"
         (ceiling
          (* 100 (/ (float (window-vscroll nil t))
                    (cdr (edoc-view-image-size t))))))))))

(defvar edoc-misc-menu-bar-minor-mode-map (make-sparse-keymap)
  "The keymap used in `edoc-misc-menu-bar-minor-mode'.")

(easy-menu-define nil edoc-misc-menu-bar-minor-mode-map
  "Menu for PDF Tools."
  `("PDF Tools"
    ["Go Backward" edoc-history-backward
     :visible (bound-and-true-p edoc-history-minor-mode)
     :active (and (bound-and-true-p edoc-history-minor-mode)
                  (not (edoc-history-end-of-history-p)))]
    ["Go Forward" edoc-history-forward
     :visible (bound-and-true-p edoc-history-minor-mode)
     :active (not (edoc-history-end-of-history-p))]
    ["--" nil
     :visible (derived-mode-p 'edoc-virtual-view-mode)]
    ["Next file" edoc-virtual-buffer-forward-file
     :visible  (derived-mode-p 'edoc-virtual-view-mode)
     :active (edoc-virtual-document-next-file
              (edoc-view-current-page))]
    ["Previous file" edoc-virtual-buffer-backward-file
     :visible (derived-mode-p 'edoc-virtual-view-mode)
     :active (not (eq 1 (edoc-view-current-page)))]
    ["--" nil
     :visible (bound-and-true-p edoc-history-minor-mode)]
    ["Add text annotation" edoc-annot-mouse-add-text-annotation
     :visible (bound-and-true-p edoc-annot-minor-mode)
     :keys "\\[edoc-annot-add-text-annotation]"]
    ("Add markup annotation"
     :active (edoc-view-active-region-p)
     :visible (and (bound-and-true-p edoc-annot-minor-mode)
                   (edoc-info-markup-annotations-p))
     ["highlight" edoc-annot-add-highlight-markup-annotation]
     ["squiggly" edoc-annot-add-squiggly-markup-annotation]
     ["underline" edoc-annot-add-underline-markup-annotation]
     ["strikeout" edoc-annot-add-strikeout-markup-annotation])
    ["--" nil :visible (bound-and-true-p edoc-annot-minor-mode)]
    ["Display Annotations" edoc-annot-list-annotations
     :help "List all annotations"
     :visible (bound-and-true-p edoc-annot-minor-mode)]
    ["Display Attachments" edoc-annot-attachment-dired
     :help "Display attachments in a dired buffer"
     :visible (featurep 'edoc-annot)]
    ["Display Metadata" edoc-misc-display-metadata
     :help "Display information about the document"
     :visible (featurep 'edoc-misc)]
    ["Display Outline" edoc-outline
     :help "Display documents outline"
     :visible (featurep 'edoc-outline)]
    "--"
    ("Render Options"
     ["Printed Mode" (lambda ()
                       (interactive)
                       (edoc-view-printer-minor-mode 'toggle))
      :style toggle
      :selected edoc-view-printer-minor-mode
      :help "Display the PDF as it would be printed."]
     ["Midnight Mode" (lambda ()
                        (interactive)
                        (edoc-view-midnight-minor-mode 'toggle))
      :style toggle
      :selected edoc-view-midnight-minor-mode
      :help "Apply a color-filter appropriate for past midnight reading."])
    "--"
    ["Copy region" edoc-view-kill-ring-save
     :keys "\\[kill-ring-save]"
     :active (edoc-view-active-region-p)]
    ("Selection style"
     ["Glyph" (edoc-view-set-selection-style 'glyph)
      :style radio
      :selected (eq edoc-view-selection-style 'glyph)
      :help "When dragging the mouse, select individual characters."]
     ["Word" (edoc-view-set-selection-style 'word)
      :style radio
      :selected (eq edoc-view-selection-style 'word)
      :help "When dragging the mouse, select entire words."]
     ["Line" (edoc-view-set-selection-style 'line)
      :style radio
      :selected (eq edoc-view-selection-style 'line)
      :help "When dragging the mouse, select entire lines."])
    "--"
    ["Isearch document" isearch-forward
     :visible (bound-and-true-p edoc-isearch-minor-mode)]
    ["Occur document" edoc-occur
     :visible (featurep 'edoc-occur)]
    "--"
    ["Locate TeX source" edoc-sync-backward-search-mouse
     :visible (and (featurep 'edoc-sync)
                   (equal last-command-event
                          last-nonmenu-event))]
    ["--" nil :visible (and (featurep 'edoc-sync)
                            (equal last-command-event
                                   last-nonmenu-event))]
    ["Print" edoc-misc-print-document
     :active (and (edoc-view-buffer-file-name)
                  (file-readable-p (edoc-view-buffer-file-name)))]
    ["Create image" edoc-view-extract-region-image
     :help "Create an image of the page or the selected region(s)."]
    ["Create virtual PDF" edoc-virtual-buffer-create
     :help "Create a PDF containing all documents in this directory."
     :visible (bound-and-true-p edoc-virtual-global-minor-mode)]
    "--"
    ["Revert buffer" edoc-view-revert-buffer
     :visible (edoc-info-writable-annotations-p)]
    "--"
    ["Customize" edoc-tools-customize]))

;;;###autoload
(define-minor-mode edoc-misc-menu-bar-minor-mode
  "Display a PDF Tools menu in the menu-bar."
  :group 'edoc-misc
  (edoc-util-assert-edoc-buffer))

(defvar edoc-misc-context-menu-minor-mode-map
  (let ((kmap (make-sparse-keymap)))
    (define-key kmap [down-mouse-3] 'edoc-misc-popup-context-menu)
    kmap))

;;;###autoload
(define-minor-mode edoc-misc-context-menu-minor-mode
  "Provide a right-click context menu in PDF buffers.

\\{edoc-misc-context-menu-minor-mode-map}"
  :group 'edoc-misc
  (edoc-util-assert-edoc-buffer))

(defun edoc-misc-popup-context-menu (_event)
  "Popup a context menu at position."
  (interactive "@e")
  (popup-menu
   (cons 'keymap
         (cddr (or (lookup-key edoc-misc-menu-bar-minor-mode-map
                               [menu-bar PDF\ Tools])
                   (lookup-key edoc-misc-menu-bar-minor-mode-map
                               [menu-bar pdf\ tools]))))))

(defun edoc-misc-display-metadata ()
  "Display all available metadata in a separate buffer."
  (interactive)
  (edoc-util-assert-edoc-buffer)
  (let* ((buffer (current-buffer))
         (md (edoc-info-metadata)))
    (with-current-buffer (get-buffer-create "*PDF-Metadata*")
      (let* ((inhibit-read-only t)
             (pad (apply' max (mapcar (lambda (d)
                                        (length (symbol-name (car d))))
                                      md)))
             (fmt (format "%%%ds:%%s\n" pad)))
        (erase-buffer)
        (setq header-line-format (buffer-name buffer)
              buffer-read-only t)
        (font-lock-mode 1)
        (font-lock-add-keywords nil
          '(("^ *\\(\\(?:\\w\\|-\\)+\\):"
             (1 font-lock-keyword-face))))
        (dolist (d md)
          (let ((key (car d))
                (val (cdr d)))
            (cl-case key
              (keywords
               (setq val (mapconcat 'identity val ", "))))
            (let ((beg (+ (length (symbol-name key)) (point) 1))
                  (fill-prefix
                   (make-string (1+ pad) ?\s)))
              (insert (format fmt key val))
              (fill-region beg (point) )))))
      (goto-char 1)
      (display-buffer (current-buffer)))
    md))

(defgroup edoc-misc nil
  "Miscellaneous options for PDF documents."
  :group 'edoc-tools)

(define-obsolete-variable-alias 'edoc-misc-print-programm
  'edoc-misc-print-program-executable "1.0")
(defcustom edoc-misc-print-program-executable nil
  "The program used for printing.

It is called with one argument, the PDF file."
  :group 'edoc-misc
  :type 'file)

(define-obsolete-variable-alias 'edoc-misc-print-programm-args
  'edoc-misc-print-program-args "1.0")
(defcustom edoc-misc-print-program-args nil
  "List of additional arguments passed to `edoc-misc-print-program'."
  :group 'edoc-misc
  :type '(repeat string))

(define-obsolete-function-alias 'edoc-misc-print-programm
  'edoc-misc-print-program "1.0")
(defun edoc-misc-print-program (&optional interactive-p)
  "Return the program used to print PDFs (if the executable is installed).

If INTERACTIVE-P is non-nil, ask the user for which program to
use when printing the PDF. Optionally, save the choice"
  (or (and edoc-misc-print-program-executable
           (executable-find edoc-misc-print-program-executable))
      (when interactive-p
        (let* ((default (car (delq nil (mapcar
                                        'executable-find
                                        '("gtklp" "xpp" "gpr")))))
               buffer-file-name
               (program
                (expand-file-name
                 (read-file-name
                  "Print with: " default nil t nil 'file-executable-p))))
          (when (and program
                     (executable-find program))
            (when (y-or-n-p "Save choice using customize? ")
              (customize-save-variable
               'edoc-misc-print-program-executable program))
            (setq edoc-misc-print-program-executable program))))))

(defun edoc-misc-print-document (filename &optional interactive-p)
  "Print the PDF doc FILENAME.

`edoc-misc-print-program' handles the print program, which see for
definition of INTERACTIVE-P."
  (interactive
   (list (edoc-view-buffer-file-name) t))
  (cl-check-type filename (and string (satisfies file-readable-p)))
  (let ((program (edoc-misc-print-program interactive-p))
        (args (append edoc-misc-print-program-args (list filename))))
    (unless program
      (error "No print program available"))
    (apply #'start-process "printing" nil program args)
    (message "Print job started: %s %s"
             program (mapconcat #'identity args " "))))


(provide 'edoc-misc)

;;; edoc-misc.el ends here
