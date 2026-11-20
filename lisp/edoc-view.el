;;; edoc-view.el --- View PDF documents. -*- lexical-binding:t -*-

;; Copyright (C) 2013  Andreas Politz

;; Author: Andreas Politz <politza@fh-trier.de>
;; Keywords: files, doc-view, pdf

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

;;  Functions related to viewing PDF documents.

;;; Code:

(require 'image-mode)
(require 'edoc-macs)
(require 'edoc-util)
(require 'edoc-info)
(require 'edoc-cache)
(require 'jka-compr)
(require 'bookmark)
(require 'password-cache)

(declare-function cua-copy-region "cua-base")
(declare-function edoc-tools-edoc-buffer-p "edoc-tools")

;; * ================================================================== *
;; * Customizations
;; * ================================================================== *

(defgroup edoc-view nil
  "View PDF documents."
  :group 'edoc-tools)

(defcustom edoc-view-display-size 'fit-width
  "The desired size of displayed pages.

This may be one of `fit-height', `fit-width', `fit-page' or a
number as a scale factor applied to the document's size.  Any
other value behaves like `fit-width'."
  :group 'edoc-view
  :type '(choice number
                 (const fit-height)
                 (const fit-width)
                 (const fit-page)))

(make-variable-buffer-local 'edoc-view-display-size)

(defcustom edoc-view-resize-factor 1.25
  "Fractional amount of resizing of one resize command."
  :group 'edoc-view
  :type 'number)

(defcustom edoc-view-continuous t
  "In Continuous mode reaching the page edge advances to next/previous page.

When non-nil, scrolling a line upward at the bottom edge of the page
moves to the next page, and scrolling a line downward at the top edge
of the page moves to the previous page."
  :type 'boolean
  :group 'edoc-view)

(defcustom edoc-view-bounding-box-margin 0.05
  "Fractional margin used for slicing with the bounding-box."
  :group 'edoc-view
  :type 'number)

(defcustom edoc-view-use-imagemagick nil
  "Whether imagemagick should be used for rendering.

This variable has no effect, if imagemagick was not compiled into
Emacs or if imagemagick is the only way to display PNG images.
FIXME: Explain dis-/advantages of imagemagick and png."
  :group 'edoc-view
  :type 'boolean)

(defcustom edoc-view-use-scaling t
  "Whether images should be allowed to be scaled for rendering.

This variable affects both the reuse of higher-resolution images
as lower-resolution ones by down-scaling the image.  As well as
the rendering of higher-resolution for high-resolution displays,
if available."
  :group 'edoc-view
  :type 'boolean)

(defface edoc-view-region
  '((((background dark)) (:inherit region))
    (((background light)) (:inherit region)))
  "Face used to determine the colors of the region."
  :group 'edoc-view
  :group 'edoc-tools-faces)

(defface edoc-view-rectangle
  '((((background dark)) (:inherit highlight))
    (((background light)) (:inherit highlight)))
  "Face used to determine the colors of the highlighted rectangle."
  :group 'edoc-view
  :group 'edoc-tools-faces)

(defcustom edoc-view-midnight-colors '("#839496" . "#002b36" )
  "Colors used when command `edoc-view-midnight-minor-mode' is activated.

This should be a cons \(FOREGROUND . BACKGROUND\) of colors."
  :group 'edoc-view
  :type '(cons (color :tag "Foreground")
               (color :tag "Background")))

(defcustom edoc-view-midnight-invert t
  "In midnight mode invert the image color lightness maintaining hue.

This is particularly useful if you are viewing documents with
color coded data in plots.  This will maintain the colors such
that blue and red will remain these colors in the inverted
rendering. This inversion is non-trivial. This makes use of the
OKLab color space which is well calibrated to have equal
perceptual brightness across hue, but not all colors are within
the RGB gamut after inversion, causing some colors to saturate.
Nevertheless, this seems to work well in most cases."
  :group 'edoc-view
  :type 'boolean)

(defcustom edoc-view-change-page-hook nil
  "Hook run after changing to another page, but before displaying it.

See also `edoc-view-before-change-page-hook' and
`edoc-view-after-change-page-hook'."
  :group 'edoc-view
  :type 'hook)

(defcustom edoc-view-before-change-page-hook nil
  "Hook run before changing to another page.

See also `edoc-view-change-page-hook' and
`edoc-view-after-change-page-hook'."
  :group 'edoc-view
  :type 'hook)

(defcustom edoc-view-after-change-page-hook nil
  "Hook run after changing to and displaying another page.

See also `edoc-view-change-page-hook' and
`edoc-view-before-change-page-hook'."
  :group 'edoc-view
  :type 'hook)

(defcustom edoc-view-use-dedicated-register t
  "Whether to use dedicated register for PDF positions.

If this is non-nil, the commands `edoc-view-position-to-register'
and `edoc-view-jump-to-register' use the buffer-local variable
`edoc-view-register-alist' to store resp. retrieve marked
positions.  Otherwise the common variable `register-alist' is
used."
  :group 'edoc-view
  :type 'boolean)

(defcustom edoc-view-image-relief 0
  "Add a shadow rectangle around the page's image.

See :relief property in Info node `(elisp) Image Descriptors'."
  :group 'edoc-view
  :type '(integer :tag "Pixel")
  :link '(info-link "(elisp) Image Descriptors"))

(defcustom edoc-view-max-image-width 4800
  "Maximum width of any image displayed in pixel."
  :group 'edoc-view
  :type '(integer :tag "Pixel"))

(defcustom edoc-view-use-unicode-ligther t
  "Decide whether to use unicode symbols in the mode-line.

On some systems finding a font which supports those symbols can
take some time.  If you don't want to spend that time waiting and
don't care for a nicer looking mode-line, set this variable to
nil.

Note, that this option has only an effect when this library is
loaded."
  :group 'edoc-view
  :type 'boolean)

(defcustom edoc-view-incompatible-modes
  '(linum-mode linum-relative-mode helm-linum-relative-mode
	           nlinum-mode nlinum-hl-mode nlinum-relative-mode yalinum-mode
               display-line-numbers-mode)
  "A list of modes incompatible with `edoc-view-mode'.

Issue a warning, if one of them is active in a PDF buffer."
  :group 'edoc-view
  :type '(repeat symbol))

(defcustom edoc-view-selection-style 'word
  "The current default selection style.

Must be one of `glyph', `word', or `line'."
  :group 'edoc-view
  :type '(choice (const glyph)
                 (const word)
                 (const line)))


;; * ================================================================== *
;; * Internal variables and macros
;; * ================================================================== *

(defvar-local edoc-view-active-region nil
  "The active region as a list of edges.

Edge values are relative coordinates.")

(defvar-local edoc-view--have-rectangle-region nil
  "Non-nil if the region is currently rendered as a rectangle.

This variable is set in `edoc-view-mouse-set-region' and used in
`edoc-view-mouse-extend-region' to determine the right choice
regarding display of the region in the later function.")

(defvar-local edoc-view--buffer-file-name nil
  "Local copy of remote file or nil.")

(defvar-local edoc-view--server-file-name nil
  "The servers notion of this buffer's filename.")

(defvar-local edoc-view--next-page-timer nil
  "Timer used in `edoc-view-next-page-command'.")

(defvar-local edoc-view--hotspot-functions nil
  "Alist of hotspot functions.")

(defvar-local edoc-view--current-rotation nil
  "Current rotation of the page.")

(defvar-local edoc-view-register-alist nil
  "Local, dedicated register for PDF positions.")

(defun edoc-view-current-pagelabel (&optional window)
  (nth (1- (edoc-view-current-page window)) (edoc-info-pagelabels)))

(defun edoc-view-active-region-p nil
  "Return t if there are active regions."
  (not (null edoc-view-active-region)))

(defmacro edoc-view-assert-active-region ()
  "Signal an error if there are no active regions."
  `(unless (edoc-view-active-region-p)
     (error "The region is not active")))

(defconst edoc-view-have-image-mode-pixel-vscroll
  (>= emacs-major-version 27)
  "Whether `image-mode' scrolls vertically by pixels.")


;; * ================================================================== *
;; * Major Mode
;; * ================================================================== *

(defvar edoc-view-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map image-mode-map)
    (define-key map (kbd "Q")         'kill-this-buffer)
    ;; Navigation in the document
    (define-key map (kbd "n")         'edoc-view-next-page-command)
    (define-key map (kbd "p")         'edoc-view-previous-page-command)
    (define-key map (kbd "<next>")    'forward-page)
    (define-key map (kbd "<prior>")   'backward-page)
    (define-key map [remap forward-page]  'edoc-view-next-page-command)
    (define-key map [remap backward-page] 'edoc-view-previous-page-command)
    (define-key map (kbd "SPC")       'edoc-view-scroll-up-or-next-page)
    (define-key map (kbd "S-SPC")     'edoc-view-scroll-down-or-previous-page)
    (define-key map (kbd "DEL")       'edoc-view-scroll-down-or-previous-page)
    (define-key map (kbd "C-n")       'edoc-view-next-line-or-next-page)
    (define-key map (kbd "<down>")    'edoc-view-next-line-or-next-page)
    (define-key map [remap next-line] 'edoc-view-next-line-or-next-page)
    (define-key map (kbd "C-p")           'edoc-view-previous-line-or-previous-page)
    (define-key map (kbd "<up>")          'edoc-view-previous-line-or-previous-page)
    (define-key map [remap previous-line] 'edoc-view-previous-line-or-previous-page)
    (define-key map (kbd "M-<")                 'edoc-view-first-page)
    (define-key map [remap beginning-of-buffer] 'edoc-view-first-page)
    (define-key map (kbd "M->")                 'edoc-view-last-page)
    (define-key map [remap end-of-buffer]       'edoc-view-last-page)
    (define-key map [remap goto-line] 'edoc-view-goto-page)
    (define-key map (kbd "M-g l")     'edoc-view-goto-label)
    (define-key map (kbd "RET")       'image-next-line)
    ;; Zoom in/out.
    (define-key map "+"               'edoc-view-enlarge)
    (define-key map "="               'edoc-view-enlarge)
    (define-key map "-"               'edoc-view-shrink)
    (define-key map "0"               'edoc-view-scale-reset)
    ;; Fit the image to the window
    (define-key map "W"               'edoc-view-fit-width-to-window)
    (define-key map "H"               'edoc-view-fit-height-to-window)
    (define-key map "P"               'edoc-view-fit-page-to-window)
    ;; Slicing the image
    (define-key map (kbd "s m")       'edoc-view-set-slice-using-mouse)
    (define-key map (kbd "s b")       'edoc-view-set-slice-from-bounding-box)
    (define-key map (kbd "s r")       'edoc-view-reset-slice)
    ;; Rotation.
    (define-key map (kbd "R")              #'edoc-view-rotate)
    ;; Reconvert
    (define-key map (kbd "C-c C-c")   'doc-view-mode)
    (define-key map (kbd "g")         'revert-buffer)
    ;; Region
    (define-key map [down-mouse-1] 'edoc-view-mouse-set-region)
    (define-key map [M-down-mouse-1] 'edoc-view-mouse-set-region-rectangle)
    (define-key map [C-down-mouse-1] 'edoc-view-mouse-extend-region)
    (define-key map [remap kill-region] 'edoc-view-kill-ring-save)
    (define-key map [remap kill-ring-save] 'edoc-view-kill-ring-save)
    (define-key map [remap mark-whole-buffer] 'edoc-view-mark-whole-page)
    ;; Other
    (define-key map (kbd "C-c C-d") 'edoc-view-dark-minor-mode)
    (define-key map (kbd "m") 'edoc-view-position-to-register)
    (define-key map (kbd "'") 'edoc-view-jump-to-register)

    (define-key map (kbd "C-c C-i") 'edoc-view-extract-region-image)
    ;; Rendering
    (define-key map (kbd "C-c C-r m") 'edoc-view-midnight-minor-mode)
    (define-key map (kbd "C-c C-r t") 'edoc-view-themed-minor-mode)
    (define-key map (kbd "C-c C-r p") 'edoc-view-printer-minor-mode)
    map)
  "Keymap used by `edoc-view-mode' when displaying a doc as a set of images.")

(defvar edoc-tools-enabled-modes)
(define-derived-mode edoc-view-mode special-mode "EDocView"
  "Major mode in PDF buffers.

EDocView Mode is an Emacs PDF viewer.  It displays PDF files as
PNG images in Emacs buffers."
  :group 'edoc-view
  :abbrev-table nil
  :syntax-table nil
  ;; Setup a local copy for remote files.
  (when (and (or jka-compr-really-do-compress
                 (let ((file-name-handler-alist nil))
                   (not (and buffer-file-name
                             (file-readable-p buffer-file-name)))))
             (edoc-tools-edoc-buffer-p))
    (let ((tempfile (edoc-util-make-temp-file)))
      (write-region nil nil tempfile nil 'no-message)
      (setq-local edoc-view--buffer-file-name tempfile)))
  ;; Decryption needs to be done before any other function calls into
  ;; edoc-info.el (e.g. from the mode-line during redisplay during
  ;; waiting for process output).
  (edoc-view-decrypt-document)

  ;; Setup scroll functions
  (if (boundp 'mwheel-scroll-up-function) ; not --without-x build
      (setq-local mwheel-scroll-up-function
                  #'edoc-view-scroll-up-or-next-page))
  (if (boundp 'mwheel-scroll-down-function)
      (setq-local mwheel-scroll-down-function
                  #'edoc-view-scroll-down-or-previous-page))

  ;; Disable pixel-scroll-precision-mode locally if enabled
  (if (bound-and-true-p pixel-scroll-precision-mode)
      (set (make-local-variable 'pixel-scroll-precision-mode) nil))
  (if (boundp 'mwheel-coalesce-scroll-events)
      (setq-local mwheel-coalesce-scroll-events t))

  ;; If the Emacs theme is dark, add `edoc-view-dark-minor-mode' to the
  ;; list of `edoc-tools-enabled-modes'. See an interesting discussion
  ;; at: https://github.com/vedang/edoc-tools/issues/166 about how this
  ;; avoids a segfault crash in MacOS Ventura. IF you know why this
  ;; happens, please get in touch via the linked issue.

  (when (eq 'dark (frame-parameter nil 'background-mode))
    (add-to-list 'edoc-tools-enabled-modes 'edoc-view-dark-minor-mode))

  ;; Clearing overlays
  (add-hook 'change-major-mode-hook
            (lambda ()
              (remove-overlays (point-min) (point-max) 'edoc-view t))
            nil t)
  (remove-overlays (point-min) (point-max) 'edoc-view t) ;Just in case.

  ;; Setup other local variables.
  (setq-local mode-line-position
              '(" P" (:eval (number-to-string (edoc-view-current-page)))
                ;; Avoid errors during redisplay.
                "/" (:eval (or (ignore-errors
                                 (number-to-string (edoc-cache-number-of-pages)))
                               "???"))))
  (setq-local auto-hscroll-mode nil)
  (setq-local edoc-view--server-file-name (edoc-view-buffer-file-name))
  ;; High values of scroll-conservatively seem to trigger
  ;; some display bug in xdisp.c:try_scrolling .
  (setq-local scroll-conservatively 0)
  (setq-local cursor-type nil)
  (setq-local buffer-read-only t)
  (setq-local view-read-only nil)
  (setq-local bookmark-make-record-function
              'edoc-view-bookmark-make-record)
  (setq-local revert-buffer-function #'edoc-view-revert-buffer)
  ;; No auto-save at the moment.
  (setq-local buffer-auto-save-file-name nil)
  ;; Disable image rescaling.
  (when (boundp 'image-scaling-factor)
    (setq-local image-scaling-factor 1))
  ;; No undo at the moment.
  (unless buffer-undo-list
    (buffer-disable-undo))
  ;; Enable transient-mark-mode, so region deactivation when quitting
  ;; will work.
  (setq-local transient-mark-mode t)

  (add-hook 'window-configuration-change-hook
            'edoc-view-redisplay-some-windows nil t)
  (add-hook 'deactivate-mark-hook 'edoc-view-deactivate-region nil t)
  (add-hook 'write-contents-functions
            'edoc-view--write-contents-function nil t)
  (add-hook 'kill-buffer-hook 'edoc-view-close-document nil t)
  (edoc-view-add-hotspot-function
   'edoc-view-text-regions-hotspots-function -9)

  ;; Keep track of display info
  (add-hook 'image-mode-new-window-functions
            'edoc-view-new-window-function nil t)
  (image-mode-setup-winprops)

  ;; Issue a warning in the future about incompatible modes.
  (run-with-timer 1 nil (lambda (buffer)
                          (when (buffer-live-p buffer)
                            (edoc-view-check-incompatible-modes buffer)))
		  (current-buffer)))

(advice-add 'cua-copy-region
	        :before-until
	        #'cua-copy-region--edoc-view-advice)

(defun cua-copy-region--edoc-view-advice (&rest _)
  "If the current buffer is in `edoc-view' mode, call `edoc-view-kill-ring-save'."
  (when (eq major-mode 'edoc-view-mode)
    (edoc-view-kill-ring-save)
    t))

(defun edoc-view-check-incompatible-modes (&optional buffer)
  "Check BUFFER for incompatible modes, maybe issue a warning."
  (with-current-buffer (or buffer (current-buffer))
    (let ((modes
	   (cl-remove-if-not
	    (lambda (mode) (and (symbolp mode)
				(boundp mode)
				(symbol-value mode)))
	    edoc-view-incompatible-modes)))
      (when modes
	(display-warning
	 'edoc-view
	 (format "These modes are incompatible with `edoc-view-mode',
	please deactivate them (or customize edoc-view-incompatible-modes): %s"
		 (mapconcat #'symbol-name modes ",")))))))

(defun edoc-view-decrypt-document ()
  "Read a password, if the document is encrypted and open it."
  (interactive)
  (when (edoc-info-encrypted-p)
    (let ((fn (buffer-file-name))
          (prompt "Enter password for pdf document: ")
          (i 3)
          key password)

      (when fn
        (setq prompt (format "Enter password for `%s': "
                             (abbreviate-file-name fn)))
        (setq key (concat "/edoc-tools" fn))
        ;; First, try with a cached password
        (when (setq password (password-read-from-cache key))
          (ignore-errors (edoc-info-open nil password))
          (when (edoc-info-encrypted-p)
            (password-cache-remove key))))

      (while (and (> i 0)
                  (edoc-info-encrypted-p))
        (setq i (1- i))
        ;; Cached password was not present or valid, try reading a new password
        ;; without cache.
        (setq password (password-read prompt))
        (setq prompt "Invalid password, try again: ")
        (ignore-errors (edoc-info-open nil password)))
      (edoc-info-open nil password)
      (when key
        (password-cache-add key password))))
  nil)

(defun edoc-view-buffer-file-name ()
  "Return the local filename of the PDF in the current buffer.

This may be different from variable `buffer-file-name' when
operating on a local copy of a remote file."
  (or edoc-view--buffer-file-name
      (buffer-file-name)))

(defun edoc-view--write-contents-function ()
  "Function for `write-contents-functions' to save the buffer."
  (when (edoc-util-edoc-buffer-p)
    (let ((tempfile (edoc-info-save edoc-view--server-file-name)))
      (unwind-protect
          (progn
            ;; Order matters here: We need to first copy the new
            ;; content (tempfile) to the PDF, and then close the PDF.
            ;; Since while closing the file (and freeing its resources
            ;; in the process), it may be immediately reopened due to
            ;; redisplay happening inside the edoc-info-close function
            ;; (while waiting for a response from the process.).
            (copy-file tempfile (or (buffer-file-name)
                                    (read-file-name
                                     "File name to save PDF to: "))
                       t)
            (edoc-info-close edoc-view--server-file-name)

            (when edoc-view--buffer-file-name
              (copy-file tempfile edoc-view--buffer-file-name t))
            (clear-visited-file-modtime)
            (set-buffer-modified-p nil)
            (setq edoc-view--server-file-name
                  (edoc-view-buffer-file-name))
            t)
        (when (file-exists-p tempfile)
          (delete-file tempfile))))))

(defun edoc-view--after-revert ()
  "Reload the local copy in case of a remote file, and close the document."
  (when edoc-view--buffer-file-name
    (write-region nil nil edoc-view--buffer-file-name nil 'no-message))
  (edoc-info-close))

(defun edoc-view-revert-buffer (&optional ignore-auto noconfirm)
  "Revert buffer while preserving current modes.

Optional parameters IGNORE-AUTO and NOCONFIRM are defined as in
`revert-buffer'."
  (interactive (list (not current-prefix-arg)))
  ;; Bind to default so that we can use edoc-view-revert-buffer as
  ;; revert-buffer-function.  A binding of nil is needed in Emacs 24.3, but in
  ;; later versions the semantics that nil means the default function should
  ;; not relied upon.
  (let ((revert-buffer-function (when (fboundp #'revert-buffer--default)
                                  #'revert-buffer--default))
        (after-revert-hook
         (cons #'edoc-view--after-revert
               after-revert-hook)))
    (prog1
        (revert-buffer ignore-auto noconfirm 'preserve-modes)
      (edoc-view-decrypt-document)
      (edoc-view-redisplay t))))

(defun edoc-view-close-document ()
  "Return immediately after closing document.

This function always succeeds.  See also `edoc-info-close', which
does not return immediately."
  (when (edoc-info-running-p)
    (let ((edoc-info-asynchronous 'ignore))
      (ignore-errors
        (edoc-info-close)))))


;; * ================================================================== *
;; * Scaling
;; * ================================================================== *

(defun edoc-view-fit-page-to-window ()
  "Fit PDF to window.

Choose the larger of PDF's height and width, and fits that
dimension to window."
  (interactive)
  (setq edoc-view-display-size 'fit-page)
  (image-set-window-vscroll 0)
  (image-set-window-hscroll 0)
  (edoc-view-redisplay t))

(defun edoc-view-fit-height-to-window ()
  "Fit PDF height to window."
  (interactive)
  (setq edoc-view-display-size 'fit-height)
  (image-set-window-vscroll 0)
  (edoc-view-redisplay t))

(defun edoc-view-fit-width-to-window ()
  "Fit PDF size to window."
  (interactive)
  (setq edoc-view-display-size 'fit-width)
  (image-set-window-hscroll 0)
  (edoc-view-redisplay t))

(defun edoc-view-enlarge (factor)
  "Enlarge PDF by FACTOR.

When called interactively, uses the value of
`edoc-view-resize-factor'.

For example, (edoc-view-enlarge 1.25) increases size by 25%."
  (interactive
   (list (float edoc-view-resize-factor)))
  (let* ((size (edoc-view-image-size))
         (pagesize (edoc-cache-pagesize
                    (edoc-view-current-page)))
         (scale (/ (float (car size))
                   (float (car pagesize)))))
    (setq edoc-view-display-size
          (* factor scale))
    (edoc-view-redisplay t)))

(defun edoc-view-shrink (factor)
  "Shrink PDF by FACTOR.

When called interactively, uses the value of
`edoc-view-resize-factor'.

For example, (edoc-view-shrink 1.25) decreases size by 20%."
  (interactive
   (list (float edoc-view-resize-factor)))
  (edoc-view-enlarge (/ 1.0 factor)))

(defun edoc-view-scale-reset ()
  "Reset PDF to its default set."
  (interactive)
  (setq edoc-view-display-size 1.0)
  (edoc-view-redisplay t))


;; * ================================================================== *
;; * Rotation
;; * ================================================================== *
(defun edoc-view-rotate (angle)
  "Rotate the current page by ANGLE degrees clockwise.
When called interactively, angle defaults to 90.  Moreover, if
called interactively with a prefix argument, then rotate
anti-clockwise."
  (interactive (list (if current-prefix-arg -90 90)))
  (setq-local edoc-view--current-rotation
              (mod (+ (or edoc-view--current-rotation 0)
                      angle)
                   360))
  (edoc-view-redisplay t))


;; * ================================================================== *
;; * Moving by pages and scrolling
;; * ================================================================== *

(defvar edoc-view-inhibit-redisplay nil)
(defvar edoc-view-inhibit-hotspots nil)

(defun edoc-view-goto-page (page &optional window)
  "Go to PAGE in PDF.

If optional parameter WINDOW, go to PAGE in all `edoc-view'
windows."
  (interactive
   (list (if current-prefix-arg
             (prefix-numeric-value current-prefix-arg)
           (read-number "Page: "))))
  (unless (and (>= page 1)
               (<= page (edoc-cache-number-of-pages)))
    (error "No such page: %d" page))
  (unless window
    (setq window
          (if (edoc-util-edoc-window-p)
              (selected-window)
            t)))
  (save-selected-window
    ;; Select the window for the hooks below.
    (when (window-live-p window)
      (select-window window 'norecord))
    (let ((changing-p
           (not (eq page (edoc-view-current-page window)))))
      (when changing-p
        (run-hooks 'edoc-view-before-change-page-hook)
        (setf (edoc-view-current-page window) page)
        (run-hooks 'edoc-view-change-page-hook))
      (when (window-live-p window)
        (edoc-view-redisplay window))
      (when changing-p
        (edoc-view-deactivate-region)
        (force-mode-line-update)
        (run-hooks 'edoc-view-after-change-page-hook))))
  nil)

(defun edoc-view-next-page (&optional n)
  "View the next page in the PDF.

Optional parameter N moves N pages forward."
  (interactive "p")
  (edoc-view-goto-page (+ (edoc-view-current-page)
                         (or n 1))))

(defun edoc-view-previous-page (&optional n)
  "View the previous page in the PDF.

Optional parameter N moves N pages backward."
  (interactive "p")
  (edoc-view-next-page (- (or n 1))))

(defun edoc-view-next-page-command (&optional n)
  "View the next page in the PDF.

Optional parameter N moves N pages forward.

This command is a wrapper for `edoc-view-next-page' that will
indicate to the user if they are on the last page and more."
  (declare (interactive-only edoc-view-next-page))
  (interactive "p")
  (unless n (setq n 1))
  (when (> (+ (edoc-view-current-page) n)
           (edoc-cache-number-of-pages))
    (user-error "Last page"))
  (when (< (+ (edoc-view-current-page) n) 1)
    (user-error "First page"))
  (let ((edoc-view-inhibit-redisplay t))
    (edoc-view-goto-page
     (+ (edoc-view-current-page) n)))
  (force-mode-line-update)
  (sit-for 0)
  (when edoc-view--next-page-timer
    (cancel-timer edoc-view--next-page-timer)
    (setq edoc-view--next-page-timer nil))
  (if (or (not (input-pending-p))
          (and (> n 0)
               (= (edoc-view-current-page)
                  (edoc-cache-number-of-pages)))
          (and (< n 0)
               (= (edoc-view-current-page) 1)))
      (edoc-view-redisplay)
    (setq edoc-view--next-page-timer
          (run-with-idle-timer 0.001 nil 'edoc-view-redisplay (selected-window)))))

(defun edoc-view-previous-page-command (&optional n)
  "View the previous page in the PDF.

Optional parameter N moves N pages backward.

This command is a wrapper for `edoc-view-previous-page'."
  (declare (interactive-only edoc-view-previous-page))
  (interactive "p")
  (with-no-warnings
    (edoc-view-next-page-command (- (or n 1)))))

(defun edoc-view-first-page ()
  "View the first page."
  (interactive)
  (edoc-view-goto-page 1))

(defun edoc-view-last-page ()
  "View the last page."
  (interactive)
  (edoc-view-goto-page (edoc-cache-number-of-pages)))

(defun edoc-view-scroll-up-or-next-page (&optional arg)
  "Scroll page up ARG lines if possible, else go to the next page.

When `edoc-view-continuous' is non-nil, scrolling upward at the
bottom edge of the page moves to the next page.  Otherwise, go to
next page only on typing SPC (ARG is nil)."
  (interactive "P")
  (if (or edoc-view-continuous (null arg))
      (let ((hscroll (window-hscroll))
            (cur-page (edoc-view-current-page))
            (win-scroll (window-vscroll nil edoc-view-have-image-mode-pixel-vscroll))
            (img-scroll (image-scroll-up arg)))
        (when (or
               ;; There is no next line for the image to scroll to
               (and img-scroll (= win-scroll img-scroll))
               ;; Workaround rounding/off-by-one issues.
               (memq edoc-view-display-size
                     '(fit-height fit-page)))
          (edoc-view-next-page)
          (when (/= cur-page (edoc-view-current-page))
            (image-bob)
            (image-bol 1))
          (image-set-window-hscroll hscroll)))
    (image-scroll-up arg)))

(defun edoc-view-scroll-down-or-previous-page (&optional arg)
  "Scroll page down ARG lines if possible, else go to the previous page.

When `edoc-view-continuous' is non-nil, scrolling downward at the
top edge of the page moves to the previous page.  Otherwise, go
to previous page only on typing DEL (ARG is nil)."
  (interactive "P")
  (if (or edoc-view-continuous (null arg))
      (let ((hscroll (window-hscroll))
            (cur-page (edoc-view-current-page))
            (win-scroll (window-vscroll nil edoc-view-have-image-mode-pixel-vscroll))
            (img-scroll (image-scroll-down arg)))
        (when (or
               ;; There is no previous line for the image to scroll to
               (and img-scroll (= win-scroll img-scroll))
               ;; Workaround rounding/off-by-one issues.
               (memq edoc-view-display-size
                     '(fit-height fit-page)))
          (edoc-view-previous-page)
          (when (/= cur-page (edoc-view-current-page))
            (image-eob)
            (image-bol 1))
          (image-set-window-hscroll hscroll)))
    (image-scroll-down arg)))

(defun edoc-view-next-line-or-next-page (&optional arg)
  "Scroll upward by ARG lines if possible, else go to the next page.

When `edoc-view-continuous' is non-nil, scrolling a line upward
at the bottom edge of the page moves to the next page."
  (interactive "p")
  (if edoc-view-continuous
      (let ((hscroll (window-hscroll))
            (cur-page (edoc-view-current-page)))
        (when (= (window-vscroll nil edoc-view-have-image-mode-pixel-vscroll)
                 (image-next-line arg))
          (edoc-view-next-page)
          (when (/= cur-page (edoc-view-current-page))
            (image-bob)
            (image-bol 1))
          (image-set-window-hscroll hscroll)))
    (image-next-line arg)))

(defun edoc-view-previous-line-or-previous-page (&optional arg)
  "Scroll downward by ARG lines if possible, else go to the previous page.

When `edoc-view-continuous' is non-nil, scrolling a line downward
at the top edge of the page moves to the previous page."
  (interactive "p")
  (if edoc-view-continuous
      (let ((hscroll (window-hscroll))
            (cur-page (edoc-view-current-page)))
        (when (= (window-vscroll nil edoc-view-have-image-mode-pixel-vscroll)
                 (image-previous-line arg))
          (edoc-view-previous-page)
          (when (/= cur-page (edoc-view-current-page))
            (image-eob)
            (image-bol 1))
          (image-set-window-hscroll hscroll)))
    (image-previous-line arg)))

(defun edoc-view-goto-label (label)
  "Go to the page corresponding to LABEL.

Usually, the label of a document's page is the same as its
displayed page number."
  (interactive
   (list (let ((labels (edoc-info-pagelabels)))
           (completing-read "Goto label: " labels nil t))))
  (let ((index (cl-position label (edoc-info-pagelabels) :test 'equal)))
    (unless index
      (error "No such label: %s" label))
    (edoc-view-goto-page (1+ index))))

(defun edoc-view-center-in-window ()
  "Center PDF in window horizontally."
  (interactive)
  (image-set-window-hscroll
   (/ (* (- (car (edoc-view-image-size))
            (window-pixel-width))
         (window-width))
      2 (window-pixel-width))) ; convert from pixel to character width
  (edoc-view-redisplay t))

(defun edoc-view-align-left ()
  "Align left edge of pdf with left edge of window."
  (interactive)
  (image-set-window-hscroll 0)
  (edoc-view-redisplay t))

(defun edoc-view-align-right ()
  "Align right edge of pdf with right edge of window."
  (interactive)
  (image-set-window-hscroll
   (/ (* (- (car (edoc-view-image-size))
            (window-pixel-width))
         (window-width))
      (window-pixel-width))) ; convert from pixel to character width
  (edoc-view-redisplay t))


;; * ================================================================== *
;; * Slicing
;; * ================================================================== *

(defun edoc-view-set-slice (x y width height &optional window)
  "Set the slice of the pages that should be displayed in WINDOW.

WINDOW defaults to `selected-window' if not provided.
X, Y, WIDTH and HEIGHT should be relative coordinates, i.e. in
\[0;1\].  To reset the slice use `edoc-view-reset-slice'."
  (unless (equal (edoc-view-current-slice window)
                 (list x y width height))
    (setf (edoc-view-current-slice window)
          (mapcar (lambda (v)
                    (max 0 (min 1 v)))
                  (list x y width height)))
    (edoc-view-redisplay window)))

(defun edoc-view-set-slice-using-mouse ()
  "Set the slice of the images that should be displayed.

Set the slice by pressing `mouse-1' at its top-left corner and
dragging it to its bottom-right corner.  See also
`edoc-view-set-slice' and `edoc-view-reset-slice'."
  (interactive)
  (let ((size (edoc-view-image-size))
        x y w h done)
    (while (not done)
      (let ((e (read-event
                (concat "Press mouse-1 at the top-left corner and "
                        "drag it to the bottom-right corner!"))))
        (when (eq (car e) 'drag-mouse-1)
          (setq x (car (posn-object-x-y (event-start e))))
          (setq y (cdr (posn-object-x-y (event-start e))))
          (setq w (- (car (posn-object-x-y (event-end e))) x))
          (setq h (- (cdr (posn-object-x-y (event-end e))) y))
          (setq done t))))
    (apply 'edoc-view-set-slice
           (edoc-util-scale
            (list x y w h)
            (cons (/ 1.0 (float (car size)))
                  (/ 1.0 (float (cdr size))))))))

(defun edoc-view-set-slice-from-bounding-box (&optional window)
  "Set the slice from the page's bounding-box.

WINDOW defaults to `selected-window' if not provided.

The result is that the margins are almost completely cropped,
much more accurate than could be done manually using
`edoc-view-set-slice-using-mouse'.

See also `edoc-view-bounding-box-margin'."
  (interactive)
  (let* ((bb (edoc-cache-boundingbox (edoc-view-current-page window)))
         (margin (max 0 (or edoc-view-bounding-box-margin 0)))
         (slice (list (- (nth 0 bb)
                         (/ margin 2.0))
                      (- (nth 1 bb)
                         (/ margin 2.0))
                      (+ (- (nth 2 bb) (nth 0 bb))
                         margin)
                      (+ (- (nth 3 bb) (nth 1 bb))
                         margin))))
    (apply 'edoc-view-set-slice
           (append slice (and window (list window))))))

(defun edoc-view-reset-slice (&optional window)
  "Reset the current slice and redisplay WINDOW.

WINDOW defaults to `selected-window' if not provided.

After calling this function the whole page will be visible
again."
  (interactive)
  (when (edoc-view-current-slice window)
    (setf (edoc-view-current-slice window) nil)
    (edoc-view-redisplay window))
  nil)

(define-minor-mode edoc-view-auto-slice-minor-mode
  "Automatically slice pages according to their bounding boxes.

See also `edoc-view-set-slice-from-bounding-box'."
  :group 'edoc-view
  (edoc-util-assert-edoc-buffer)
  (cond
   (edoc-view-auto-slice-minor-mode
    (dolist (win (get-buffer-window-list nil nil t))
      (when (edoc-util-edoc-window-p win)
        (edoc-view-set-slice-from-bounding-box win)))
    (add-hook 'edoc-view-change-page-hook
              'edoc-view-set-slice-from-bounding-box nil t))
   (t
    (progn (remove-hook 'edoc-view-change-page-hook
                        'edoc-view-set-slice-from-bounding-box t)
           (edoc-view-reset-slice)))))


;; * ================================================================== *
;; * Display
;; * ================================================================== *

(defun edoc-view-image-type ()
  "Return the image type that should be used.

The return value is either `imagemagick' (if available and wanted
or if png is not available) or `png'.

Signal an error, if neither `imagemagick' nor `png' is available.

See also `edoc-view-use-imagemagick'."
  (cond ((and edoc-view-use-imagemagick
              (fboundp 'imagemagick-types))
         'imagemagick)
        ((image-type-available-p 'image-io)
         'image-io)
        ((image-type-available-p 'png)
         'png)
        ((fboundp 'imagemagick-types)
         'imagemagick)
        (t
         (error "PNG image supported not compiled into Emacs"))))

(defmacro edoc-view-create-image (data &rest props)
  ;; TODO: add DATA and PROPS to docstring.
  "Like `create-image', but with set DATA-P and TYPE arguments."
  (declare (indent 1) (debug t))
  (let ((image-data (make-symbol "data")))
    `(let ((,image-data ,data))
       (apply #'create-image ,image-data (edoc-view-image-type) t ,@props
              (cl-list*
               :relief (or edoc-view-image-relief 0)
               (when (and (eq (framep-on-display) 'mac)
                          (= (edoc-util-frame-scale-factor) 2))
                 (list :data-2x ,image-data)))))))

(defun edoc-view-create-page (page &optional window)
  "Create an image of PAGE for display on WINDOW."
  (let* ((size (edoc-view-desired-image-size page window))
         (data (edoc-cache-renderpage
                page (car size)
                (if edoc-view-use-scaling
                    (* 2 (car size))
                  (car size))))
         (hotspots (edoc-view-apply-hotspot-functions
                    window page size)))
    (edoc-view-create-image data
      :width (car size)
      :rotation (or edoc-view--current-rotation 0)
      :map hotspots
      :pointer 'arrow)))

(defun edoc-view-image-size (&optional displayed-p window)
  ;; TODO: add WINDOW to docstring.
  "Return the size in pixel of the current image.

If DISPLAYED-P is non-nil, return the size of the displayed
image.  These values may be different, if slicing is used."
  (if displayed-p
      (with-selected-window (or window (selected-window))
        (image-display-size
         (image-get-display-property) t))
    (image-size (edoc-view-current-image window) t)))

(defun edoc-view-image-offset (&optional window)
  ;; TODO: add WINDOW to docstring.
  "Return the offset of the current image.

It is equal to \(LEFT . TOP\) of the current slice in pixel."
  (let* ((slice (edoc-view-current-slice window)))
    (cond
     (slice
      (edoc-util-scale-relative-to-pixel
       (cons (nth 0 slice) (nth 1 slice))
       window))
     (t
      (cons 0 0)))))

(defun edoc-view-display-page (page &optional window)
  "Display page PAGE in WINDOW."
  (setf (edoc-view-window-needs-redisplay window) nil)
  (edoc-view-display-image
   (edoc-view-create-page page window)
   window))

(defun edoc-view-display-image (image &optional window inhibit-slice-p)
  ;; TODO: write documentation!
  (let ((ol (edoc-view-current-overlay window)))
    (when (window-live-p (overlay-get ol 'window))
      (let* ((size (image-size image t))
             (slice (if (not inhibit-slice-p)
                        (edoc-view-current-slice window)))
             (displayed-width (floor
                               (if slice
                                   (* (nth 2 slice)
                                      (car (image-size image)))
                                 (car (image-size image))))))
        (setf (edoc-view-current-image window) image)
        (move-overlay ol (point-min) (point-max))
        ;; In case the window is wider than the image, center the image
        ;; horizontally.
        (overlay-put ol 'before-string
                     (when (> (window-width window)
                              displayed-width)
                       (propertize " " 'display
                                   `(space :align-to
                                           ,(/ (- (window-width window)
                                                  displayed-width) 2)))))
        (overlay-put ol 'display
                     (if slice
                         (list (cons 'slice
                                     (edoc-util-scale slice size 'round))
                               image)
                       image))
        (let* ((win (overlay-get ol 'window))
               (hscroll (image-mode-window-get 'hscroll win))
               (vscroll (image-mode-window-get 'vscroll win)))
          ;; Reset scroll settings, in case they were changed.
          (if hscroll (set-window-hscroll win hscroll))
          (if vscroll (set-window-vscroll
                       win vscroll edoc-view-have-image-mode-pixel-vscroll)))))))

(defun edoc-view-redisplay (&optional window)
  "Redisplay page in WINDOW.

If WINDOW is t, redisplay pages in all windows."
  (unless edoc-view-inhibit-redisplay
    (if (not (eq t window))
        (edoc-view-display-page
         (edoc-view-current-page window)
         window)
      (dolist (win (get-buffer-window-list nil nil t))
        (edoc-view-display-page
         (edoc-view-current-page win)
         win))
      (when (consp image-mode-winprops-alist)
        (dolist (window (mapcar #'car image-mode-winprops-alist))
          (unless (or (not (window-live-p window))
                      (eq (current-buffer)
                          (window-buffer window)))
            (setf (edoc-view-window-needs-redisplay window) t)))))
    (force-mode-line-update)))

(defun edoc-view-redisplay-pages (&rest pages)
  "Redisplay PAGES in all windows."
  (edoc-util-assert-edoc-buffer)
  (dolist (window (get-buffer-window-list nil nil t))
    (when (memq (edoc-view-current-page window)
                pages)
      (edoc-view-redisplay window))))

(defun edoc-view-maybe-redisplay-resized-windows ()
  "Redisplay some windows needing redisplay."
  (unless (or (numberp edoc-view-display-size)
              (edoc-view-active-region-p)
              (> (minibuffer-depth) 0))
    (dolist (window (get-buffer-window-list nil nil t))
      (let ((stored (edoc-view-current-window-size window))
            (size (cons (window-width window)
                        (window-height window))))
        (unless (equal size stored)
          (setf (edoc-view-current-window-size window) size)
          (unless (or (null stored)
                      (and (eq edoc-view-display-size 'fit-width)
                           (eq (car size) (car stored)))
                      (and (eq edoc-view-display-size 'fit-height)
                           (eq (cdr size) (cdr stored))))
            (edoc-view-redisplay window)))))))

(defun edoc-view-redisplay-some-windows ()
  (edoc-view-maybe-redisplay-resized-windows)
  (dolist (window (get-buffer-window-list nil nil t))
    (when (edoc-view-window-needs-redisplay window)
      (edoc-view-redisplay window))))

(defun edoc-view-new-window-function (winprops)
  ;; TODO: write documentation!
  ;; (message "New window %s for buf %s" (car winprops) (current-buffer))
  (cl-assert (or (eq t (car winprops))
                 (eq (window-buffer (car winprops)) (current-buffer))))
  (let ((ol (image-mode-window-get 'overlay winprops)))
    (if ol
        (progn
          (setq ol (copy-overlay ol))
          ;; `ol' might actually be dead.
          (move-overlay ol (point-min) (point-max)))
      (setq ol (make-overlay (point-min) (point-max) nil t))
      (overlay-put ol 'edoc-view t))
    (overlay-put ol 'window (car winprops))
    (unless (windowp (car winprops))
      ;; It's a pseudo entry.  Let's make sure it's not displayed (the
      ;; `window' property is only effective if its value is a window).
      (cl-assert (eq t (car winprops)))
      (delete-overlay ol))
    (image-mode-window-put 'overlay ol winprops)
    ;; Clean up some overlays.
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (and (windowp (overlay-get ov 'window))
                 (not (window-live-p (overlay-get ov 'window))))
        (delete-overlay ov)))
    (when (and (windowp (car winprops))
               (null (image-mode-window-get 'image winprops)))
      ;; We're not displaying an image yet, so let's do so.  This
      ;; happens when the buffer is displayed for the first time.
      (with-selected-window (car winprops)
        (edoc-view-goto-page
         (or (image-mode-window-get 'page t) 1))))))

(defun edoc-view-desired-image-size (&optional page window)
  ;; TODO: write documentation!
  (let* ((pagesize (edoc-cache-pagesize
                    (or page (edoc-view-current-page window))))
         (slice (edoc-view-current-slice window))
         (width-scale (/ (/ (float (window-body-width window t))
                            (or (nth 2 slice) 1.0))
                         (float (car pagesize))))
         (height (- (nth 3 (window-inside-pixel-edges window))
                    (nth 1 (window-inside-pixel-edges window))
                    1))
         (height-scale (/ (/ (float height)
                             (or (nth 3 slice) 1.0))
                          (float (cdr pagesize))))
         (scale width-scale))
    (if (numberp edoc-view-display-size)
        (setq scale (float edoc-view-display-size))
      (cl-case edoc-view-display-size
        (fit-page
         (setq scale (min height-scale width-scale)))
        (fit-height
         (setq scale height-scale))
        (t
         (setq scale width-scale))))
    (let ((width (floor (* (car pagesize) scale)))
          (height (floor (* (cdr pagesize) scale))))
      (when (> width (max 1 (or edoc-view-max-image-width width)))
        (setq width edoc-view-max-image-width
              height (* height (/ (float edoc-view-max-image-width) width))))
      (cons (max 1 width) (max 1 height)))))

(defun edoc-view-text-regions-hotspots-function (page size)
  "Return a list of hotspots for text regions on PAGE using SIZE.

This will display a text cursor, when hovering over them."
  (local-set-key [edoc-view-text-region t]
                 'edoc-util-image-map-mouse-event-proxy)
  (mapcar (lambda (region)
            (let ((e (edoc-util-scale region size 'round)))
              `((rect . ((,(nth 0 e) . ,(nth 1 e))
                         . (,(nth 2 e) . ,(nth 3 e))))
                edoc-view-text-region
                (pointer text))))
          (edoc-cache-textregions page)))

(define-minor-mode edoc-view-dark-minor-mode
  "Mode for PDF documents with dark background.

This tells the various modes to use their face's dark colors."
  :group 'edoc-view
  (edoc-util-assert-edoc-buffer)
  ;; FIXME: This should really be run in a hook.
  (when (bound-and-true-p edoc-isearch-active-mode)
    (with-no-warnings
      (edoc-isearch-redisplay)
      (edoc-isearch-message
       (if edoc-view-dark-minor-mode "dark mode" "light mode")))))

(define-minor-mode edoc-view-printer-minor-mode
  "Display the PDF as it would be printed."
  :group 'edoc-view
  :lighter " Prn"
  (edoc-util-assert-edoc-buffer)
  (let ((enable (lambda ()
                  (edoc-info-setoptions :render/printed t))))
    (cond
     (edoc-view-printer-minor-mode
      (add-hook 'after-save-hook enable nil t)
      (add-hook 'after-revert-hook enable nil t))
     (t
      (remove-hook 'after-save-hook enable t)
      (remove-hook 'after-revert-hook enable t))))
  (edoc-info-setoptions :render/printed edoc-view-printer-minor-mode)
  (edoc-cache-clear-images)
  (edoc-view-redisplay t))

(define-minor-mode edoc-view-midnight-minor-mode
  "Apply a color-filter appropriate for past midnight reading.

The colors are determined by the variable
`edoc-view-midnight-colors', which see. "
  :group 'edoc-view
  :lighter " Mid"
  (edoc-util-assert-edoc-buffer)
  ;; FIXME: Maybe these options should be passed stateless to edoc-info-renderpage ?
  (let ((enable (lambda ()
                  (edoc-info-setoptions
                   :render/foreground (or (car edoc-view-midnight-colors) "black")
                   :render/background (or (cdr edoc-view-midnight-colors) "white")
                   :render/usecolors
                   (if edoc-view-midnight-invert
                       ;; If midnight invert is enabled, pass "2" indicating
                       ;; that :render/foreground and :render/background should
                       ;; be ignored and to instead invert the PDF (preserving
                       ;; hue)
                       2
                     ;; If invert is not enabled, pass "1" indictating that
                     ;; :render/foreground and :render/background should be used
                     1)))))
    (cond
     (edoc-view-midnight-minor-mode
      (add-hook 'after-save-hook enable nil t)
      (add-hook 'after-revert-hook enable nil t)
      (funcall enable))
     (t
      (remove-hook 'after-save-hook enable t)
      (remove-hook 'after-revert-hook enable t)
      (edoc-info-setoptions
       ;; Value "0" indicates that colors should remain unchanged
       :render/usecolors 0))))
  (edoc-cache-clear-images)
  (edoc-view-redisplay t))

(defun edoc-view-set-theme-background ()
  "Set the buffer's color filter to correspond to the current Emacs theme."
  (edoc-util-assert-edoc-buffer)
  (edoc-info-setoptions
   :render/foreground (face-foreground 'default nil)
   :render/background (face-background 'default nil)
   :render/usecolors 1))

(defun edoc-view-refresh-themed-buffer (&optional get-theme)
  "Refresh the current buffer to activate applied colors.

When GET-THEME is non-nil, also reset the applied colors to the
current theme's colors."
  (edoc-util-assert-edoc-buffer)
  (edoc-cache-clear-images)
  (when get-theme
	(edoc-view-set-theme-background))
  (edoc-view-redisplay t))

(define-minor-mode edoc-view-themed-minor-mode
  "Synchronize color filter with the present Emacs theme.

The colors are determined by the `face-foreground' and
`face-background' of the currently active theme."
  :group 'edoc-view
  :lighter " Thm"
  (edoc-util-assert-edoc-buffer)
  (cond
   (edoc-view-themed-minor-mode
    (add-hook 'after-save-hook #'edoc-view-set-theme-background nil t)
    (add-hook 'after-revert-hook #'edoc-view-set-theme-background nil t))
   (t
    (remove-hook 'after-save-hook #'edoc-view-set-theme-background t)
    (remove-hook 'after-revert-hook #'edoc-view-set-theme-background t)
    (edoc-info-setoptions :render/usecolors 0)))
  (edoc-view-refresh-themed-buffer edoc-view-themed-minor-mode))

(when edoc-view-use-unicode-ligther
  ;; This check uses an implementation detail, which hopefully gets the
  ;; right answer.
  (and (fontp (char-displayable-p ?⎙))
       (setcdr (assq 'edoc-view-printer-minor-mode minor-mode-alist)
               (list " ⎙" )))
  (and (fontp (char-displayable-p ?🌙))
       (setcdr (assq 'edoc-view-midnight-minor-mode minor-mode-alist)
               (list  " 🌙" ))))


;; * ================================================================== *
;; * Hotspot handling
;; * ================================================================== *

(defun edoc-view-add-hotspot-function (fn &optional layer)
  "Register FN as a hotspot function in the current buffer, using LAYER.

FN will be called in the PDF buffer with the page-number and the
image size \(WIDTH . HEIGHT\) as arguments.  It should return a
list of hotspots applicable to the the :map image-property.

LAYER determines the order: Functions in a higher LAYER will
supersede hotspots in lower ones."
  (push (cons (or layer 0) fn)
        edoc-view--hotspot-functions))

(defun edoc-view-remove-hotspot-function (fn)
  "Unregister FN as a hotspot function in the current buffer."
  (setq edoc-view--hotspot-functions
        (cl-remove fn edoc-view--hotspot-functions
                   :key 'cdr)))

(defun edoc-view-sorted-hotspot-functions ()
  ;; TODO: write documentation!
  (mapcar 'cdr (cl-sort (copy-sequence edoc-view--hotspot-functions)
                        '> :key 'car)))

(defun edoc-view-apply-hotspot-functions (window page image-size)
  ;; TODO: write documentation!
  (unless edoc-view-inhibit-hotspots
    (save-selected-window
      (when window (select-window window 'norecord))
      (apply 'nconc
             (mapcar (lambda (fn)
                       (funcall fn page image-size))
                     (edoc-view-sorted-hotspot-functions))))))


;; * ================================================================== *
;; * Region
;; * ================================================================== *

(defun edoc-view--push-mark ()
  ;; TODO: write documentation!
  (let (mark-ring)
    (push-mark-command nil))
  (setq deactivate-mark nil))

(defun edoc-view-active-region (&optional deactivate-p)
  "Return the active region, a list of edges.

Deactivate the region if DEACTIVATE-P is non-nil."
  (edoc-view-assert-active-region)
  (prog1
      edoc-view-active-region
    (when deactivate-p
      (edoc-view-deactivate-region))))

(defun edoc-view-deactivate-region ()
  "Deactivate the region."
  (interactive)
  (when edoc-view-active-region
    (setq edoc-view-active-region nil)
    (deactivate-mark)
    (edoc-view-redisplay t)))

(defun edoc-view-mouse-set-region (event &optional allow-extend-p
                                        rectangle-p
                                        selection-style)
  "Select a region of text using the mouse with mouse event EVENT.

Allow for stacking of regions, if ALLOW-EXTEND-P is non-nil.

Create a rectangular region, if RECTANGLE-P is non-nil.

Overwrite `edoc-view-selection-style' with SELECTION-STYLE,
which is one of `glyph', `word', or `line'.

Stores the region in `edoc-view-active-region'."
  (interactive "@e")
  (setq edoc-view--have-rectangle-region rectangle-p)
  (unless (and (eventp event)
               (mouse-event-p event))
    (signal 'wrong-type-argument (list 'mouse-event-p event)))
  (unless (and allow-extend-p
               (or (null (get this-command 'edoc-view-region-window))
                   (equal (get this-command 'edoc-view-region-window)
                          (selected-window))))
    (edoc-view-deactivate-region))
  (put this-command 'edoc-view-region-window
       (selected-window))
  (let* ((window (selected-window))
         (pos (event-start event))
         (begin-inside-image-p t)
         (begin (if (posn-image pos)
                    (posn-object-x-y pos)
                  (setq begin-inside-image-p nil)
                  (posn-x-y pos)))
         (abs-begin (posn-x-y pos))
         (selection-style (or selection-style edoc-view-selection-style))
         edoc-view-continuous
         region)
    (when (edoc-util-track-mouse-dragging (event 0.05)
            (let* ((pos (event-start event))
                   (end (posn-object-x-y pos))
                   (end-inside-image-p
                    (and (eq window (posn-window pos))
                         (posn-image pos))))
              (when (or end-inside-image-p
                        begin-inside-image-p)
                (cond
                 ((and end-inside-image-p
                       (not begin-inside-image-p))
                  ;; Started selection outside the image, setup begin.
                  (let* ((xy (posn-x-y pos))
                         (dxy (cons (- (car xy) (car begin))
                                    (- (cdr xy) (cdr begin))))
                         (size (edoc-view-image-size t)))
                    (setq begin (cons (max 0 (min (car size)
                                                  (- (car end) (car dxy))))
                                      (max 0 (min (cdr size)
                                                  (- (cdr end) (cdr dxy)))))
                          ;; Store absolute position for later.
                          abs-begin (cons (- (car xy)
                                             (- (car end)
                                                (car begin)))
                                          (- (cdr xy)
                                             (- (cdr end)
                                                (cdr begin))))
                          begin-inside-image-p t)))
                 ((and begin-inside-image-p
                       (not end-inside-image-p))
                  ;; Moved outside the image, setup end.
                  (let* ((xy (posn-x-y pos))
                         (dxy (cons (- (car xy) (car abs-begin))
                                    (- (cdr xy) (cdr abs-begin))))
                         (size (edoc-view-image-size t)))
                    (setq end (cons (max 0 (min (car size)
                                                (+ (car begin) (car dxy))))
                                    (max 0 (min (cdr size)
                                                (+ (cdr begin) (cdr dxy)))))))))
                (let ((iregion (if rectangle-p
                                   (list (min (car begin) (car end))
                                         (min (cdr begin) (cdr end))
                                         (max (car begin) (car end))
                                         (max (cdr begin) (cdr end)))
                                 (list (car begin) (cdr begin)
                                       (car end) (cdr end)))))
                  (setq region
                        (edoc-util-scale-pixel-to-relative iregion))
                  (edoc-view-display-region
                   (cons region edoc-view-active-region)
                   rectangle-p
                   selection-style)
                  (edoc-util-scroll-to-edges iregion)))))
      (setq edoc-view-active-region
            (append edoc-view-active-region
                    (list region)))
      (edoc-view--push-mark))))

(defun edoc-view-mouse-extend-region (event)
  "Extend the currently active region with mouse event EVENT."
  (interactive "@e")
  (edoc-view-mouse-set-region
   event t edoc-view--have-rectangle-region))

(defun edoc-view-mouse-set-region-rectangle (event)
  "Like `edoc-view-mouse-set-region' but displays as a rectangle.

EVENT is the mouse event.

This is more useful for commands like
`edoc-view-extract-region-image'."
  (interactive "@e")
  (edoc-view-mouse-set-region event nil t))

(defun edoc-view-display-region (&optional region rectangle-p selection-style)
  ;; TODO: write documentation!
  (unless region
    (edoc-view-assert-active-region)
    (setq region edoc-view-active-region))
  (let ((colors (edoc-util-face-colors
                 (if rectangle-p 'edoc-view-rectangle 'edoc-view-region)
                 (bound-and-true-p edoc-view-dark-minor-mode)))
        (page (edoc-view-current-page))
        (width (car (edoc-view-image-size))))
    (edoc-view-display-image
     (edoc-view-create-image
         (if rectangle-p
             (edoc-info-renderpage-highlight
              page width nil
              `(,(car colors) ,(cdr colors) 0.35 ,@region))
           (edoc-info-renderpage-text-regions
            page width nil selection-style nil
            `(,(car colors) ,(cdr colors) ,@region)))
       :width width))))

(defun edoc-view-kill-ring-save ()
  "Copy the region to the `kill-ring'."
  (interactive)
  (edoc-view-assert-active-region)
  (let* ((txt (edoc-view-active-region-text)))
    (edoc-view-deactivate-region)
    (kill-new (mapconcat 'identity txt "\n"))))

(defun edoc-view-mark-whole-page ()
  "Mark the whole page."
  (interactive)
  (edoc-view-deactivate-region)
  (setq edoc-view-active-region
        (list (list 0 0 1 1)))
  (edoc-view--push-mark)
  (edoc-view-display-region))

(defun edoc-view-active-region-text ()
  "Return the text of the active region as a list of strings."
  (edoc-view-assert-active-region)
  (mapcar
   (lambda (edges)
     (edoc-info-gettext
      (edoc-view-current-page)
      edges
      edoc-view-selection-style))
   edoc-view-active-region))

(defun edoc-view-extract-region-image (regions &optional page size
                                              output-buffer no-display-p)
  ;; TODO: what is "resp."? Avoid contractions.
  "Create a PNG image of REGIONS.

REGIONS should have the same form as `edoc-view-active-region',
which see.  PAGE and SIZE are the page resp. base-size of the
image from which the image-regions will be created; they default
to `edoc-view-current-page' resp. `edoc-view-image-size'.

Put the image in OUTPUT-BUFFER, defaulting to \"*PDF region
image*\" and display it, unless NO-DISPLAY-P is non-nil.

In case of multiple regions, the resulting image is constructed
by joining them horizontally.  For this operation (and this only)
the `convert' program is used."

  (interactive
   (list (if (edoc-view-active-region-p)
             (edoc-view-active-region t)
           '((0 0 1 1)))))
  (unless page
    (setq page (edoc-view-current-page)))
  (unless size
    (setq size (edoc-view-image-size)))
  (unless output-buffer
    (setq output-buffer (get-buffer-create "*PDF image*")))
  (let* ((images (mapcar (lambda (edges)
                           (let ((file (make-temp-file "edoc-view"))
                                 (coding-system-for-write 'binary))
                             (write-region
                              (edoc-info-renderpage
                               page (car size)
                               :crop-to edges)
                              nil file nil 'no-message)
                             file))
                         regions))
         result)
    (unwind-protect
        (progn
          (if (= (length images) 1)
              (setq result (car images))
            (setq result (make-temp-file "edoc-view"))
            ;; Join the images horizontally with a gap of 10 pixel.
            (edoc-util-convert
             "-noop" ;; workaround limitations of this function
             result
             :commands `("("
                         ,@images
                         "-background" "white"
                         "-splice" "0x10+0+0"
                         ")"
                         "-gravity" "Center"
                         "-append"
                         "+gravity"
                         "-chop" "0x10+0+0")
             :apply '((0 0 0 0))))
          (with-current-buffer output-buffer
            (let ((inhibit-read-only t))
              (erase-buffer))
            (set-buffer-multibyte nil)
            (insert-file-contents-literally result)
            (image-mode)
            (unless no-display-p
              (pop-to-buffer (current-buffer)))))
      (dolist (f (cons result images))
        (when (file-exists-p f)
          (delete-file f))))))

(defun edoc-view-set-selection-style (&optional style)
  "Set `edoc-view-selection-style' to STYLE in the current buffer.

When called interactively or without an argument, cycle between
the selection styles."
  (interactive)
  (unless style
    (setq style (or (cadr (memq edoc-view-selection-style '(glyph word line)))
                    'glyph))
    (message "Setting selection style to `%s'." style))
  (edoc-view-deactivate-region)
  (setq-local edoc-view-selection-style style))


;; * ================================================================== *
;; * Bookmark + Register Integration
;; * ================================================================== *

(defun edoc-view-bookmark-make-record  (&optional no-page no-slice no-size no-origin)
  ;; TODO: add NO-PAGE, NO-SLICE, NO-SIZE, NO-ORIGIN to the docstring.
  "Create a bookmark PDF record.

The optional, boolean args exclude certain attributes."
  (let ((displayed-p (eq (current-buffer)
                         (window-buffer))))
    (cons (buffer-name)
          (append (bookmark-make-record-default nil t 1)
                  `(,(unless no-page
                       (cons 'page (edoc-view-current-page)))
                    ,(unless no-slice
                       (cons 'slice (and displayed-p
                                         (edoc-view-current-slice))))
                    ,(unless no-size
                       (cons 'size edoc-view-display-size))
                    ,(unless no-origin
                       (cons 'origin
                             (and displayed-p
                                  (let ((edges (edoc-util-image-displayed-edges nil t)))
                                    (edoc-util-scale-pixel-to-relative
                                     (cons (car edges) (cadr edges)) nil t)))))
                    (handler . edoc-view-bookmark-jump-handler))))))

;;;###autoload
(defun edoc-view-bookmark-jump-handler (bmk)
  "The bookmark handler-function interface for bookmark BMK.

See also `edoc-view-bookmark-make-record'."
  (let ((page (bookmark-prop-get bmk 'page))
        (slice (bookmark-prop-get bmk 'slice))
        (size (bookmark-prop-get bmk 'size))
        (origin (bookmark-prop-get bmk 'origin))
        (file (bookmark-prop-get bmk 'filename))
        (show-fn-sym (make-symbol "edoc-view-bookmark-after-jump-hook")))
    (fset show-fn-sym
          (lambda ()
            (remove-hook 'bookmark-after-jump-hook show-fn-sym)
            (unless (derived-mode-p 'edoc-view-mode)
              (edoc-view-mode))
            (with-selected-window
                (or (get-buffer-window (current-buffer) 0)
                    (selected-window))
              (when size
                (setq-local edoc-view-display-size size))
              (when slice
                (apply 'edoc-view-set-slice slice))
              (when (numberp page)
                (edoc-view-goto-page page))
              (when origin
                (let ((size (edoc-view-image-size t)))
                  (image-set-window-hscroll
                   (round (/ (* (car origin) (car size))
                             (frame-char-width))))
                  (image-set-window-vscroll
                   (round (/ (* (cdr origin) (cdr size))
                             (if edoc-view-have-image-mode-pixel-vscroll
                                 1
                               (frame-char-height))))))))))
    (add-hook 'bookmark-after-jump-hook show-fn-sym)
    (set-buffer (or (find-buffer-visiting file)
                    (find-file-noselect file)))))

(defun edoc-view-bookmark-jump (bmk)
  "Switch to bookmark BMK.

This function is like `bookmark-jump', but it always uses the
selected window for display and does not run any hooks.  Also, it
works only with bookmarks created by
`edoc-view-bookmark-make-record'."

  (let* ((file (bookmark-prop-get bmk 'filename))
         (buffer (or (find-buffer-visiting file)
                     (find-file-noselect file))))
    (switch-to-buffer buffer)
    (let (bookmark-after-jump-hook)
      (edoc-view-bookmark-jump-handler bmk)
      (run-hooks 'bookmark-after-jump-hook))))

(defun edoc-view-registerv-make ()
  "Create a PDF register entry of the current position."
  (registerv-make
   (edoc-view-bookmark-make-record nil t t)
   :print-func 'edoc-view-registerv-print-func
   :jump-func 'edoc-view-bookmark-jump
   :insert-func (lambda (bmk)
                  (insert (format "%S" bmk)))))

(defun edoc-view-registerv-print-func (bmk)
  "Print a textual representation of bookmark BMK.

This function is used as the `:print-func' property with
`registerv-make'."
  (let* ((file (bookmark-prop-get bmk 'filename))
         (buffer (find-buffer-visiting file))
         (page (bookmark-prop-get bmk 'page))
         (origin (bookmark-prop-get bmk 'origin)))
    (princ (format "PDF position: %s, page %d, %d%%"
                   (if buffer
                       (buffer-name buffer)
                     file)
                   (or page 1)
                   (if origin
                       (round (* 100 (cdr origin)))
                     0)))))

(defmacro edoc-view-with-register-alist (&rest body)
  "Setup the proper binding for `register-alist' in BODY.

This macro may not work as desired when it is nested.  See also
`edoc-view-use-dedicated-register'."
  (declare (debug t) (indent 0))
  (let ((dedicated-p (make-symbol "dedicated-p")))
    `(let* ((,dedicated-p edoc-view-use-dedicated-register)
            (register-alist
             (if ,dedicated-p
                 edoc-view-register-alist
               register-alist)))
       (unwind-protect
           (progn ,@body)
         (when ,dedicated-p
           (setq edoc-view-register-alist register-alist))))))

(defun edoc-view-position-to-register (register)
  "Store current PDF position in register REGISTER.

See also `point-to-register'."
  (interactive
   (list (edoc-view-with-register-alist
           (register-read-with-preview "Position to register: "))))
  (edoc-view-with-register-alist
    (set-register register (edoc-view-registerv-make))))

(defun edoc-view-jump-to-register (register &optional delete return-register)
  ;; TODO: add RETURN-REGISTER to the docstring.
  "Move point to a position stored in a REGISTER.

Optional parameter DELETE is defined as in `jump-to-register'."
  (interactive
   (edoc-view-with-register-alist
     (list
      (register-read-with-preview "Jump to register: ")
      current-prefix-arg
      (and (or edoc-view-use-dedicated-register
               (local-variable-p 'register-alist))
           (characterp last-command-event)
           last-command-event))))
  (edoc-view-with-register-alist
    (let ((return-pos (and return-register
                           (edoc-view-registerv-make))))
      (jump-to-register register delete)
      (when return-register
        (set-register return-register return-pos)))))

(provide 'edoc-view)

;;; edoc-view.el ends here
