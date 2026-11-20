;;; edoc-annot.el --- Annotation support for PDF files.  -*- lexical-binding: t -*-

;; Copyright (C) 2013, 2014  Andreas Politz

;; Author: Andreas Politz <politza@fh-trier.de>
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


(require 'edoc-view)
(require 'edoc-info)
(require 'edoc-cache)
(require 'edoc-misc)
(require 'edoc-util)
(require 'facemenu) ;; list-colors-duplicates
(require 'faces) ;; color-values
(require 'org)   ;; org-create-formula-image
(require 'tablist)
(require 'cl-lib)
(require 'seq)


;; * ================================================================== *
;; * Customizations
;; * ================================================================== *

;;; Code:

(defgroup edoc-annot nil
  "Annotation support for PDF documents."
  :group 'edoc-tools)

(defcustom edoc-annot-activate-handler-functions nil
  "A list of functions to activate a annotation.

The functions on this hook will be called when some annotation is
activated, usually by a mouse-click.  Each one is called with the
annotation as a single argument and it should return a non-nil
value if it has `handled' it.  If no such function exists, the
default handler `edoc-annot-default-activate-handler' will be
called.

This hook is meant to allow for custom annotations.  FIXME:
Implement and describe basic org example."
  :type 'hook)

(defcustom edoc-annot-default-text-annotation-properties nil
  "Alist of initial properties for new text annotations."
  :type '(alist :key-type symbol :value-type sexp))

(defcustom edoc-annot-default-markup-annotation-properties nil
  "Alist of initial properties for new markup annotations."
  :type '(alist :key-type symbol :value-type sexp))

(make-obsolete-variable 'edoc-annot-default-text-annotation-properties
                        'edoc-annot-default-annotation-properties
                        "0.90")

(make-obsolete-variable 'edoc-annot-default-markup-annotation-properties
                        'edoc-annot-default-annotation-properties
                        "0.90")

(defcustom edoc-annot-default-annotation-properties
  `((t (label . ,user-full-name))
    (text (icon . "Note")
          (color . "#ff0000"))
    (highlight (color . "yellow"))
    (squiggly (color . "orange"))
    (strike-out(color . "red"))
    (underline (color . "blue")))
  "An alist of initial properties for new annotations.

The alist contains a sub-alist for each of the currently available
annotation types, i.e. text, highlight, squiggly, strike-out and
underline.  Additionally a sub-alist with a key of t acts as a default
entry.

Each of these sub-alists contain default property-values of newly
added annotations of its respective type.

Some of the most important properties and their types are label
\(a string\), contents \(a string\), color \(a color\) and, for
text-annotations only, icon \(one of the standard icon-types, see
`edoc-annot-standard-text-icons'\).

For example a value of

  \(\(t \(color . \"red\"\)
      \(label . \"Joe\"\)
   \(highlight \(color . \"green\"\)\)

would use a green color for highlight and a red one for other
annotations.  Additionally the label for all annotations is set
to \"Joe\"."

  :type (let* ((label '(cons :tag "Label" (const label) string))
               (contents '(cons :tag "Contents" (const contents) string))
               (color '(cons :tag "Color" (const color) color))
               (icon `(cons :tag "Icon"
                            (const icon)
                            (choice
                             ,@(mapcar (lambda (icon)
                                         `(const ,icon))
                                       '("Note" "Comment" "Key" "Help" "NewParagraph"
                                         "Paragraph" "Insert" "Cross" "Circle")))))
               (other '(repeat
                        :tag "Other properties"
                        (cons :tag "Property"
                              (symbol :tag "Key  ")
                              (sexp :tag "Value"))))
               (text-properties
                `(set ,label ,contents ,color ,icon ,other))
               (markup-properties
                `(set ,label ,contents ,color))
               (all-properties
                `(set ,label ,contents ,color ,icon ,other)))
          `(set
            (cons :tag "All Annotations" (const t) ,all-properties)
            (cons :tag "Text Annotations" (const text) ,text-properties)
            (cons :tag "Highlight Annotations" (const highlight) ,markup-properties)
            (cons :tag "Underline Annotations" (const underline) ,markup-properties)
            (cons :tag "Squiggly Annotations" (const squiggly) ,markup-properties)
            (cons :tag "Strike-out Annotations" (const strike-out) ,markup-properties))))

(defcustom edoc-annot-print-annotation-functions
  '(edoc-annot-print-annotation-latex-maybe)
  "A alist of functions for printing annotations, e.g. for the tooltip.

The functions receive the annotation as single argument and
should return either a string or nil.  The first string returned
will be used.

If all of them return nil, the default function
`edoc-annot-print-annotation-default' is used."
  :type 'hook)

(defcustom edoc-annot-latex-string-predicate
  (lambda (str)
    (and str (string-match "\\`[[:space:]\n]*[$\\]" str)))
  "A predicate for recognizing LaTeX fragments.

It receives a string and should return non-nil, if string is a
LaTeX fragment."
  :type 'function)

(defcustom edoc-annot-latex-header
  (concat org-format-latex-header
          "\n\\setlength{\\textwidth}{12cm}")
  "Header used when latex compiling annotations.
The default value is `org-format-latex-header' +
\"\\n\\\\setlength{\\\\textwidth}{12cm}\"."
  :type 'string)

(defcustom edoc-annot-tweak-tooltips t
  "Whether this package should tweak some settings regarding tooltips.

If this variable has a non-nil value,

`x-gtk-use-system-tooltips' is set to nil if appropriate, in
order to display text properties;

`tooltip-hide-delay' is set to infinity, in order to not being
annoyed while reading the annotations."
  :type 'boolean)

(defcustom edoc-annot-activate-created-annotations nil
  "Whether to activate (i.e. edit) created annotations."
  :type 'boolean)

(defcustom edoc-annot-attachment-display-buffer-action nil
  "The display action used when displaying attachments."
  :type display-buffer--action-custom-type)

(defconst edoc-annot-annotation-types
  '(3d caret circle file
       free-text highlight ink line link movie poly-line polygon popup
       printer-mark screen sound square squiggly stamp strike-out text
       trap-net underline unknown watermark widget)
  "Complete list of annotation types.")

(defcustom edoc-annot-list-listed-types
  (if (edoc-info-markup-annotations-p)
      (list 'text 'file 'squiggly 'highlight 'underline 'strike-out)
    (list 'text 'file))
  "A list of annotation types displayed in the list buffer."
  :type `(set ,@(mapcar (lambda (type)
                          (list 'const type))
                        edoc-annot-annotation-types)))


;; * ================================================================== *
;; * Variables and Macros
;; * ================================================================== *

(defvar edoc-annot-color-history nil
  "A list of recently used colors for annotations.")

(defvar-local edoc-annot-modified-functions nil
  "Functions to call, when an annotation was modified.

A function on this hook should accept one argument: A CLOSURE
containing inserted, changed and deleted annotations.

It may access these annotations by calling CLOSURE with one of
these arguments:

`:inserted' The list of recently added annotations.

`:deleted' The list of recently deleted annotations.

`:changed' The list of recently changed annotations.

t The union of recently added, deleted or changed annotations.

nil Just returns nil.

Any other argument signals an error.")

(defconst edoc-annot-text-annotation-size '(24 . 24)
  "The Size of text and file annotations in PDF points.

These values are hard-coded in poppler.  And while the size of
these annotations may be changed, i.e. the edges property, it has
no effect on the rendering.")

(defconst edoc-annot-markup-annotation-types
  '(text link free-text line square
         circle polygon poly-line highlight underline squiggly
         strike-out stamp caret ink file sound)
  "List of defined markup annotation types.")

(defconst edoc-annot-standard-text-icons
  '("Note" "Comment" "Key" "Help" "NewParagraph"
    "Paragraph" "Insert" "Cross" "Circle")
  "A list of standard icon properties for text annotations.")

(defvar edoc-annot-inhibit-modification-hooks nil
  "Controls the behavior of `edoc-annot-modified-functions'.

If non-nil, `edoc-annot-modified-functions' are not run on any
annotation change.")

(defvar-local edoc-annot-delayed-modified-annotations nil
  "A plist of not yet propagated modifications.

It contains three entries :change, :delete and :insert.  Each one
having a list of annotations as value.")

(defvar-local edoc-annot--attachment-file-alist nil
  "Alist mapping attachment ids to unique relative filenames.")

(defmacro edoc-annot-with-atomic-modifications (&rest body)
  "Execute BODY joining multiple modifications.

The effect is, that `edoc-annot-modified-functions' will be called
only once at the end of BODY.

BODY should not modify annotations in a different then the
current buffer, because that won't run the hooks properly."
  (declare (indent 0) (debug t))
  `(unwind-protect
       (save-current-buffer
         (let ((edoc-annot-inhibit-modification-hooks t))
           (progn ,@body)))
     (edoc-annot-run-modified-hooks)))


;; * ================================================================== *
;; * Minor mode
;; * ================================================================== *

(defcustom edoc-annot-minor-mode-map-prefix (kbd "C-c C-a")
  "The prefix to use for `edoc-annot-minor-mode-map'.

Setting this after the package was loaded has no effect."
  :type 'key-sequence)

(defvar edoc-annot-minor-mode-map
  (let ((kmap (make-sparse-keymap))
        (smap (make-sparse-keymap)))
    (define-key kmap edoc-annot-minor-mode-map-prefix smap)
    (define-key smap "l" #'edoc-annot-list-annotations)
    (define-key smap "a" #'edoc-annot-attachment-dired)
    (when (edoc-info-writable-annotations-p)
      (define-key smap "D" #'edoc-annot-delete)
      (define-key smap "t" #'edoc-annot-add-text-annotation)
      (when (edoc-info-markup-annotations-p)
        (define-key smap "m" #'edoc-annot-add-markup-annotation)
        (define-key smap "s" #'edoc-annot-add-squiggly-markup-annotation)
        (define-key smap "u" #'edoc-annot-add-underline-markup-annotation)
        (define-key smap "o" #'edoc-annot-add-strikeout-markup-annotation)
        (define-key smap "h" #'edoc-annot-add-highlight-markup-annotation)))
    kmap)
  "Keymap used for `edoc-annot-minor-mode'.")

(defvar savehist-minibuffer-history-variables)

;;;###autoload
(define-minor-mode edoc-annot-minor-mode
  "Support for PDF Annotations.

\\{edoc-annot-minor-mode-map}"
  :group 'edoc-annot
  (cond
   (edoc-annot-minor-mode
    (when edoc-annot-tweak-tooltips
      (when (boundp 'x-gtk-use-system-tooltips)
        (setq x-gtk-use-system-tooltips nil))
      (setq tooltip-hide-delay 3600))
    (edoc-view-add-hotspot-function 'edoc-annot-hotspot-function 9)
    (add-hook 'edoc-info-close-document-hook
              #'edoc-annot-attachment-delete-base-directory nil t)
    (when (featurep 'savehist)
      (add-to-list 'savehist-minibuffer-history-variables
                   'edoc-annot-color-history)))
   (t
    (edoc-view-remove-hotspot-function 'edoc-annot-hotspot-function)
    (remove-hook 'edoc-info-close-document-hook
                 #'edoc-annot-attachment-delete-base-directory t)))
  (edoc-view-redisplay t))

(defun edoc-annot-create-context-menu (a)
  "Create a appropriate context menu for annotation A."
  (let ((menu (make-sparse-keymap)))
    ;; (when (and (bound-and-true-p edoc-misc-menu-bar-minor-mode)
    ;;            (bound-and-true-p edoc-misc-install-popup-menu))
    ;;   (set-keymap-parent menu
    ;;                      (lookup-key edoc-misc-menu-bar-minor-mode-map
    ;;                                  [menu-bar edoc-tools]))
    ;;   (define-key menu [sep-99] menu-bar-separator))
    (when (edoc-info-writable-annotations-p)
      (define-key menu [delete-annotation]
        `(menu-item "Delete annotation"
                    ,(lambda ()
                       (interactive)
                       (edoc-annot-delete a)
                       (message "Annotation deleted"))
                    :help
                    "Delete this annotation.")))
    (define-key menu [goto-annotation]
      `(menu-item "List annotation"
                  ,(lambda ()
                     (interactive)
                     (edoc-annot-show-annotation a t)
                     (edoc-annot-list-annotations)
                     (edoc-annot-list-goto-annotation a))
                  :help "Find this annotation in the list buffer."))
    (when (edoc-annot-text-annotation-p a)
      (define-key menu [change-text-icon]
        `(menu-item "Change icon"
                    ,(edoc-annot-create-icon-submenu a)
                    :help "Change the appearance of this annotation.")))
    (define-key menu [change-color]
      `(menu-item "Change color"
                  ,(edoc-annot-create-color-submenu a)
                  :help "Change the appearance of this annotation."))
    (define-key menu [activate-annotation]
      `(menu-item "Activate"
                  ,(lambda ()
                     (interactive)
                     (edoc-annot-activate-annotation a))
                  :help "Activate this annotation."))
    menu))

(defun edoc-annot-create-color-submenu (a)
  "Show the user a color menu for their annotation A."
  (let ((menu (make-sparse-keymap)))
    (define-key menu [color-chooser]
                `(menu-item "Choose ..."
                            ,(lambda ()
                               (interactive)
                               (list-colors-display
                                nil "*Choose annotation color*"
                                ;; list-colors-print does not like closures.
                                (let ((callback (make-symbol "xcallback")))
                                  (fset callback
                                        (lambda (color)
                                          (edoc-annot-put a 'color color)
                                          (setq edoc-annot-color-history
                                                (cons color
                                                      (remove color edoc-annot-color-history)))
                                          (quit-window t)))
                                  (list 'function callback))))))
    (dolist (color (butlast (reverse edoc-annot-color-history)
                            (max 0 (- (length edoc-annot-color-history)
                                      12))))
      (define-key menu (vector (intern (format "color-%s" color)))
                  `(menu-item ,color
                              ,(lambda nil
                                 (interactive)
                                 (edoc-annot-put a 'color color)))))
    menu))

(defun edoc-annot-create-icon-submenu (a)
  "Show the user an icon menu for the annotation A."
  (let ((menu (make-sparse-keymap)))
    (dolist (icon (reverse edoc-annot-standard-text-icons))
      (define-key menu (vector (intern (format "icon-%s" icon)))
                  `(menu-item ,icon
                              ,(lambda nil
                                 (interactive)
                                 (edoc-annot-put a 'icon icon)))))
    menu))

;; * ================================================================== *
;; * Annotation Basics
;; * ================================================================== *

(defun edoc-annot-create (alist &optional buffer)
  "Create a annotation from ALIST in BUFFER.

ALIST should be a property list as returned by
`edoc-cache-getannots'.  BUFFER should be the buffer of the
corresponding PDF document. It defaults to the current buffer."

  (cons `(buffer . ,(or buffer (current-buffer)))
        alist))

(defun edoc-annot-getannots (&optional pages types buffer)
  "Return a list of annotations on PAGES of TYPES in BUFFER.

See `edoc-info-normalize-pages' for valid values of PAGES.  TYPES
may be a symbol or list of symbols denoting annotation types.

PAGES defaults to all pages, TYPES to all types and BUFFER to the
current buffer."

  (edoc-util-assert-edoc-buffer buffer)
  (unless buffer
    (setq buffer (current-buffer)))
  (unless (listp types)
    (setq types (list types)))
  (with-current-buffer buffer
    (let (result)
      (dolist (a (edoc-info-getannots pages))
        (when (or (null types)
                  (memq (edoc-annot-get a 'type) types))
          (push (edoc-annot-create a) result)))
      result)))

(defun edoc-annot-getannot (id &optional buffer)
  "Return the annotation object for annotation ID.

Optionally take the BUFFER name of the PDF buffer. When none is
provided, the `current-buffer' is picked up."
  (edoc-annot-create
   (edoc-info-getannot id buffer)
   buffer))

(defun edoc-annot-get (a property &optional default)
  "Get annotation A's value of PROPERTY.

Return DEFAULT, if value is nil."
  (or (cdr (assq property a)) default))

(defun edoc-annot-put (a property value)
  "Set annotation A's PROPERTY to VALUE.

Unless VALUE is `equal' to the current value, sets A's buffer's
modified flag and runs the hook `edoc-annot-modified-functions'.

Signals an error, if PROPERTY is not modifiable.

Returns the modified annotation."

  (declare (indent 2))
  (unless (equal value (edoc-annot-get a property))
    (unless (edoc-annot-property-modifiable-p a property)
      (error "Property `%s' is read-only for this annotation"
             property))
    (with-current-buffer (edoc-annot-get-buffer a)
      (setq a (edoc-annot-create
               (edoc-info-editannot
                (edoc-annot-get-id a)
                `((,property . ,value)))))
      (set-buffer-modified-p t)
      (edoc-annot-run-modified-hooks :change a)))
  a)

(defun edoc-annot-run-modified-hooks (&optional operation &rest annotations)
  "Run `edoc-annot-modified-functions' using OPERATION on ANNOTATIONS.

OPERATION should be one of nil, :change, :insert or :delete.  If
nil, annotations should be empty.

Redisplay modified pages.

If `edoc-annot-inhibit-modification-hooks' in non-nil, this just
saves ANNOTATIONS and does not call the hooks until later, when
the variable is nil and this function is called again."

  (unless (memq operation '(nil :insert :change :delete))
    (error "Invalid operation: %s" operation))
  (when (and (null operation) annotations)
    (error "Missing operation argument"))

  (when operation
    (let ((list (plist-get edoc-annot-delayed-modified-annotations operation)))
      (dolist (a annotations)
        (cl-pushnew a list :test 'edoc-annot-equal))
      (setq edoc-annot-delayed-modified-annotations
            (plist-put edoc-annot-delayed-modified-annotations
                       operation list))))
  (unless edoc-annot-inhibit-modification-hooks
    (let* ((changed (plist-get edoc-annot-delayed-modified-annotations :change))
           (inserted (mapcar (lambda (a)
                               (or (car (cl-member a changed :test 'edoc-annot-equal))
                                   a))
                             (plist-get edoc-annot-delayed-modified-annotations :insert)))
           (deleted (plist-get edoc-annot-delayed-modified-annotations :delete))
           (union (cl-union (cl-union changed inserted :test 'edoc-annot-equal)
                            deleted :test 'edoc-annot-equal))
           (closure (lambda (arg)
                      (when arg
                        (cl-case arg
                          (:inserted (copy-sequence inserted))
                          (:changed (copy-sequence changed))
                          (:deleted (copy-sequence deleted))
                          (t (copy-sequence union))))))
           (pages (mapcar (lambda (a) (edoc-annot-get a 'page)) union)))
      (when union
        (unwind-protect
            (run-hook-with-args
             'edoc-annot-modified-functions closure)
          (setq edoc-annot-delayed-modified-annotations nil)
          (apply #'edoc-view-redisplay-pages pages))))))

(defun edoc-annot-equal (a1 a2)
  "Return non-nil, if annotations A1 and A2 are equal.

Two annotations are equal, if they belong to the same buffer and
have identical id properties."
  (and (eq (edoc-annot-get-buffer a1)
           (edoc-annot-get-buffer a2))
       (eq (edoc-annot-get-id a1)
           (edoc-annot-get-id a2))))

(defun edoc-annot-get-buffer (a)
  "Return annotation A's buffer."
  (edoc-annot-get a 'buffer))

(defun edoc-annot-get-id (a)
  "Return id property of annotation A."
  (edoc-annot-get a 'id))

(defun edoc-annot-get-type (a)
  "Return type property of annotation A."
  (edoc-annot-get a 'type))

(defun edoc-annot-get-display-edges (a)
  "Return a list of EDGES used for display for annotation A.

This returns a list of \(LEFT TOP RIGHT BOT\) demarking the
rectangles of the page where A is rendered."

  (or (edoc-annot-get a 'markup-edges)
      (list (edoc-annot-get a 'edges))))

(defun edoc-annot-delete (a)
  "Delete annotation A.

Sets A's buffer's modified flag and runs the hook
`edoc-annot-modified-functions'.

This function always returns nil."
  (interactive
   (list (edoc-annot-read-annotation
          "Click on the annotation you wish to delete")))
  (with-current-buffer (edoc-annot-get-buffer a)
    (edoc-info-delannot
     (edoc-annot-get-id a))
    (set-buffer-modified-p t)
    (edoc-annot-run-modified-hooks :delete a))
  (when (called-interactively-p 'any)
    (message "Annotation deleted"))
  nil)

(defun edoc-annot-text-annotation-p (a)
  "Return non-nil if annotation A is of type text."
  (eq 'text (edoc-annot-get a 'type)))

(defun edoc-annot-markup-annotation-p (a)
  "Return non-nil if annotation A is a known markup type.

Annotation types are defined in `edoc-annot-markup-annotation-types'."
  (not (null
        (memq (edoc-annot-get a 'type)
              edoc-annot-markup-annotation-types))))

(defun edoc-annot-property-modifiable-p (a property)
  "Return non-nil if PROPERTY for annotation A is editable."
  (or (memq property '(edges color flags contents))
      (and (edoc-annot-markup-annotation-p a)
           (memq property '(label opacity popup popup-is-open)))
      (and (edoc-annot-text-annotation-p a)
           (memq property '(icon is-open)))))

(defun edoc-annot-activate-annotation (a)
  "Run handler functions on A to activate the annotation.

Activation functions are defined in `edoc-annot-activate-handler-functions'."
  (or (run-hook-with-args-until-success
       'edoc-annot-activate-handler-functions
       a)
      (edoc-annot-default-activate-handler a)))

(defun edoc-annot-default-activate-handler (a)
  "The default activation function to run on annotation A.

Activation functions are defined in `edoc-annot-activate-handler-functions'."
  (cond
   ((edoc-annot-has-attachment-p a)
    (edoc-annot-pop-to-attachment a))
   (t (edoc-annot-edit-contents a))))


;; * ================================================================== *
;; * Handling attachments
;; * ================================================================== *

(defun edoc-annot-has-attachment-p (a)
  "Return non-nil if annotation A's has data attached."
  (eq 'file (edoc-annot-get a 'type)))

(defun edoc-annot-get-attachment (a &optional do-save)
  "Retrieve annotation A's attachment.

The DO-SAVE argument is given to
`edoc-info-getattachment-from-annot', which see."
  (unless (edoc-annot-has-attachment-p a)
    (error "Annotation has no data attached: %s" a))
  (edoc-info-getattachment-from-annot
   (edoc-annot-get-id a)
   do-save
   (edoc-annot-get-buffer a)))

(defun edoc-annot-attachment-base-directory ()
  "Return the base directory for saving attachments."
  (let ((dir (edoc-util-expand-file-name "attachments")))
    (unless (file-exists-p dir)
      (make-directory dir))
    dir))

(defun edoc-annot-attachment-delete-base-directory ()
  "Delete all saved attachment files of the current buffer."
  (setq edoc-annot--attachment-file-alist nil)
  (delete-directory (edoc-annot-attachment-base-directory) t))

(defun edoc-annot-attachment-unique-filename (attachment)
  "Return a unique absolute filename for ATTACHMENT."
  (let* ((filename (or (cdr (assq 'filename attachment))
                       "attachment"))
         (id (cdr (assq 'id attachment)))
         (unique
          (or (cdr (assoc id edoc-annot--attachment-file-alist))
              (let* ((sans-ext
                      (expand-file-name
                       (concat (file-name-as-directory ".")
                               (file-name-sans-extension filename))
                       (edoc-annot-attachment-base-directory)))
                     (ext (file-name-extension filename))
                     (newname (concat sans-ext "." ext))
                     (i 0))
                (while (rassoc newname edoc-annot--attachment-file-alist)
                  (setq newname (format "%s-%d.%s" sans-ext (cl-incf i) ext)))
                (push (cons id newname) edoc-annot--attachment-file-alist)
                newname)))
         (directory (file-name-directory unique)))
    (unless (file-exists-p directory)
      (make-directory directory t))
    unique))


(defun edoc-annot-attachment-save (attachment &optional regenerate-p)
  "Save ATTACHMENT's data to a unique filename and return its name.

If REGENERATE-P is non-nil, copy attachment's file even if the
copy already exists.

Signal an error, if ATTACHMENT has no, or a non-existing, `file'
property, i.e. it was retrieved with an unset do-save argument.
See `edoc-info-getattachments'"

  (let ((datafile (cdr (assq 'file attachment))))
    (unless (and datafile
                 (file-exists-p datafile))
      (error "Attachment's file property is invalid"))
    (let* ((filename
            (edoc-annot-attachment-unique-filename attachment)))
      (when (or regenerate-p
                (not (file-exists-p filename)))
        (copy-file datafile filename nil nil t t))
      filename)))

(defun edoc-annot-find-attachment-noselect (a)
  "Find annotation A's attachment in a buffer, without selecting it.

Signals an error, if A has no data attached."
  (let ((attachment (edoc-annot-get-attachment a t)))
    (unwind-protect
        (find-file-noselect
         (edoc-annot-attachment-save attachment))
      (let ((tmpfile (cdr (assq 'file attachment))))
        (when (and tmpfile
                   (file-exists-p tmpfile))
          (delete-file tmpfile))))))

(defun edoc-annot-attachment-dired (&optional regenerate-p)
  "List all attachments in a Dired buffer.

If REGENERATE-P is non-nil, create attachment's files even if
they already exist.  Interactively REGENERATE-P is non-nil if a
prefix argument was given.

Return the Dired buffer."
  (interactive (list current-prefix-arg))
  (let ((attachments (edoc-info-getattachments t)))
    (unwind-protect
        (progn
          (dolist (a (edoc-annot-getannots nil 'file))
            (push (edoc-annot-get-attachment a t)
                  attachments ))
          (dolist (att attachments)
            (edoc-annot-attachment-save att regenerate-p))
          (unless attachments
            (error "Document has no data attached"))
          (dired (edoc-annot-attachment-base-directory)))
      (dolist (att attachments)
        (let ((tmpfile (cdr (assq 'file att))))
          (when (and tmpfile (file-exists-p tmpfile))
            (delete-file tmpfile)))))))

(defun edoc-annot-display-attachment (a &optional display-action select-window-p)
  "Display file annotation A's data in a buffer.

DISPLAY-ACTION should be a valid `display-buffer' action.  If
nil, `edoc-annot-attachment-display-buffer-action' is used.

Select the window, if SELECT-WINDOW-P is non-nil.

Return the window attachment is displayed in."

  (interactive
   (list (edoc-annot-read-annotation
          "Select a file annotation by clicking on it")))
  (let* ((buffer (edoc-annot-find-attachment-noselect a))
         (window (display-buffer
                  buffer (or display-action
                             edoc-annot-attachment-display-buffer-action))))
    (when select-window-p
      (select-window window))
    window))

(defun edoc-annot-pop-to-attachment (a)
  "Display annotation A's attachment in a window and select it."
  (interactive
   (list (edoc-annot-read-annotation
          "Select a file annotation by clicking on it")))
  (edoc-annot-display-attachment a nil t))


;; * ================================================================== *
;; * Interfacing with the display
;; * ================================================================== *

(defun edoc-annot-image-position (a &optional image-size)
  "Return the position of annotation A in image coordinates.

IMAGE-SIZE should be a cons \(WIDTH . HEIGHT\) and defaults to
the page-image of the selected window."

  (unless image-size
    (edoc-util-assert-edoc-window)
    (setq image-size (edoc-view-image-size)))
  (let ((e (edoc-util-scale
            (edoc-annot-get a 'edges)
            image-size)))
    (edoc-util-with-edges (e)
      `(,e-left . ,e-top))))

(defun edoc-annot-image-set-position (a x y &optional image-size)
  "Set annotation A's position to X,Y in image coordinates.

See `edoc-annot-image-position' for IMAGE-SIZE."

  (unless image-size
    (edoc-util-assert-edoc-window)
    (setq image-size (edoc-view-image-size)))
  (let* ((edges (edoc-annot-get a 'edges))
         (x (/ x (float (car image-size))))
         (y (/ y (float (cdr image-size)))))
    (edoc-util-with-edges (edges)
      (let* ((w edges-width)
             (h edges-height)
             (x (max 0 (min x (- 1 w))))
             (y (max 0 (min y (- 1 h)))))
        (edoc-annot-put a 'edges
          (list x y -1 -1))))))

(defun edoc-annot-image-size (a &optional image-size)
  "Return the size of annotation A in image coordinates.

Returns \(WIDTH . HEIGHT\).

See `edoc-annot-image-position' for IMAGE-SIZE."
  (unless image-size
    (edoc-util-assert-edoc-window)
    (setq image-size (edoc-view-image-size)))
  (let ((edges (edoc-util-scale
                (edoc-annot-get a 'edges) image-size)))
    (edoc-util-with-edges (edges)
      (cons edges-width edges-height))))

(defun edoc-annot-image-set-size (a &optional width height image-size)
  "Set annotation A's size in image to WIDTH and/or HEIGHT.

See `edoc-annot-image-position' for IMAGE-SIZE."
  (unless image-size
    (edoc-util-assert-edoc-window)
    (setq image-size (edoc-view-image-size)))
  (let* ((edges (edoc-annot-get a 'edges))
         (w (and width
                 (/ width (float (car image-size)))))
         (h (and height
                 (/ height (float (cdr image-size))))))
    (edoc-util-with-edges (edges)
      (edoc-annot-put a 'edges
        (list edges-left
              edges-top
              (if w (+ edges-left w) edges-right)
              (if h (+ edges-top h) edges-bot))))))

(defun edoc-annot-at-position (pos)
  "Return annotation at POS in the selected window.

POS should be an absolute image position as a cons \(X . Y\).
Alternatively POS may also be an event position, in which case
`posn-window' and `posn-object-x-y' is used to find the image
position.

Return nil, if no annotation was found."
  (let (window)
    (when (posnp pos)
      (setq window (posn-window pos)
            pos (posn-object-x-y pos)))
    (save-selected-window
      (when window (select-window window 'norecord))
      (let* ((annots (edoc-annot-getannots (edoc-view-current-page)))
             (size (edoc-view-image-size))
             (rx (/ (car pos) (float (car size))))
             (ry (/ (cdr pos) (float (cdr size))))
             (rpos (cons rx ry)))
        (or (cl-some (lambda (a)
                       (and (cl-some
                             (lambda (e)
                               (edoc-util-edges-inside-p e rpos))
                             (edoc-annot-get-display-edges a))
                            a))
                     annots)
            (error "No annotation at this position"))))))

(defun edoc-annot-mouse-move (event &optional annot)
  "Start moving an annotation at EVENT's position.

EVENT should be a mouse event originating the request and is used
as a reference point.

ANNOT is the annotation to operate on and defaults to the
annotation at EVENT's start position.

This function does not return until the operation is completed,
i.e. a non mouse-movement event is read."

  (interactive "@e")
  (edoc-util-assert-edoc-window (posn-window (event-start event)))
  (select-window (posn-window (event-start event)))
  (let* ((mpos (posn-object-x-y (event-start event)))
         (a (or annot
                (edoc-annot-at-position mpos))))
    (unless a
      (error "No annotation at this position: %s" mpos))
    (let* ((apos (edoc-annot-image-position a))
           (offset (cons (- (car mpos) (car apos))
                         (- (cdr mpos) (cdr apos))))
           (window (selected-window))
           make-pointer-invisible)
      (when (edoc-util-track-mouse-dragging (ev 0.1)
              (when (and (eq window (posn-window (event-start ev)))
                         (eq 'image (car-safe (posn-object (event-start ev)))))
                (let ((edoc-view-inhibit-hotspots t)
                      (edoc-annot-inhibit-modification-hooks t)
                      (edoc-cache-image-inihibit t)
                      (xy (posn-object-x-y (event-start ev))))
                  (edoc-annot-image-set-position
                   a (- (car xy) (car offset))
                   (- (cdr xy) (cdr offset)))
                  (edoc-view-redisplay))))
        (edoc-annot-run-modified-hooks)))
    nil))

(defun edoc-annot-hotspot-function (page size)
  "Create image hotspots for page PAGE of size SIZE."
  (apply #'nconc (mapcar (lambda (a)
                           (unless (eq (edoc-annot-get a 'type)
                                       'link)
                             (edoc-annot-create-hotspots a size)))
                         (edoc-annot-getannots page))))

(defun edoc-annot-create-hotspots (a size)
  "Return a list of image hotspots for annotation A.

SIZE is a cons (SX . SY), by which edges are scaled."
  (let ((id (edoc-annot-get-id a))
        (edges (edoc-util-scale
                (edoc-annot-get-display-edges a)
                size 'round))
        (moveable-p (memq (edoc-annot-get a 'type)
                          '(file text)))
        hotspots)
    (dolist (e edges)
      (edoc-util-with-edges (e)
        (push `((rect . ((,e-left . ,e-top) . (,e-right . ,e-bot)))
                ,id
                (pointer
                 hand
                 help-echo
                 ,(edoc-annot-print-annotation a)))
              hotspots)))
    (edoc-annot-create-hotspot-binding id moveable-p a)
    hotspots))

;; FIXME: Define a keymap as a template for this. Much cleaner.
(defun edoc-annot-create-hotspot-binding (id moveable-p annotation)
  "Create a local keymap for interacting with ANNOTATION using the mouse.

ID is the identifier for the ANNOTATION, as returned
`edoc-annot-get-id'. MOVEABLE-P indicates whether the annotation
is moveable."
  ;; Activating
  (local-set-key
   (vector id 'mouse-1)
   (lambda ()
     (interactive)
     (edoc-annot-activate-annotation annotation)))
  ;; Move
  (when moveable-p
    (local-set-key
     (vector id 'down-mouse-1)
     (lambda (ev)
       (interactive "@e")
       (edoc-annot-mouse-move ev annotation))))
  ;; Context Menu
  (local-set-key
   (vector id 'down-mouse-3)
   (lambda ()
     (interactive "@")
     (popup-menu (edoc-annot-create-context-menu annotation))))
  ;; Everything else
  (local-set-key
   (vector id t)
   'edoc-util-image-map-mouse-event-proxy))

(defun edoc-annot-show-annotation (a &optional highlight-p window)
  "Make annotation A visible.

Turn to A's page in WINDOW, and scroll it if necessary.

If HIGHLIGHT-P is non-nil, visually distinguish annotation A from
other annotations."

  (save-selected-window
    (when window (select-window window 'norecord))
    (edoc-util-assert-edoc-window)
    (let ((page (edoc-annot-get a 'page))
          (size (edoc-view-image-size)))
      (unless (= page (edoc-view-current-page))
        (edoc-view-goto-page page))
      (let ((edges (edoc-annot-get-display-edges a)))
        (when highlight-p
          (edoc-view-display-image
           (edoc-view-create-image
               (edoc-cache-renderpage-highlight
                page (car size)
                `("white" "steel blue" 0.35 ,@edges))
             :map (edoc-view-apply-hotspot-functions
                   window page size)
             :width (car size))))
        (edoc-util-scroll-to-edges
         (edoc-util-scale-relative-to-pixel (car edges)))))))

(defun edoc-annot-read-annotation (&optional prompt)
  "Let the user choose a annotation a mouse click using PROMPT."
  (edoc-annot-at-position
   (edoc-util-read-image-position
    (or prompt "Choose a annotation by clicking on it"))))


;; * ================================================================== *
;; * Creating annotations
;; * ================================================================== *

(defun edoc-annot-add-annotation (type edges &optional property-alist page)
  "Create and add a new annotation of type TYPE to the document.

TYPE determines the kind of annotation to add and maybe one of
`text', `squiggly', `underline', `strike-out' or `highlight'.

EDGES determines where the annotation will appear on the page.
If type is `text', this should be a single list of \(LEFT TOP
RIGHT BOT\).  Though, in this case only LEFT and TOP are used,
since the size of text annotations is fixed. Otherwise EDGES may
be a list of such elements.  All values should be image relative
coordinates, i.e. in the range \[0;1\].

PROPERTY-ALIST is a list of annotation properties, which will be
put on the created annotation.

PAGE determines the page of the annotation. It defaults to the
page currently displayed in the selected window.

Signal an error, if PROPERTY-ALIST contains non-modifiable
properties or PAGE is nil and the selected window does not
display a PDF document or creating annotations of type TYPE is
not supported.

Set buffers modified flag and calls
`edoc-annot-activate-annotation' if
`edoc-annot-activate-created-annotations' is non-nil.

Return the new annotation."

  (unless (memq type (edoc-info-creatable-annotation-types))
    (error "Unsupported annotation type: %s" type))
  (unless page
    (edoc-util-assert-edoc-window)
    (setq page (edoc-view-current-page)))
  (unless (consp (car-safe edges))
    (setq edges (list edges)))
  (when (and (eq type 'text)
             (> (length edges) 1))
    (error "Edges argument should be a single edge-list for text annotations"))
  (let* ((selection-style edoc-view-selection-style)
         (non-markup (pcase type
                       ('text t)
                       ('highlight edoc-view--have-rectangle-region)))
         (a (apply #'edoc-info-addannot
                   page
                   (if non-markup
                       (car edges)
                     (apply #'edoc-util-edges-union
                            (apply #'append
                                   (mapcar
                                    (lambda (e)
                                      (edoc-info-getselection page e selection-style))
                                    edges))))
                   type
                   selection-style
                   nil
                   (unless non-markup edges)))
         (id (edoc-annot-get-id a)))
    (when property-alist
      (condition-case err
          (setq a (edoc-info-editannot id property-alist))
        (error
         (edoc-info-delannot id)
         (signal (car err) (cdr err)))))
    (setq a (edoc-annot-create a))
    (set-buffer-modified-p t)
    (edoc-annot-run-modified-hooks :insert a)
    (when edoc-annot-activate-created-annotations
      (edoc-annot-activate-annotation a))
    a))

(defun edoc-annot-add-text-annotation (pos &optional icon property-alist)
  "Add a new text annotation at POS in the selected window.

POS should be a image position object or a cons \(X . Y\), both
being image coordinates.

ICON determines how the annotation is displayed and should be
listed in `edoc-annot-standard-text-icons'.  Any other value is ok
as well, but will render the annotation invisible.

Adjust X and Y accordingly, if the position would render the
annotation off-page.

Merge ICON as a icon property with PROPERTY-ALIST and
`edoc-annot-default-annotation-properties' and apply the
result to the created annotation.

See also `edoc-annot-add-annotation'.

Return the new annotation."

  (interactive
   (let* ((posn (edoc-util-read-image-position
                 "Click where a new text annotation should be added ..."))
          (window (posn-window posn)))
     (select-window window)
     (list posn)))
  (edoc-util-assert-edoc-window)
  (when (posnp pos)
    (setq pos (posn-object-x-y pos)))
  (let ((isize (edoc-view-image-size))
        (x (car pos))
        (y (cdr pos)))
    (unless (and (>= x 0)
                 (< x (car isize)))
      (signal 'args-out-of-range (list pos)))
    (unless (and (>= y 0)
                 (< y (cdr isize)))
      (signal 'args-out-of-range (list pos)))
    (let ((size (edoc-util-scale-points-to-pixel
                 edoc-annot-text-annotation-size 'round)))
      (setcar size (min (car size) (car isize)))
      (setcdr size (min (cdr size) (cdr isize)))
      (cl-decf x (max 0 (- (+ x (car size)) (car isize))))
      (cl-decf y (max 0 (- (+ y (cdr size)) (cdr isize))))
      (edoc-annot-add-annotation
       'text (edoc-util-scale-pixel-to-relative
              (list x y -1 -1))
       (edoc-annot-merge-alists
        (and icon `((icon . ,icon)))
        property-alist
        (cdr (assq 'text edoc-annot-default-annotation-properties))
        (cdr (assq t edoc-annot-default-annotation-properties))
        `((color . ,(car edoc-annot-color-history))))))))

(defun edoc-annot-mouse-add-text-annotation (ev)
  "Add a text annotation using the mouse.

EV describes the captured mouse event."
  (interactive "@e")
  (edoc-annot-add-text-annotation
   (if (eq (car-safe ev)
           'menu-bar)
       (let (echo-keystrokes)
         (message nil)
         (edoc-util-read-image-position
          "Click where a new text annotation should be added ..."))
     (event-start ev))))

(defun edoc-annot-add-markup-annotation (list-of-edges type &optional color
                                                      property-alist)
  "Add a new markup annotation in the selected window.

LIST-OF-EDGES determines the marked up area and should be a list
of \(LEFT TOP RIGHT BOT\), each value a relative coordinate.

TYPE should be one of `squiggly', `underline', `strike-out' or
`highlight'.

Merge COLOR as a color property with PROPERTY-ALIST and
`edoc-annot-default-annotation-properties' and apply the
result to the created annotation.

See also `edoc-annot-add-annotation'.

Return the new annotation."
  (interactive
   (list (edoc-view-active-region t)
         (let ((type (completing-read "Markup type (default highlight): "
                                      '("squiggly" "highlight" "underline" "strike-out")
                                      nil t)))
           (if (equal type "") 'highlight (intern type)))
         (edoc-annot-read-color)))
  (edoc-util-assert-edoc-window)
  (edoc-annot-add-annotation
   type
   list-of-edges
   (edoc-annot-merge-alists
    (and color `((color . ,color)))
    property-alist
    (cdr (assq type edoc-annot-default-annotation-properties))
    (cdr (assq t edoc-annot-default-annotation-properties))
    (when edoc-annot-color-history
      `((color . ,(car edoc-annot-color-history))))
    '((color . "#ffff00")))
   (edoc-view-current-page)))

(defun edoc-annot-add-squiggly-markup-annotation (list-of-edges
                                                 &optional color property-alist)
  "Add a new squiggly annotation in the selected window.

LIST-OF-EDGES defines the annotation boundary. COLOR defines the
annotation color and PROPERTY-ALIST defines additional annotation
properties. See also `edoc-annot-add-markup-annotation'."
  (interactive (list (edoc-view-active-region t)))
  (edoc-annot-add-markup-annotation list-of-edges 'squiggly color property-alist))

(defun edoc-annot-add-underline-markup-annotation (list-of-edges
                                                  &optional color property-alist)
  "Add a new underline annotation in the selected window.

LIST-OF-EDGES defines the annotation boundary. COLOR defines the
annotation color and PROPERTY-ALIST defines additional annotation
properties. See also `edoc-annot-add-markup-annotation'."
  (interactive (list (edoc-view-active-region t)))
  (edoc-annot-add-markup-annotation list-of-edges 'underline color property-alist))

(defun edoc-annot-add-strikeout-markup-annotation (list-of-edges
                                                  &optional color property-alist)
  "Add a new strike-out annotation in the selected window.

LIST-OF-EDGES defines the annotation boundary. COLOR defines the
annotation color and PROPERTY-ALIST defines additional annotation
properties. See also `edoc-annot-add-markup-annotation'."
  (interactive (list (edoc-view-active-region t)))
  (edoc-annot-add-markup-annotation list-of-edges 'strike-out color property-alist))

(defun edoc-annot-add-highlight-markup-annotation (list-of-edges
                                                  &optional color property-alist)
  "Add a new highlight annotation in the selected window.

LIST-OF-EDGES defines the annotation boundary. COLOR defines the
annotation color and PROPERTY-ALIST defines additional annotation
properties. See also `edoc-annot-add-markup-annotation'."
  (interactive (list (edoc-view-active-region t)))
  (edoc-annot-add-markup-annotation list-of-edges 'highlight color property-alist))

(defun edoc-annot-read-color (&optional prompt)
  "Read and return a color using PROMPT.

Offer `edoc-annot-color-history' as default values."
  (let* ((defaults (append
                    (seq-map #'cdr
                             (seq-filter (lambda (x) (eq 'color (car x)))
                                         (seq-mapcat #'cdr
                                                     edoc-annot-default-annotation-properties)))
                    edoc-annot-color-history))
         (prompt
          (format "%s%s: "
                  (or prompt "Color")
                  (if defaults (format " (default %s)" (car defaults)) "")))
         (current-completing-read-function completing-read-function)
         (completing-read-function
          (lambda (prompt collection &optional predicate require-match
                          initial-input _hist _def inherit-input-method)
            (funcall current-completing-read-function
                     prompt collection predicate require-match
                     initial-input 'edoc-annot-color-history
                     defaults
                     inherit-input-method))))
    (read-color prompt)))

(defun edoc-annot-merge-alists (&rest alists)
  "Merge ALISTS into a single one.

Suppresses successive duplicate entries of keys after the first
occurrence in ALISTS."

  (let (merged)
    (dolist (elt (apply #'append alists))
      (unless (assq (car elt) merged)
        (push elt merged)))
    (nreverse merged)))



;; * ================================================================== *
;; * Displaying annotation contents
;; * ================================================================== *

(defun edoc-annot-print-property (a property)
  "Pretty print annotation A's property PROPERTY."
  (let ((value (edoc-annot-get a property)))
    (cl-case property
      (color
       (propertize (or value "")
                   'face (and value
                              `(:background ,value))))
      ((created modified)
       (let ((date value))
         (if (null date)
             "No date"
           (current-time-string date))))
      ;; print verbatim
      (subject
       (or value "No subject"))
      (opacity
       (let ((opacity (or value 1.0)))
         (format "%d%%" (round (* 100 opacity)))))
      (t (format "%s" (or value ""))))))

(defun edoc-annot-print-annotation (a)
  "Pretty print annotation A."
  (or (run-hook-with-args-until-success
       'edoc-annot-print-annotation-functions a)
      (edoc-annot-print-annotation-default a)))

(defun edoc-annot-print-annotation-default (a)
  "Default pretty printer for annotation A.

The result consists of a header (as printed with
`edoc-annot-print-annotation-header') a newline and A's contents
property."
  (concat
   (edoc-annot-print-annotation-header a)
   "\n"
   (edoc-annot-get a 'contents)))

(defun edoc-annot-print-annotation-header (a)
  "Emit a suitable header string for annotation A."
  (let ((header
         (cond
          ((eq 'file (edoc-annot-get a 'type))
           (let ((att (edoc-annot-get-attachment a)))
             (format "File attachment `%s' of %s"
                     (or (cdr (assq 'filename att)) "unnamed")
                     (if (cdr (assq 'size att))
                         (format "size %s" (file-size-human-readable
                                            (cdr (assq 'size att))))
                       "unknown size"))))
          (t
           (format "%s"
                   (mapconcat
                    #'identity
                    (mapcar
                     (lambda (property)
                       (edoc-annot-print-property
                        a property))
                     `(subject
                       label
                       modified))
                    ";"))))))
    (setq header (propertize header 'face 'header-line
                             'intangible t 'read-only t))
    ;; This `trick' makes the face apply in a tooltip.
    (propertize header 'display header)))

(defun edoc-annot-print-annotation-latex-maybe (a)
  "Maybe print annotation A's content as a LaTeX fragment.

See `edoc-annot-latex-string-predicate'."
  (when (and (functionp edoc-annot-latex-string-predicate)
             (funcall edoc-annot-latex-string-predicate
                      (edoc-annot-get a 'contents)))
    (edoc-annot-print-annotation-latex a)))

(defun edoc-annot-print-annotation-latex (a)
  "Print annotation A's content as a LaTeX fragment.

This compiles A's contents as a LaTeX fragment and puts the
resulting image as a display property on the contents, prefixed
by a header."

  (let (tempfile)
    (unwind-protect
        (with-current-buffer (edoc-annot-get-buffer a)
          (let* ((page (edoc-annot-get a 'page))
                 (header (edoc-annot-print-annotation-header a))
                 (contents (edoc-annot-get a 'contents))
                 (hash (sxhash (format
                                "edoc-annot-print-annotation-latex%s%s%s"
                                page header contents)))
                 (data (edoc-cache-lookup-image page 0 nil hash))
                 ;; edoc-tools can only work with png files, so this
                 ;; binding ensures that edoc-tools can print the
                 ;; latex-preview regardless of the user
                 ;; configuration.
                 (org-preview-latex-default-process 'dvipng)
                 (org-format-latex-header edoc-annot-latex-header)
                 (temporary-file-directory
                  (edoc-util-expand-file-name "edoc-annot-print-annotation-latex")))
            (unless (file-directory-p temporary-file-directory)
              (make-directory temporary-file-directory))
            (unless data
              (setq tempfile (make-temp-file "edoc-annot" nil ".png"))
              ;; FIXME: Why is this with-temp-buffer needed (which it is) ?
              (with-temp-buffer
                (org-create-formula-image
                 contents tempfile org-format-latex-options t))
              (setq data (edoc-util-munch-file tempfile))
              (if (and (> (length data) 3)
                       (equal (substring data 1 4)
                              "PNG"))
                  (edoc-cache-put-image page 0 data hash)
                (setq data nil)))
            (concat
             header
             "\n"
             (if data
                 (propertize
                  contents 'display (edoc-view-create-image data))
               (propertize
                contents
                'display
                (concat
                 (propertize "Failed to compile latex fragment\n"
                             'face 'error)
                 contents))))))
      (when (and tempfile
                 (file-exists-p tempfile))
        (delete-file tempfile)))))


;; * ================================================================== *
;; * Editing annotation contents
;; * ================================================================== *

(defvar-local edoc-annot-edit-contents--annotation nil)
(put 'edoc-annot-edit-contents--annotation 'permanent-local t)
(defvar-local edoc-annot-edit-contents--buffer nil)

(defcustom edoc-annot-edit-contents-setup-function
  (lambda (a)
    (let ((mode (if (funcall edoc-annot-latex-string-predicate
                             (edoc-annot-get a 'contents))
                    'latex-mode
                  'org-mode)))
      (unless (derived-mode-p mode)
        (funcall mode))))
  "A function for setting up, e.g. the major-mode, of the edit buffer.

The function receives one argument, the annotation whose contents
is about to be edited in this buffer.

The default value turns on `latex-mode' if
`edoc-annot-latex-string-predicate' returns non-nil on the
annotation's contents and otherwise `org-mode'."
  :type 'function)

(defcustom edoc-annot-edit-contents-display-buffer-action
  '((display-buffer-reuse-window
     display-buffer-split-below-and-attach)
    (inhibit-same-window . t)
    (window-height . 0.25))
  "Display action when showing the edit buffer."
  :type display-buffer--action-custom-type)

(defvar edoc-annot-edit-contents-minor-mode-map
  (let ((kmap (make-sparse-keymap)))
    (set-keymap-parent kmap text-mode-map)
    (define-key kmap (kbd "C-c C-c") #'edoc-annot-edit-contents-commit)
    (define-key kmap (kbd "C-c C-q") #'edoc-annot-edit-contents-abort)
    (define-key kmap (kbd "C-c C-k") #'edoc-annot-edit-contents-abort)
    kmap))

(define-minor-mode edoc-annot-edit-contents-minor-mode
  "Active when editing the contents of annotations."
  :group 'edoc-annot
  (when edoc-annot-edit-contents-minor-mode
    (setq-local header-line-format
                (substitute-command-keys "\
Press \\[edoc-annot-edit-contents-commit] to commit your changes, \\[edoc-annot-edit-contents-abort] to abandon them."))))

(put 'edoc-annot-edit-contents-minor-mode 'permanent-local t)

(defun edoc-annot-edit-contents-finalize (do-save &optional do-kill)
  "Finalize edit-operations on an Annotation.

If DO-SAVE is t, save the changes to annotation content without
asking. If DO-SAVE is `ask', check with the user if contents
should be saved.

If DO-KILL is t, kill all windows displaying the annotation
contents. Else just bury the buffers."
  (when (buffer-modified-p)
    (cond
     ((eq do-save 'ask)
      (save-window-excursion
        (display-buffer (current-buffer) nil (selected-frame))
        (when (y-or-n-p "Save changes to this annotation ?")
          (edoc-annot-edit-contents-save-annotation))))
     (do-save
      (edoc-annot-edit-contents-save-annotation)))
    (set-buffer-modified-p nil))
  (dolist (win (get-buffer-window-list))
    (quit-window do-kill win)))

(defun edoc-annot-edit-contents-save-annotation ()
  "Internal function to save the contents of the annotation under editing."
  (when edoc-annot-edit-contents--annotation
    (edoc-annot-put edoc-annot-edit-contents--annotation
        'contents
      (buffer-substring-no-properties (point-min) (point-max)))
    (set-buffer-modified-p nil)))

(defun edoc-annot-edit-contents-commit ()
  "Save the change made to the current annotation."
  (interactive)
  (edoc-annot-edit-contents-finalize t))

(defun edoc-annot-edit-contents-abort ()
  "Abort the change made to the current annotation."
  (interactive)
  (edoc-annot-edit-contents-finalize nil t))

(defun edoc-annot-edit-contents-noselect (a)
  "Internal function to setup all prerequisites for editing annotation A.

At any given point of time, only one annotation can be in edit mode."
  (with-current-buffer (edoc-annot-get-buffer a)
    (when (and (buffer-live-p edoc-annot-edit-contents--buffer)
               (not (eq a edoc-annot-edit-contents--annotation)))
      (with-current-buffer edoc-annot-edit-contents--buffer
        (edoc-annot-edit-contents-finalize 'ask)))
    (unless (buffer-live-p edoc-annot-edit-contents--buffer)
      (setq edoc-annot-edit-contents--buffer
            (get-buffer-create
             (format "*Edit Annotation %s*" (buffer-name)))))
    (with-current-buffer edoc-annot-edit-contents--buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (save-excursion (insert (edoc-annot-get a 'contents)))
        (set-buffer-modified-p nil))
      (setq edoc-annot-edit-contents--annotation a)
      (funcall edoc-annot-edit-contents-setup-function a)
      (edoc-annot-edit-contents-minor-mode 1)
      (current-buffer))))

(defun edoc-annot-edit-contents (a)
  "Edit the contents of annotation A."
  (select-window
   (display-buffer
    (edoc-annot-edit-contents-noselect a)
    edoc-annot-edit-contents-display-buffer-action)))

(defun edoc-annot-edit-contents-mouse (ev)
  "Edit the contents of the annotation described by mouse event EV."
  (interactive "@e")
  (let* ((pos (posn-object-x-y (event-start ev)))
         (a (and pos (edoc-annot-at-position pos))))
    (unless a
      (error "No annotation at this position"))
    (edoc-annot-edit-contents a)))



;; * ================================================================== *
;; * Listing annotations
;; * ================================================================== *

(defcustom edoc-annot-list-display-buffer-action
  '((display-buffer-reuse-window
     display-buffer-pop-up-window)
    (inhibit-same-window . t))
  "Display action used when displaying the list buffer."
  :type display-buffer--action-custom-type)

(defcustom edoc-annot-list-format
  '((page . 3)
    (type . 10)
    (label . 24)
    (date . 24))
  "Annotation properties visible in the annotation list.

It should be a list of \(PROPERTIZE. WIDTH\), where PROPERTY is a
symbol naming one of supported properties to list and WIDTH its
desired column-width.

Currently supported properties are page, type, label, date and contents."
  :type '(alist :key-type (symbol))
  :options '((page (integer :value 3 :tag "Column Width"))
             (type (integer :value 10 :tag "Column Width" ))
             (label (integer :value 24 :tag "Column Width"))
             (date (integer :value 24 :tag "Column Width"))
             (contents (integer :value 56 :tag "Column Width"))))

(defcustom edoc-annot-list-highlight-type t
  "Whether to highlight \"Type\" column annotation list with annotation color."
  :type 'boolean)

(defvar-local edoc-annot-list-buffer nil)

(defvar-local edoc-annot-list-document-buffer nil)

(defvar edoc-annot-list-mode-map
  (let ((km (make-sparse-keymap)))
    (define-key km (kbd "C-c C-f") #'edoc-annot-list-follow-minor-mode)
    (define-key km (kbd "SPC") #'edoc-annot-list-display-annotation-from-id)
    km))

(defun edoc-annot-property-completions (property)
  "Return a list of completion candidates for annotation property PROPERTY.

Return nil, if not available."
  (cl-case property
    (color (edoc-util-color-completions))
    (icon (copy-sequence edoc-annot-standard-text-icons))))

(defun edoc-annot-compare-annotations (a1 a2)
  "Compare annotations A1 and A2.

Return non-nil if A1's page is less than A2's one or if they
belong to the same page and A1 is displayed above/left of A2."
  (let ((p1 (edoc-annot-get a1 'page))
        (p2 (edoc-annot-get a2 'page)))
    (or (< p1 p2)
        (and (= p1 p2)
             (let ((e1 (edoc-util-scale
                        (car (edoc-annot-get-display-edges a1))
                        '(1000 . 1000)))
                   (e2 (edoc-util-scale
                        (car (edoc-annot-get-display-edges a2))
                        '(1000 . 1000))))
               (edoc-util-with-edges (e1 e2)
                 (or (< e1-top e2-top)
                     (and (= e1-top e2-top)
                          (<= e1-left e2-left)))))))))

(defun edoc-annot-list-entries ()
  "Return all the annotations of this PDF buffer as a `tabulated-list'."
  (unless (buffer-live-p edoc-annot-list-document-buffer)
    (error "No PDF document associated with this buffer"))
  (mapcar #'edoc-annot-list-create-entry
          (sort (edoc-annot-getannots nil edoc-annot-list-listed-types
                                     edoc-annot-list-document-buffer)
                #'edoc-annot-compare-annotations)))

(defun edoc-annot--make-entry-formatter (a)
  "Return a formatter function for annotation A.

A formatter function takes a format cons-cell and returns
pretty-printed output."
  (lambda (fmt)
    (let ((entry-type (car fmt))
          (entry-width (cdr fmt))
          ;; Taken from css-mode.el
          (contrasty-color
           (lambda (name)
             (if (> (color-distance name "black") 292485)
                 "black" "white")))
          (prune-newlines
           (lambda (str)
             (replace-regexp-in-string "\n" " " str t t))))
      (cl-ecase entry-type
        (date (propertize (edoc-annot-print-property a 'modified)
                          'date
                          (edoc-annot-get a 'modified)))
        (page (edoc-annot-print-property a 'page))
        (label (funcall prune-newlines
                        (edoc-annot-print-property a 'label)))
        (contents
         (truncate-string-to-width
          (funcall prune-newlines
                   (edoc-annot-print-property a 'contents))
          entry-width))
        (type
         (let ((color (edoc-annot-get a 'color))
               (type (edoc-annot-print-property a 'type)))
           (if (and edoc-annot-list-highlight-type color)
               (propertize
                type 'face
                `(:background ,color
                              :foreground ,(funcall contrasty-color color)))
             type)))))))

(defun edoc-annot-list-create-entry (a)
  "Create a `tabulated-list-entries' entry for annotation A."
  (list (edoc-annot-get-id a)
        (vconcat
         (mapcar (edoc-annot--make-entry-formatter a)
                 edoc-annot-list-format))))

(define-derived-mode edoc-annot-list-mode tablist-mode "Annots"
  ;; @TODO: Remove the hard-coded index values here, and figure out a
  ;; way to properly link this to the index values of
  ;; `edoc-annot-list-format'.

  ;; @TODO: Add tests for annotation formatting and display
  (let* ((page-sorter
          (lambda (a b)
            (< (string-to-number (aref (cadr a) 0))
               (string-to-number (aref (cadr b) 0)))))
         (date-sorter
          (lambda (a b)
            (time-less-p (get-text-property 0 'date (aref (cadr a) 3))
                         (get-text-property 0 'date (aref (cadr b) 3)))))
         (format-generator
          (lambda (format)
            (let ((field (car format))
                  (width (cdr format)))
              (cl-case field
                (page `("Pg."
                        ,width
                        ,page-sorter
                        :read-only t
                        :right-align t))
                (date `("Date"
                        ,width
                        ,date-sorter
                        :read-only t))
                (t (list
                    (capitalize (symbol-name field))
                    width
                    t
                    :read-only t)))))))
    (setq tabulated-list-entries 'edoc-annot-list-entries
          tabulated-list-format (vconcat
                                 (mapcar
                                  format-generator
                                  edoc-annot-list-format))
          tabulated-list-padding 2))
  (set-keymap-parent edoc-annot-list-mode-map tablist-mode-map)
  (use-local-map edoc-annot-list-mode-map)
  (when (assq 'type edoc-annot-list-format)
    (setq tablist-current-filter
          `(not (== "Type" "link"))))
  (tabulated-list-init-header))

(defun edoc-annot-list-annotations ()
  "List annotations in a Dired like buffer.

\\{edoc-annot-list-mode-map}"
  (interactive)
  (edoc-util-assert-edoc-buffer)
  (let* ((buffer (current-buffer))
         (name (format "*%s's annots*"
                       (file-name-sans-extension
                        (buffer-name))))
         (annots-existed (and (get-buffer name)
                              edoc-annot-list-buffer)))
    (with-current-buffer (get-buffer-create name)
      (delay-mode-hooks
        (unless (derived-mode-p 'edoc-annot-list-mode)
          (edoc-annot-list-mode))
        (setq edoc-annot-list-document-buffer buffer)
        (unless annots-existed
          (tabulated-list-print))
        (setq tablist-context-window-function
              (lambda (id) (edoc-annot-list-context-function id buffer))
              tablist-operations-function #'edoc-annot-list-operation-function)
        (let ((list-buffer (current-buffer)))
          (with-current-buffer buffer
            (setq edoc-annot-list-buffer list-buffer))))
      (run-mode-hooks)
      (pop-to-buffer
       (current-buffer)
       edoc-annot-list-display-buffer-action)
      (tablist-move-to-major-column)
      (tablist-display-context-window))
    (add-hook 'edoc-info-close-document-hook
              #'edoc-annot-list-update nil t)
    (add-hook 'edoc-annot-modified-functions
              #'edoc-annot-list-update nil t)))

(defun edoc-annot-list-goto-annotation (a)
  "List all the annotations in the current buffer.

Goto the annotation A in the list."
  (with-current-buffer (edoc-annot-get-buffer a)
    (unless (and (buffer-live-p edoc-annot-list-buffer)
                 (get-buffer-window edoc-annot-list-buffer))
      (edoc-annot-list-annotations))
    (with-selected-window (get-buffer-window edoc-annot-list-buffer)
      (goto-char (point-min))
      (let ((id (edoc-annot-get-id a)))
        (while (and (not (eobp))
                    (not (eq id (tabulated-list-get-id))))
          (forward-line))
        (unless (eq id (tabulated-list-get-id))
          (error "Unable to find annotation"))
        (when (invisible-p (point))
          (tablist-suspend-filter t))
        (tablist-move-to-major-column)))))


(defun edoc-annot-list-update (&optional _fn)
  "Update the list of annotations on any change.

This is an internal function which runs as a hook in various situations."
  (when (buffer-live-p edoc-annot-list-buffer)
    (with-current-buffer edoc-annot-list-buffer
      (unless tablist-edit-column-minor-mode
        (tablist-revert))
      (tablist-context-window-update))))

(defun edoc-annot-list-context-function (id buffer)
  "Show the contents of an Annotation.

For an annotation identified by ID, belonging to PDF in BUFFER,
get the contents and display them on demand."
  (with-current-buffer (get-buffer-create "*Contents*")
    (set-window-buffer nil (current-buffer))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (when id
        (save-excursion
          (insert
           (edoc-annot-print-annotation
            (edoc-annot-getannot id buffer)))))
      (read-only-mode 1))))

(defun edoc-annot-list-operation-function (op &rest args)
  "Define bulk operations in Annotation list buffer.

OP is the operation that the user wants to execute. Supported
operations are `delete' and `find-entry'.

ARGS contain the annotation-ids to operate on."
  (cl-ecase op
    (supported-operations '(delete find-entry))
    (delete
     (cl-destructuring-bind (ids)
         args
       (when (buffer-live-p edoc-annot-list-document-buffer)
         (with-current-buffer edoc-annot-list-document-buffer
           (edoc-annot-with-atomic-modifications
             (dolist (a (mapcar #'edoc-annot-getannot ids))
               (edoc-annot-delete a)))))))
    (find-entry
     (cl-destructuring-bind (id)
         args
       (unless (buffer-live-p edoc-annot-list-document-buffer)
         (error "No PDF document associated with this buffer"))
       (let* ((buffer edoc-annot-list-document-buffer)
              (a (edoc-annot-getannot id buffer))
              (edoc-window (save-selected-window
                            (or (get-buffer-window buffer)
                                (display-buffer buffer))))
              window)
         (with-current-buffer buffer
           (edoc-annot-activate-annotation a)
           (setq window (selected-window)))
         ;; Make it so that quitting the edit window returns to the
         ;; list window.
         (unless (memq window (list (selected-window) edoc-window))
           (let* ((quit-restore
                   (window-parameter window 'quit-restore)))
             (when quit-restore
               (setcar (nthcdr 2 quit-restore) (selected-window))))))))))

(defvar edoc-annot-list-display-annotation--timer nil)

(defun edoc-annot-list-display-annotation-from-id (id)
  "Display the Annotation ID in the PDF file.

This allows us to follow the tabulated-list of annotations and
have the PDF buffer automatically move along with us."
  (interactive (list (tabulated-list-get-id)))
  (when id
    (unless (buffer-live-p edoc-annot-list-document-buffer)
      (error "PDF buffer was killed"))
    (when (timerp edoc-annot-list-display-annotation--timer)
      (cancel-timer edoc-annot-list-display-annotation--timer))
    (setq edoc-annot-list-display-annotation--timer
          (run-with-idle-timer 0.1 nil
            (lambda (buffer a)
              (when (buffer-live-p buffer)
                (with-selected-window
                    (or (get-buffer-window buffer)
                        (display-buffer
                         buffer
                         '(nil (inhibit-same-window . t))))
                  (edoc-annot-show-annotation a t))))
            edoc-annot-list-document-buffer
            (edoc-annot-getannot id edoc-annot-list-document-buffer)))))

(define-minor-mode edoc-annot-list-follow-minor-mode
  "Make the PDF follow the annotations in the list buffer."
  :group 'edoc-annot
  (unless (derived-mode-p 'edoc-annot-list-mode)
    (error "Not in edoc-annot-list-mode"))
  (cond
   (edoc-annot-list-follow-minor-mode
    (add-hook 'tablist-selection-changed-functions
              #'edoc-annot-list-display-annotation-from-id nil t)
    (let ((id (tabulated-list-get-id)))
      (when id
        (edoc-annot-list-display-annotation-from-id id))))
   (t
    (remove-hook 'tablist-selection-changed-functions
                 #'edoc-annot-list-display-annotation-from-id t))))

(provide 'edoc-annot)
;;; edoc-annot.el ends here
