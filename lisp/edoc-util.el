;;; edoc-util.el --- PDF Utility functions. -*- lexical-binding: t -*-

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
;;; Todo:
;;

;;; Code:

(require 'edoc-macs)
(require 'cl-lib)
(require 'format-spec)
(require 'faces)

;; These functions are only used after a PdfView window was asserted,
;; which won't succeed, if edoc-view.el isn't loaded.
(declare-function edoc-view-image-size "edoc-view")
(declare-function edoc-view-image-offset "edoc-view")
(declare-function edoc-cache-pagesize "edoc-cache")
(declare-function edoc-view-image-type "edoc-view")



;; * ================================================================== *
;; * Transforming coordinates
;; * ================================================================== *


(defun edoc-util-scale (list-of-edges-or-pos scale &optional rounding-fn)
  "Scale LIST-OF-EDGES-OR-POS by SCALE.

SCALE is a cons (SX . SY), by which edges/positions are scaled.
If ROUNDING-FN is non-nil, it should be a function of one
argument, a real value, returning a rounded
value (e.g. `ceiling').

The elements in LIST-OF-EDGES-OR-POS should be either a list
\(LEFT TOP RIGHT BOT\) or a position \(X . Y\).

LIST-OF-EDGES-OR-POS may also be a single such element.

Return scaled list of edges if LIST-OF-EDGES-OR-POS was indeed a list,
else return the scaled singleton."

  (let ((have-list-p (listp (car list-of-edges-or-pos))))
    (unless have-list-p
      (setq list-of-edges-or-pos (list list-of-edges-or-pos)))
    (let* ((sx (car scale))
           (sy (cdr scale))
           (result
            (mapcar
             (lambda (edges)
               (cond
                ((consp (cdr edges))
                 (let ((e (list (* (nth 0 edges) sx)
                                (* (nth 1 edges) sy)
                                (* (nth 2 edges) sx)
                                (* (nth 3 edges) sy))))
                   (if rounding-fn
                       (mapcar rounding-fn e)
                     e)))
                (rounding-fn
                 (cons (funcall rounding-fn (* (car edges) sx))
                       (funcall rounding-fn (* (cdr edges) sy))))
                (t
                 (cons (* (car edges) sx)
                       (* (cdr edges) sy)))))
             list-of-edges-or-pos)))
      (if have-list-p
          result
        (car result)))))

(defun edoc-util-scale-to (list-of-edges from to &optional rounding-fn)
  "Scale LIST-OF-EDGES in FROM basis to TO.

FROM and TO should both be a cons \(WIDTH . HEIGHT\).  See also
`edoc-util-scale'."

  (edoc-util-scale list-of-edges
                  (cons (/ (float (car to))
                           (float (car from)))
                        (/ (float (cdr to))
                           (float (cdr from))))
                  rounding-fn))

(defun edoc-util-scale-pixel-to-points (list-of-pixel-edges
                                       &optional rounding-fn displayed-p window)
  "Scale LIST-OF-PIXEL-EDGES to point values.

The result depends on the currently displayed page in WINDOW.
See also `edoc-util-scale'."
  (edoc-util-assert-edoc-window window)
  (edoc-util-scale-to
   list-of-pixel-edges
   (edoc-view-image-size displayed-p window)
   (edoc-cache-pagesize (edoc-view-current-page window))
   rounding-fn))

(defun edoc-util-scale-points-to-pixel (list-of-points-edges
                                       &optional rounding-fn displayed-p window)
  "Scale LIST-OF-POINTS-EDGES to point values.

The result depends on the currently displayed page in WINDOW.
See also `edoc-util-scale'."
  (edoc-util-assert-edoc-window window)
  (edoc-util-scale-to
   list-of-points-edges
   (edoc-cache-pagesize (edoc-view-current-page window))
   (edoc-view-image-size displayed-p window)
   rounding-fn))

(defun edoc-util-scale-relative-to-points (list-of-relative-edges
                                          &optional rounding-fn window)
  "Scale LIST-OF-RELATIVE-EDGES to point values.

The result depends on the currently displayed page in WINDOW.
See also `edoc-util-scale'."
  (edoc-util-assert-edoc-window window)
  (edoc-util-scale-to
   list-of-relative-edges
   '(1.0 . 1.0)
   (edoc-cache-pagesize (edoc-view-current-page window))
   rounding-fn))

(defun edoc-util-scale-points-to-relative (list-of-points-edges
                                          &optional rounding-fn window)
  "Scale LIST-OF-POINTS-EDGES to relative values.

See also `edoc-util-scale'."
  (edoc-util-assert-edoc-window window)
  (edoc-util-scale-to
   list-of-points-edges
   (edoc-cache-pagesize (edoc-view-current-page window))
   '(1.0 . 1.0)
   rounding-fn))

(defun edoc-util-scale-pixel-to-relative (list-of-pixel-edges
                                         &optional rounding-fn displayed-p window)
  "Scale LIST-OF-PIXEL-EDGES to relative values.

The result depends on the currently displayed page in WINDOW.
See also `edoc-util-scale'."
  (edoc-util-assert-edoc-window window)
  (edoc-util-scale-to
   list-of-pixel-edges
   (edoc-view-image-size displayed-p window)
   '(1.0 . 1.0)
   rounding-fn))


(defun edoc-util-scale-relative-to-pixel (list-of-relative-edges
                                         &optional rounding-fn displayed-p window)
  "Scale LIST-OF-EDGES to match SIZE.

The result depends on the currently displayed page in WINDOW.
See also `edoc-util-scale'."
  (edoc-util-assert-edoc-window window)
  (edoc-util-scale-to
   list-of-relative-edges
   '(1.0 . 1.0)
   (edoc-view-image-size displayed-p window)
   rounding-fn))

(defun edoc-util-translate (list-of-edges-or-pos
                           offset &optional opposite-direction-p)
  "Translate LIST-OF-EDGES-OR-POS by OFFSET

OFFSET should be a cons \(X . Y\), by which to translate
LIST-OF-EDGES-OR-POS.  If OPPOSITE-DIRECTION-P is non-nil
translate by \(-X . -Y\).

See `edoc-util-scale' for the LIST-OF-EDGES-OR-POS argument."

  (let ((have-list-p (listp (car list-of-edges-or-pos))))
    (unless have-list-p
      (setq list-of-edges-or-pos (list list-of-edges-or-pos)))
    (let* ((ox (if opposite-direction-p
                   (- (car offset))
                 (car offset)))
           (oy (if opposite-direction-p
                   (- (cdr offset))
                 (cdr offset)))
           (result
            (mapcar
             (lambda (edges)
               (cond
                ((consp (cdr edges))
                 (list (+ (nth 0 edges) ox)
                       (+ (nth 1 edges) oy)
                       (+ (nth 2 edges) ox)
                       (+ (nth 3 edges) oy)))
                (t
                 (cons (+ (car edges) ox)
                       (+ (cdr edges) oy)))))
             list-of-edges-or-pos)))
      (if have-list-p
          result
        (car result)))))

(defmacro edoc-util-with-edges (list-of-edges &rest body)
  "Provide some convenient macros for the edges in LIST-OF-EDGES.

LIST-OF-EDGES should be a list of variables \(X ...\), each one
holding a list of edges. Inside BODY the symbols X-left, X-top,
X-right, X-bot, X-width and X-height expand to their respective
values."

  (declare (indent 1) (debug (sexp &rest form)))
  (unless (cl-every 'symbolp list-of-edges)
    (error "Argument should be a list of symbols"))
  (let ((list-of-syms
         (mapcar (lambda (edge)
                   (cons edge (mapcar
                               (lambda (kind)
                                 (intern (format "%s-%s" edge kind)))
                               '(left top right bot width height))))
                 list-of-edges)))
    (macroexpand-all
     `(cl-symbol-macrolet
          ,(apply #'nconc
                  (mapcar
                   (lambda (edge-syms)
                     (let ((edge (nth 0 edge-syms))
                           (syms (cdr edge-syms)))
                       `((,(pop syms) (nth 0 ,edge))
                         (,(pop syms) (nth 1 ,edge))
                         (,(pop syms) (nth 2 ,edge))
                         (,(pop syms) (nth 3 ,edge))
                         (,(pop syms) (- (nth 2 ,edge)
                                         (nth 0 ,edge)))
                         (,(pop syms) (- (nth 3 ,edge)
                                         (nth 1 ,edge))))))
                   list-of-syms))
        ,@body))))

(defun edoc-util-edges-transform (region elts &optional to-region-p)
  "Translate ELTS according to REGION.

ELTS may be one edges list or a position or a list thereof.
Translate each from region coordinates to (0 0 1 1) or the
opposite, if TO-REGION-P is non-nil.  All coordinates should be
relative.

Returns the translated list of elements or the single one
depending on the input."

  (when elts
    (let ((have-list-p (consp (car-safe elts))))
      (unless have-list-p
        (setq elts (list elts)))
      (let ((result
             (if (null region)
                 elts
               (mapcar (lambda (edges)
                         (let ((have-pos-p (numberp (cdr edges))))
                           (when have-pos-p
                             (setq edges (list (car edges) (cdr edges)
                                               (car edges) (cdr edges))))
                           (edoc-util-with-edges (edges region)
                             (let ((newedges
                                    (mapcar (lambda (n)
                                              (min 1.0 (max 0.0 n)))
                                            (if to-region-p
                                                `(,(/ (- edges-left region-left)
                                                      region-width)
                                                  ,(/ (- edges-top region-top)
                                                      region-height)
                                                  ,(/ (- edges-right region-left)
                                                      region-width)
                                                  ,(/ (- edges-bot region-top)
                                                      region-height))
                                              `(,(+ (* edges-left region-width)
                                                    region-left)
                                                ,(+ (* edges-top region-height)
                                                    region-top)
                                                ,(+ (* edges-right region-width)
                                                    region-left)
                                                ,(+ (* edges-bot region-height)
                                                    region-top))))))
                               (if have-pos-p
                                   (cons (car newedges) (cadr newedges))
                                 newedges)))))
                       elts))))
        (if have-list-p
            result
          (car result))))))

;; * ================================================================== *
;; * Scrolling
;; * ================================================================== *

(defun edoc-util-image-displayed-edges (&optional window displayed-p)
  "Return the visible region of the image in WINDOW.

Returns a list of pixel edges."
  (edoc-util-assert-edoc-window)
  (let* ((edges (window-inside-pixel-edges window))
         (isize (edoc-view-image-size displayed-p window))
         (offset (if displayed-p
                     `(0 . 0)
                   (edoc-view-image-offset window)))
         (hscroll (* (window-hscroll window)
                     (frame-char-width (window-frame window))))
         (vscroll (window-vscroll window t))
         (x0 (+ hscroll (car offset)))
         (y0 (+ vscroll (cdr offset)))
         (x1 (min (car isize)
                  (+ x0 (- (nth 2 edges) (nth 0 edges)))))
         (y1 (min (cdr isize)
                  (+ y0 (- (nth 3 edges) (nth 1 edges))))))
    (mapcar #'round (list x0 y0 x1 y1))))

(defun edoc-util-required-hscroll (edges &optional eager-p context-pixel)
  "Return the amount of scrolling necessary, to make image EDGES visible.

Scroll as little as necessary.  Unless EAGER-P is non-nil, in
which case scroll as much as possible.

Keep CONTEXT-PIXEL pixel of the image visible at the bottom and
top of the window.  CONTEXT-PIXEL defaults to 0.

Return the required hscroll in columns or nil, if scrolling is not
needed."

  (edoc-util-assert-edoc-window)
  (unless context-pixel
    (setq context-pixel 0))
  (let* ((win (window-inside-pixel-edges))
         (image-width (car (edoc-view-image-size t)))
         (image-left (* (frame-char-width)
                        (window-hscroll)))
         (edges (edoc-util-translate
                 edges
                 (edoc-view-image-offset) t)))
    (edoc-util-with-edges (win edges)
      (let* ((edges-left (- edges-left context-pixel))
             (edges-right (+ edges-right context-pixel)))
        (if (< edges-left image-left)
            (round (/ (max 0 (if eager-p
                                 (- edges-right win-width)
                               edges-left))
                      (frame-char-width)))
          (if (> (min image-width
                      edges-right)
                 (+ image-left win-width))
              (round (/ (min (- image-width win-width)
                             (if eager-p
                                 edges-left
                               (- edges-right win-width)))
                        (frame-char-width)))))))))

(defun edoc-util-required-vscroll (edges &optional eager-p context-pixel)
  "Return the amount of scrolling necessary, to make image EDGES visible.

Scroll as little as necessary.  Unless EAGER-P is non-nil, in
which case scroll as much as possible.

Keep CONTEXT-PIXEL pixel of the image visible at the bottom and
top of the window.  CONTEXT-PIXEL defaults to an equivalent pixel
value of `next-screen-context-lines'.

Return the required vscroll in pixels or nil, if scrolling is not
needed.

Note: For versions of emacs before 27 this will return lines instead of
pixels. This is because of a change that occurred to `image-mode' in 27."
  (edoc-util-assert-edoc-window)
  (let* ((win (window-inside-pixel-edges))
         (image-height (cdr (edoc-view-image-size t)))
         (image-top (window-vscroll nil t))
         (edges (edoc-util-translate
                 edges
                 (edoc-view-image-offset) t)))
    (edoc-util-with-edges (win edges)
      (let* ((context-pixel (or context-pixel
                                (* next-screen-context-lines
                                   (frame-char-height))))
             ;;Be careful not to modify edges.
             (edges-top (- edges-top context-pixel))
             (edges-bot (+ edges-bot context-pixel))
             (vscroll
              (cond ((< edges-top image-top)
                     (max 0 (if eager-p
                                (- edges-bot win-height)
                              edges-top)))
                    ((> (min image-height
                             edges-bot)
                        (+ image-top win-height))
                     (min (- image-height win-height)
                          (if eager-p
                              edges-top
                            (- edges-bot win-height)))))))


        (when vscroll
          (round
           ;; `image-set-window-vscroll' changed in version 27 to using
           ;; pixels, not lines.
           (if (version< emacs-version "27")
               (/ vscroll (float (frame-char-height)))
               vscroll)))))))

(defun edoc-util-scroll-to-edges (edges &optional eager-p)
  "Scroll window such that image EDGES are visible.

Scroll as little as necessary.  Unless EAGER-P is non-nil, in
which case scroll as much as possible."

  (let ((vscroll (edoc-util-required-vscroll edges eager-p))
        (hscroll (edoc-util-required-hscroll edges eager-p)))
    (when vscroll
      (image-set-window-vscroll vscroll))
    (when hscroll
      (image-set-window-hscroll hscroll))))



;; * ================================================================== *
;; * Temporary files
;; * ================================================================== *

(defvar edoc-util--base-directory nil
  "Base directory for temporary files.")

(defvar-local edoc-util--dedicated-directory nil
  "The relative name of buffer's dedicated directory.")

(defun edoc-util-dedicated-directory ()
  "Return the name of a existing dedicated directory.

The directory is exclusive to the current buffer.  It will be
automatically deleted, if Emacs or the current buffer are
killed."
  (with-file-modes #o0700
    (unless (and edoc-util--base-directory
                 (file-directory-p
                  edoc-util--base-directory)
                 (not (file-symlink-p
                       edoc-util--base-directory)))
      (add-hook 'kill-emacs-hook
                (lambda nil
                  (when (and edoc-util--base-directory
                             (file-directory-p edoc-util--base-directory))
                    (delete-directory edoc-util--base-directory t))))
      (setq edoc-util--base-directory
            (make-temp-file "edoc-tools-" t)))
    (unless (and edoc-util--dedicated-directory
                 (file-directory-p edoc-util--dedicated-directory)
                 (not (file-symlink-p
                       edoc-util--base-directory)))
      (let ((temporary-file-directory
             edoc-util--base-directory))
        (setq edoc-util--dedicated-directory
              (make-temp-file (convert-standard-filename (edoc-util-temp-prefix))
                              t))
        (add-hook 'kill-buffer-hook #'edoc-util-delete-dedicated-directory
                  nil t)))
    edoc-util--dedicated-directory))

(defun edoc-util-delete-dedicated-directory ()
  "Delete current buffer's dedicated directory."
  (delete-directory (edoc-util-dedicated-directory) t))

(defun edoc-util-expand-file-name (name)
  "Expand filename against current buffer's dedicated directory."
  (expand-file-name name (edoc-util-dedicated-directory)))

(defun edoc-util-temp-prefix ()
  "Create a temp-file prefix for the current buffer"
  (concat (if buffer-file-name
              (file-name-nondirectory buffer-file-name)
            (replace-regexp-in-string "[^[:alnum:]]+" "-" (buffer-name)))
          "-"))

(defun edoc-util-make-temp-file (&optional prefix dir-flag suffix)
  "Create a temporary file in current buffer's dedicated directory.

See `make-temp-file' for the arguments."
  (let ((temporary-file-directory (edoc-util-dedicated-directory)))
    (make-temp-file (convert-standard-filename
                     (or prefix (edoc-util-temp-prefix)))
                    dir-flag suffix)))


;; * ================================================================== *
;; * Various
;; * ================================================================== *

(defmacro edoc-util-debug (&rest body)
  "Execute BODY only if debugging is enabled."
  (declare (indent 0) (debug t))
  `(when (bound-and-true-p edoc-tools-debug)
     ,@body))

(defun edoc-util-edoc-buffer-p (&optional buffer)
  (and (or (null buffer)
           (buffer-live-p buffer))
       (save-current-buffer
         (and buffer (set-buffer buffer))
         (derived-mode-p 'edoc-view-mode))))

(defun edoc-util-assert-edoc-buffer (&optional buffer)
  (unless (edoc-util-edoc-buffer-p buffer)
    (error "Buffer is not in PDFView mode")))

(defun edoc-util-edoc-window-p (&optional window)
  (unless (or (null window)
              (window-live-p window))
    (signal 'wrong-type-argument (list 'window-live-p window)))
  (unless window (setq window (selected-window)))
  (and (window-live-p window)
       (with-selected-window window
         (edoc-util-edoc-buffer-p))))

(defun edoc-util-assert-edoc-window (&optional window)
  (unless (edoc-util-edoc-window-p window)
    (error "Window's buffer is not in PdfView mode")))

(defun edoc-util-munch-file (filename &optional multibyte-p)
  "Read contents from FILENAME and delete it.

Return the file's content as a unibyte string, unless MULTIBYTE-P
is non-nil."
  (unwind-protect
      (with-temp-buffer
        (set-buffer-multibyte multibyte-p)
        (insert-file-contents-literally filename)
        (buffer-substring-no-properties
         (point-min)
         (point-max)))
    (when (and filename
               (file-exists-p filename))
      (delete-file filename))))

(defun edoc-util-hexcolor (color)
  "Return COLOR in hex-format.

Signal an error, if color is invalid."
  (if (string-match "\\`#[[:xdigit:]]\\{6\\}\\'" color)
      color
    (let ((values (color-values color)))
      (unless values
        (signal 'wrong-type-argument (list 'color-defined-p color)))
      (apply #'format "#%02x%02x%02x"
             (mapcar (lambda (c) (ash c -8))
                     values)))))

(defun edoc-util-highlight-regexp-in-string (regexp string &optional face)
  "Highlight all occurrences of REGEXP in STRING using FACE.

FACE defaults to the `match' face.  Returns the new fontified
string."
  (with-temp-buffer
    (save-excursion (insert string))
    (while (and (not (eobp))
                (re-search-forward regexp nil t))
      (if (= (match-beginning 0)
             (match-end 0))
          (forward-char)
        (put-text-property
         (match-beginning 0)
         (point)
         'face (or face 'match))))
    (buffer-string)))

(autoload 'list-colors-duplicates "facemenu")

(defun edoc-util-color-completions ()
  "Return a fontified list of defined colors."
  (let ((color-list (list-colors-duplicates))
        colors)
    (dolist (cl color-list)
      (dolist (c (reverse cl))
        (push (propertize c 'face `(:background ,c))
              colors)))
    (nreverse colors)))

(defun edoc-util-tooltip-in-window (text x y &optional window)
  (let* ((we (window-inside-absolute-pixel-edges window))
         (dx (round (+ x (nth 0 we))))
         (dy (round (+ y (nth 1 we))))
         (tooltip-frame-parameters
          `((left . ,dx)
            (top . ,dy)
            ,@tooltip-frame-parameters)))
    (tooltip-show text)))

;; FIXME: Defined in `edoc-view' but we can't require it here because it
;; requires us :-(
(defvar edoc-view-midnight-colors)

(when (and (> emacs-major-version 28)
           (not (boundp 'x-gtk-use-system-tooltips)))
  ;; The x-gtk prefix has been dropped Emacs 29
  (defvaralias 'x-gtk-use-system-tooltips 'use-system-tooltips))

(defun edoc-util-tooltip-arrow (image-top &optional timeout)
  (edoc-util-assert-edoc-window)
  (when (floatp image-top)
    (setq image-top
          (round (* image-top (cdr (edoc-view-image-size))))))
  (let* ((x-gtk-use-system-tooltips nil)
         ;; ^ allow for display text property in tooltip
         (dx (+ (or (car (window-margins)) 0)
                (car (window-fringes))))
         (dy image-top)
         (pos (list dx dy dx (+ dy (* 2 (frame-char-height)))))
         (vscroll
          (edoc-util-required-vscroll pos))
         (tooltip-frame-parameters
          `((border-width . 0)
            (internal-border-width . 0)
            ,@tooltip-frame-parameters))
         (tooltip-hide-delay (or timeout 3)))
    (when vscroll
      (image-set-window-vscroll vscroll))
    (setq dy (max 0 (- dy
                       (cdr (edoc-view-image-offset))
                       (window-vscroll nil t)
                       (frame-char-height))))
    (when (overlay-get (edoc-view-current-overlay) 'before-string)
      (let* ((e (window-inside-pixel-edges))
             (xw (edoc-util-with-edges (e) e-width)))
        (cl-incf dx (/ (- xw (car (edoc-view-image-size t))) 2))))
    (edoc-util-tooltip-in-window
     (propertize
      " " 'display (propertize
                    "\u2192" ;;right arrow
                    'display '(height 2)
                    'face `(:foreground
                            "orange red"
                            :background
                            ,(cond
                              ((bound-and-true-p edoc-view-midnight-minor-mode)
                               (cdr edoc-view-midnight-colors))
                              ((bound-and-true-p edoc-view-themed-minor-mode)
                               (face-background 'default nil))
                              (t "white")))))
     dx dy)))

(defvar edoc-util--face-colors-cache (make-hash-table))

(advice-add 'enable-theme :after #'edoc-util--clear-faces-cache)
(defun edoc-util--clear-faces-cache (&rest _)
  (clrhash edoc-util--face-colors-cache))

(defun edoc-util-face-colors (face &optional dark-p)
  "Return both colors of FACE as a cons.

Look also in inherited faces.  If DARK-P is non-nil, return dark
colors, otherwise light."
  (let* ((bg (if dark-p 'dark 'light))
         (spec (list (get face 'face-defface-spec)
                     (get face 'theme-face)
                     (get face 'customized-face)))
         (cached (gethash face edoc-util--face-colors-cache)))
    (cl-destructuring-bind (&optional cspec color-alist)
        cached
      (or (and color-alist
               (equal cspec spec)
               (cdr (assq bg color-alist)))
          (let* ((this-bg (frame-parameter nil 'background-mode))
                 (frame-background-mode bg)
                 (f (and (not (eq bg this-bg))
                         (x-create-frame-with-faces '((visibility . nil))))))
            (with-selected-frame (or f (selected-frame))
              (unwind-protect
                  (let ((colors
                         (cons (face-attribute face :foreground nil 'default)
                               (face-attribute face :background nil 'default))))
                    (puthash face `(,(mapcar #'copy-sequence spec)
                                    ((,bg . ,colors) ,@color-alist))
                             edoc-util--face-colors-cache)
                    colors)
                (when (and f (frame-live-p f))
                  (delete-frame f)))))))))

(defun edoc-util-window-attach (awindow &optional window)
  "Attach AWINDOW to WINDOW.

This has the following effect.  Whenever WINDOW, defaulting to
the selected window, stops displaying the buffer it currently
displays (e.g., by switching buffers or because it was deleted)
AWINDOW is deleted."
  (unless window (setq window (selected-window)))
  (let ((buffer (window-buffer window))
        (hook (make-symbol "window-attach-hook")))
    (fset hook
          (lambda ()
            (when (or (not (window-live-p window))
                      (not (eq buffer (window-buffer window))))
              (remove-hook 'window-configuration-change-hook
                           hook)
              ;; Deleting windows inside wcch may cause errors in
              ;; windows.el .
              (run-with-timer
               0 nil (lambda (win)
                       (when (and (window-live-p win)
                                  (not (eq win (selected-window))))
                         (delete-window win)))
               awindow))))
    (add-hook 'window-configuration-change-hook hook)))

(defun display-buffer-split-below-and-attach (buf alist)
  "Display buffer action using `edoc-util-window-attach'."
  (let ((window (selected-window))
        (height (cdr (assq 'window-height alist)))
        newwin)
    (when height
      (when (floatp height)
        (setq height (round (* height (frame-height)))))
      (setq height (- (max height window-min-height))))
    (setq newwin (window--display-buffer
                  buf
                  (split-window-below height)
                  'window alist))
    (edoc-util-window-attach newwin window)
    newwin))

(defun edoc-util-goto-position (line &optional column)
  "Goto LINE and COLUMN in the current buffer.

COLUMN defaults to 0.  Widen the buffer, if the position is
outside the current limits."
  (let ((pos
         (when (> line 0)
           (save-excursion
             (save-restriction
               (widen)
               (goto-char 1)
               (when (= 0 (forward-line (1- line)))
                 (when (and column (> column 0))
                   (forward-char (1- column)))
                 (point)))))))
    (when pos
      (when (or (< pos (point-min))
                (> pos (point-max)))
        (widen))
      (goto-char pos))))

(defun edoc-util-seq-alignment (seq1 seq2 &optional similarity-fn alignment-type)
  "Return an alignment of sequences SEQ1 and SEQ2.

SIMILARITY-FN should be a function. It is called with two
arguments: One element from SEQ1 and one from SEQ2.  It should
return a number determining how similar the elements are, where
higher values mean `more similar'.  The default returns 1 if the
elements are equal, else -1.

ALIGNMENT-TYPE may be one of the symbols `prefix', `suffix',
`infix' or nil.  If it is `prefix', trailing elements in SEQ2 may
be ignored. For example the alignment of

\(0 1\) and \(0 1 2\)

using prefix matching is 0, since the prefixes are equal and the
trailing 2 is ignored.  The other possible values have similar
effects.  The default is nil, which means to match the whole
sequences.

Return a cons \(VALUE . ALIGNMENT\), where VALUE says how similar
the sequences are and ALIGNMENT is a list of \(E1 . E2\), where
E1 is an element from SEQ1 or nil, likewise for E2.  If one of
them is nil, it means there is gap at this position in the
respective sequence."

  (cl-macrolet ((make-matrix (rows columns)
                  `(apply #'vector
                          (cl-loop for i from 1 to ,rows
                                   collect (make-vector ,columns nil))))
                (mset (matrix row column newelt)
                  `(aset (aref ,matrix ,row) ,column ,newelt))
                (mref (matrix row column)
                  `(aref (aref ,matrix ,row) ,column)))
    (let* ((len1 (length seq1))
           (len2 (length seq2))
           (d (make-matrix (1+ len1) (1+ len2)))
           (prefix-p (memq alignment-type '(prefix infix)))
           (suffix-p (memq alignment-type '(suffix infix)))
           (similarity-fn (or similarity-fn
                              (lambda (a b)
                                (if (equal a b) 1 -1)))))

      (cl-loop for i from 0 to len1 do
        (mset d i 0 (- i)))
      (cl-loop for j from 0 to len2 do
        (mset d 0 j (if suffix-p 0 (- j))))

      (cl-loop for i from 1 to len1 do
        (cl-loop for j from 1 to len2 do
          (let ((max (max
                      (1- (mref d (1- i) j))
                      (+ (mref d i (1- j))
                         (if (and prefix-p (= i len1)) 0 -1))
                      (+ (mref d (1- i) (1- j))
                         (funcall similarity-fn
                                  (elt seq1 (1- i))
                                  (elt seq2 (1- j)))))))
            (mset d i j max))))

      (let ((i len1)
            (j len2)
            alignment)
        (while (or (> i 0)
                   (> j 0))
          (cond
           ((and (> i 0)
                 (= (mref d i j)
                    (1- (mref d (1- i) j))))
            (cl-decf i)
            (push (cons (elt seq1 i) nil) alignment))
           ((and (> j 0)
                 (= (mref d i j)
                    (+ (mref d i (1- j))
                       (if (or (and (= i 0) suffix-p)
                               (and (= i len1) prefix-p))
                           0 -1))))
            (cl-decf j)
            (push (cons nil (elt seq2 j)) alignment))
           (t
            (cl-assert (and (> i 0) (> j 0)) t)
            (cl-decf i)
            (cl-decf j)
            (push (cons (elt seq1 i)
                        (elt seq2 j))
                  alignment))))
        (cons (mref d len1 len2) alignment)))))


(defun edoc-util-pcre-quote (string)
  "Escape STRING for use as a PCRE.

See also `regexp-quote'."

  (let ((to-escape
         (eval-when-compile (append "\0\\|()[]{}^$*+?." nil)))
        (chars (append string nil))
        escaped)
    (dolist (ch chars)
      (when (memq ch to-escape)
        (push ?\\ escaped))
      (push ch escaped))
    (apply #'string (nreverse escaped))))

(defun edoc-util-frame-ppi ()
  "Return the PPI of the current frame."
  (condition-case nil
      (let* ((props (frame-monitor-attributes))
             (px (nthcdr 2 (alist-get 'geometry props)))
             (mm (alist-get 'mm-size props))
             (dp (sqrt (+ (expt (nth 0 px) 2)
                          (expt (nth 1 px) 2))))
             (di (sqrt (+ (expt (/ (nth 0 mm) 25.4) 2)
                          (expt (/ (nth 1 mm) 25.4) 2)))))
        (/ dp di))
    ;; Calculating frame-ppi failed, return 0 to indicate unknown.
    ;; This can happen when (frame-monitor-attributes) does not have
    ;; the right properties (Emacs 26, 27). It leads to the
    ;; wrong-type-argument error, which is the only one we are
    ;; catching here. We will catch more errors only if we see them
    ;; happening.
    (wrong-type-argument 0)))

(defvar edoc-view-use-scaling)

(defun edoc-util-frame-scale-factor ()
  "Return the frame scale factor depending on the image type used for display.
When `edoc-view-use-scaling' is non-nil, return the scale factor of the frame
if available. If the scale factor isn't available, return 2 if the
frame's PPI is larger than 180. Otherwise, return 1."
  (if edoc-view-use-scaling
      (or (and (fboundp 'frame-scale-factor)
               (truncate (frame-scale-factor)))
          (and (fboundp 'frame-monitor-attributes)
               (cdr (assq 'backing-scale-factor (frame-monitor-attributes))))
          (if (>= (edoc-util-frame-ppi) 180)
              2
            1))
    1))


;; * ================================================================== *
;; * Imagemagick's convert
;; * ================================================================== *

(defcustom edoc-util-convert-program
  ;; Avoid using the MS Windows command convert.exe .
  (unless (memq system-type '(ms-dos windows-nt))
    (executable-find "convert"))
  "Absolute path to the convert program."
  :group 'edoc-tools
  :type '(choice (const :tag "Unset" nil) file))

(defcustom edoc-util-fast-image-format nil
  "An image format appropriate for fast displaying.

This should be a cons (TYPE . EXT) where type is the Emacs
`image-type' and EXT the appropriate file extension starting with
a dot.  If nil, the value is determined automatically.

Different formats have different properties, with respect to
Emacs loading time, convert creation time and the file-size.  In
general, uncompressed formats are faster, but may need a fair
amount of (temporary) disk space."
  :group 'edoc-tools
  :type '(choice
          (const :tag "Determine automatically" nil)
          (cons symbol string)))

(defun edoc-util-assert-convert-program ()
  (unless (and edoc-util-convert-program
               (file-executable-p edoc-util-convert-program))
    (error "The edoc-util-convert-program is unset or non-executable")))

(defun edoc-util-image-file-size (image-file)
  "Determine the size of the image in IMAGE-FILE.

Returns a cons \(WIDTH . HEIGHT\)."
  (edoc-util-assert-convert-program)
  (with-temp-buffer
    (when (save-excursion
            (= 0 (call-process
                  edoc-util-convert-program
                  nil (current-buffer) nil
                  image-file "-format" "%w %h" "info:")))
      (let ((standard-input (current-buffer)))
        (cons (read) (read))))))

(defun edoc-util-convert (in-file out-file &rest spec)
  "Convert image IN-FILE to OUT-FILE according to SPEC.

IN-FILE should be the name of a file containing an image.  Write
the result to OUT-FILE.  The extension of this filename usually
determines the resulting image-type.

SPEC is a property list, specifying what the convert program
should do with the image.  All manipulations operate on a
rectangle, see below.

SPEC may contain the following keys, respectively values.

`:foreground' Set foreground color for all following operations.

`:background' Dito, for the background color.

`:commands' A list of strings representing arguments to convert
for image manipulations.  It may contain %-escape characters, as
follows.

%f -- Expands to the foreground color.
%b -- Expands to the background color.
%g -- Expands to the geometry of the current rectangle, i.e. WxH+X+Y.
%x -- Expands to the left edge of rectangle.
%X -- Expands to the right edge of rectangle.
%y -- Expands to the top edge of rectangle.
%Y -- Expands to the bottom edge of rectangle.
%w -- Expands to the width of rectangle.
%h -- Expands to the height of rectangle.

Keep in mind, that every element of this list is seen by convert
as a single argument.

`:formats' An alist of additional %-escapes.  Every element
should be a cons \(CHAR . STRING\) or \(CHAR . FUNCTION\).  In
the first case, all occurrences of %-CHAR in the above commands
will be replaced by STRING.  In the second case FUNCTION is
called with the current rectangle and it should return the
replacement string.

`:apply' A list of rectangles \(\(LEFT TOP RIGHT BOT\) ...\) in
IN-FILE coordinates. Each such rectangle triggers one execution
of the last commands given earlier in SPEC. E.g. a call like

  (edoc-util-convert
   image-file out-file
   :foreground \"black\"
   :background \"white\"
   :commands \\='(\"-fill\" \"%f\" \"-draw\" \"rectangle %x,%y,%X,%Y\")
   :apply \\='((0 0 10 10) (10 10 20 20))
   :commands \\='(\"-fill\" \"%b\" \"-draw\" \"rectangle %x,%y,%X,%Y\")
   :apply \\='((10 0 20 10) (0 10 10 20)))

would draw a 4x4 checkerboard pattern in the left corner of the
image, while leaving the rest of it as it was.

Returns OUT-FILE.

See url `http://www.imagemagick.org/script/convert.php'."
  (edoc-util-assert-convert-program)
  (let* ((cmds (edoc-util-convert--create-commands spec))
         (status (apply #'call-process
                        edoc-util-convert-program nil
                        (get-buffer-create "*edoc-util-convert-output*")
                        nil
                        `(,in-file ,@cmds ,out-file))))
    (unless (and (numberp status) (= 0 status))
      (error "The convert program exited with error status: %s" status))
    out-file))

(defun edoc-util-convert-asynch (in-file out-file &rest spec-and-callback)
  "Like `edoc-util-convert', but asynchronous.

If the last argument is a function, it is installed as the
process sentinel.

Returns the convert process."
  (edoc-util-assert-convert-program)
  (let ((callback (car (last spec-and-callback)))
        spec)
    (if (functionp callback)
        (setq spec (butlast spec-and-callback))
      (setq spec spec-and-callback
            callback nil))
    (let* ((cmds (edoc-util-convert--create-commands spec))
           (proc
            (apply #'start-process "edoc-util-convert"
                   (get-buffer-create "*edoc-util-convert-output*")
                   edoc-util-convert-program
                   `(,in-file ,@cmds ,out-file))))
      (when callback
        (set-process-sentinel proc callback))
      proc)))

(defun edoc-util-convert-page (&rest specs)
  "Convert image of current page according to SPECS.

Return the converted PNG image as a string.  See also
`edoc-util-convert'."

  (edoc-util-assert-edoc-window)
  (let ((in-file (make-temp-file "edoc-util-convert" nil ".png"))
        (out-file (make-temp-file "edoc-util-convert" nil ".png")))
    (unwind-protect
        (let ((image-data
               (plist-get (cdr (edoc-view-current-image)) :data)))
          (with-temp-file in-file
            (set-buffer-multibyte nil)
            (set-buffer-file-coding-system 'binary)
            (insert image-data))
          (edoc-util-munch-file
           (apply #'edoc-util-convert
                  in-file out-file specs)))
      (when (file-exists-p in-file)
        (delete-file in-file))
      (when (file-exists-p out-file)
        (delete-file out-file)))))


(defun edoc-util-convert--create-commands (spec)
  (let ((fg "red")
        (bg "red")
        formats result cmds s)
    (while (setq s (pop spec))
      (unless spec
        (error "Missing value in convert spec:%s" (cons s spec)))
      (cl-case s
        (:foreground
         (setq fg (pop spec)))
        (:background
         (setq bg (pop spec)))
        (:commands
         (setq cmds (pop spec)))
        (:formats
         (setq formats (append formats (pop spec) nil)))
        (:apply
         (dolist (m (pop spec))
           (edoc-util-with-edges (m)
             (let ((alist (append
                           (mapcar (lambda (f)
                                     (cons (car f)
                                           (if (stringp (cdr f))
                                               (cdr f)
                                             (funcall (cdr f) m))))
                                   formats)
                           `((?g . ,(format "%dx%d+%d+%d"
                                            m-width m-height
                                            m-left m-top))
                             (?x . ,m-left)
                             (?X . ,m-right)
                             (?y . ,m-top)
                             (?Y . ,m-bot)
                             (?w . ,(- m-right m-left))
                             (?h . ,(- m-bot m-top))
                             (?f . ,fg)
                             (?b . ,bg)))))
               (dolist (fmt cmds)
                 (push (format-spec fmt alist) result))))))))
    (nreverse result)))

;; FIXME: Check code below and document.

(defun edoc-util-edges-p (obj &optional relative-p)
  "Return non-nil, if OBJ look like edges.

If RELATIVE-P is non-nil, also check that all values <= 1."

  (and (consp obj)
       (ignore-errors (= 4 (length obj)))
       (cl-every (lambda (x)
                   (and (numberp x)
                        (>= x 0)
                        (or (null relative-p)
                            (<= x 1))))
                 obj)))

(defun edoc-util-edges-empty-p (edges)
  "Return non-nil, if EDGES area is empty."
  (edoc-util-with-edges (edges)
    (or (<= edges-width 0)
        (<= edges-height 0))))

(defun edoc-util-edges-inside-p (edges pos &optional epsilon)
  (edoc-util-edges-contained-p
   edges
   (list (car pos) (cdr pos) (car pos) (cdr pos))
   epsilon))

(defun edoc-util-edges-contained-p (edges contained &optional epsilon)
  (unless epsilon (setq epsilon 0))
  (edoc-util-with-edges (edges contained)
    (and (<= (- edges-left epsilon)
             contained-left)
         (>= (+ edges-right epsilon)
             contained-right)
         (<= (- edges-top epsilon)
             contained-top)
         (>= (+ edges-bot epsilon)
             contained-bot))))

(defun edoc-util-edges-intersection (e1 e2)
  (edoc-util-with-edges (edges1 e1 e2)
    (let ((left (max e1-left e2-left))
          (top (max e1-top e2-top))
          (right (min e1-right e2-right))
          (bot (min e1-bot e2-bot)))
      (when (and (<= left right)
                 (<= top bot))
        (list left top right bot)))))

(defun edoc-util-edges-union (&rest edges)
  (if (null (cdr edges))
      (car edges)
    (list (apply #'min (mapcar #'car edges))
          (apply #'min (mapcar #'cadr edges))
          (apply #'max (mapcar #'cl-caddr edges))
          (apply #'max (mapcar #'cl-cadddr edges)))))

(defun edoc-util-edges-intersection-area (e1 e2)
  (let ((inters (edoc-util-edges-intersection e1 e2)))
    (if (null inters)
        0
      (edoc-util-with-edges (inters)
        (* inters-width inters-height)))))

(defun edoc-util-read-image-position (prompt)
  "Read a image position using prompt.

Return the event position object."
  (save-selected-window
    (let ((ev (edoc-util-read-click-event
               (propertize prompt 'face 'minibuffer-prompt)))
          (buffer (current-buffer)))
      (unless (mouse-event-p ev)
        (error "Not a mouse event"))
      (let ((posn (event-start ev)))
        (unless (and (eq (window-buffer
                          (posn-window posn))
                         buffer)
                     (eq 'image (car-safe (posn-object posn))))
          (error "Invalid image position"))
        posn))))

(defun edoc-util-read-click-event (&optional prompt seconds)
  (let ((down (read-event prompt seconds)))
    (unless (and (mouse-event-p down)
                 (equal (event-modifiers down)
                        '(down)))
      (error "No a mouse click event"))
    (let ((up (read-event prompt seconds)))
      (unless (and (mouse-event-p up)
                   (equal (event-modifiers up)
                          '(click)))
        (error "No a mouse click event"))
      up)))

(defun edoc-util-image-map-mouse-event-proxy (event)
  "Set POS-OR-AREA in EVENT to 1 and unread it."
  (interactive "e")
  (setcar (cdr (cadr event)) 1)
  (setq unread-command-events (list event)))

(defun edoc-util-image-map-divert-mouse-clicks (id &optional buttons)
  (dolist (kind '("" "down-" "drag-"))
    (dolist (b (or buttons '(2 3 4 5 6)))
      (local-set-key
       (vector id (intern (format "%smouse-%d" kind b)))
       'edoc-util-image-map-mouse-event-proxy))))

(defmacro edoc-util-do-events (event-resolution-unread-p condition &rest body)
  "Read EVENTs while CONDITION executing BODY.

Process at most 1/RESOLUTION events per second.  If UNREAD-p is
non-nil, unread the final non-processed event.

\(FN (EVENT RESOLUTION &optional UNREAD-p) CONDITION &rest BODY\)"
  (declare (indent 2) (debug ((symbolp form &optional form) form body)))
  (cl-destructuring-bind (event resolution &optional unread-p)
      event-resolution-unread-p
    (let ((*seconds (make-symbol "seconds"))
          (*timestamp (make-symbol "timestamp"))
          (*clock (make-symbol "clock"))
          (*unread-p (make-symbol "unread-p"))
          (*resolution (make-symbol "resolution")))
      `(let* ((,*unread-p ,unread-p)
              (,*resolution ,resolution)
              (,*seconds 0)
              (,*timestamp (float-time))
              (,*clock (lambda (&optional secs)
                         (when secs
                           (setq ,*seconds secs
                                 ,*timestamp (float-time)))
                         (- (+ ,*timestamp ,*seconds)
                            (float-time))))
              (,event (read-event)))
         (while ,condition
           (when (<= (funcall ,*clock) 0)
             (progn ,@body)
             (setq ,event nil)
             (funcall ,*clock ,*resolution))
           (setq ,event
                 (or (read-event nil nil
                                 (and ,event
                                      (max 0 (funcall ,*clock))))
                     ,event)))
         (when (and ,*unread-p ,event)
           (setq unread-command-events
                 (append unread-command-events
                         (list ,event))))))))

(defmacro edoc-util-track-mouse-dragging (event-resolution &rest body)
  "Read mouse movement events executing BODY.

See also `edoc-util-do-events'.

This macro should be used inside a command bound to a down-mouse
event.  It evaluates to t, if at least one event was processed in
BODY, otherwise nil.  In the latter case, the only event (usually
a mouse click event) is unread.

\(FN (EVENT RESOLUTION) &rest BODY\)"
  (declare (indent 1) (debug ((symbolp form) body)))
  (let ((ran-once-p (make-symbol "ran-once-p")))
    `(let (,ran-once-p)
       (track-mouse
         (edoc-util-do-events (,@event-resolution t)
             (mouse-movement-p ,(car event-resolution))
           (setq ,ran-once-p t)
           ,@body))
       (when (and ,ran-once-p
                  unread-command-events)
         (setq unread-command-events
               (butlast unread-command-events)))
       ,ran-once-p)))

(defun edoc-util-remove-duplicates (list)
  "Remove duplicates from LIST stably using `equal'."
  (let ((ht (make-hash-table :test 'equal))
        result)
    (dolist (elt list (nreverse result))
      (unless (gethash elt ht)
        (push elt result)
        (puthash elt t ht)))))

(provide 'edoc-util)

;;; edoc-util.el ends here
