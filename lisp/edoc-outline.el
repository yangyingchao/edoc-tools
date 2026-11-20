;;; edoc-outline.el --- Outline for PDF buffer -*- lexical-binding: t -*-

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

(require 'outline)
(require 'edoc-links)
(require 'edoc-view)
(require 'edoc-util)
(require 'cl-lib)
(require 'imenu)
(require 'let-alist)

;;; Code:

;;
;; User options
;;

(defgroup edoc-outline nil
  "Display a navigatable outline of a PDF document."
  :group 'edoc-tools)

(defcustom edoc-outline-buffer-indent 2
  "The level of indent in the Outline buffer."
  :type 'integer)

(defcustom edoc-outline-enable-imenu t
  "Whether `imenu' should be enabled in PDF documents."
  :type '(choice (const :tag "Yes" t)
                 (const :tag "No" nil)))

(defcustom edoc-outline-imenu-keep-order t
  "Whether `imenu' should be advised not to reorder the outline."
  :type '(choice (const :tag "Yes" t)
                 (const :tag "No" nil)))

(defcustom edoc-outline-imenu-use-flat-menus nil
  "Whether the constructed Imenu should be a list, rather than a tree."
  :type '(choice (const :tag "Yes" t)
                 (const :tag "No" nil)))

(defcustom edoc-outline-display-buffer-action '(nil . nil)
  "The display action used, when displaying the outline buffer."
  :type display-buffer--action-custom-type)

(defcustom edoc-outline-display-labels nil
  "Whether the outline should display labels instead of page numbers.

Usually a page's label is its displayed page number."
  :type 'boolean)

(defcustom edoc-outline-fill-column fill-column
  "The value of `fill-column' in pdf outline buffers.

Set to nil to disable line wrapping."
  :type 'integer)

(defvar edoc-outline-minor-mode-map
  (let ((km (make-sparse-keymap)))
    (define-key km (kbd "o") #'edoc-outline)
    km)
  "Keymap used for `edoc-outline-minor-mode'.")

(defvar edoc-outline-buffer-mode-map
  (let ((kmap (make-sparse-keymap)))
    (dotimes (i 10)
      (define-key kmap (vector (+ i ?0)) #'digit-argument))
    (define-key kmap "-" #'negative-argument)
    (define-key kmap (kbd "p") #'previous-line)
    (define-key kmap (kbd "n") #'next-line)
    (define-key kmap (kbd "b") #'outline-backward-same-level)
    (define-key kmap (kbd "d") #'outline-hide-subtree)
    (define-key kmap (kbd "a") #'outline-show-all)
    (define-key kmap (kbd "s") #'outline-show-subtree)
    (define-key kmap (kbd "f") #'outline-forward-same-level)
    (define-key kmap (kbd "u") #'edoc-outline-up-heading)
    (define-key kmap (kbd "Q") #'outline-hide-sublevels)
    (define-key kmap (kbd "<") #'beginning-of-buffer)
    (define-key kmap (kbd ">") #'edoc-outline-end-of-buffer)
    (define-key kmap (kbd "TAB") #'outline-toggle-children)
    (define-key kmap (kbd "RET") #'edoc-outline-follow-link)
    (define-key kmap (kbd "C-o") #'edoc-outline-display-link)
    (define-key kmap (kbd "SPC") #'edoc-outline-display-link)
    (define-key kmap [mouse-1] #'edoc-outline-mouse-display-link)
    (define-key kmap (kbd "o") #'edoc-outline-select-edoc-window)
    (define-key kmap (kbd ".") #'edoc-outline-move-to-current-page)
    ;; (define-key kmap (kbd "Q") #'edoc-outline-quit)
    (define-key kmap (kbd "C-c C-q") #'edoc-outline-quit-and-kill)
    (define-key kmap (kbd "q") #'quit-window)
    (define-key kmap (kbd "M-RET") #'edoc-outline-follow-link-and-quit)
    (define-key kmap (kbd "C-c C-f") #'edoc-outline-follow-mode)
    kmap)
  "Keymap used in `edoc-outline-buffer-mode'.")

;;
;; Internal Variables
;;

(define-button-type 'edoc-outline
  'face nil
  'keymap nil)

(defvar-local edoc-outline-edoc-window nil
  "The PDF window corresponding to this outline buffer.")

(defvar-local edoc-outline-edoc-document nil
  "The PDF filename or buffer corresponding to this outline
  buffer.")

(defvar-local edoc-outline-follow-mode-last-link nil)

;;
;; Functions
;;

;;;###autoload
(define-minor-mode edoc-outline-minor-mode
  "Display an outline of a PDF document.

This provides a PDF's outline on the menu bar via imenu.
Additionally the same outline may be viewed in a designated
buffer.

\\{edoc-outline-minor-mode-map}"
  :group 'edoc-outline
  (edoc-util-assert-edoc-buffer)
  (cond
   (edoc-outline-minor-mode
    (when edoc-outline-enable-imenu
      (edoc-outline-imenu-enable)))
   (t
    (when edoc-outline-enable-imenu
      (edoc-outline-imenu-disable)))))

(define-derived-mode edoc-outline-buffer-mode outline-mode "PDF Outline"
  "View and traverse the outline of a PDF file.

Press \\[edoc-outline-display-link] to display the PDF document,
\\[edoc-outline-select-edoc-window] to select its window,
\\[edoc-outline-move-to-current-page] to move to the outline item
of the current page, \\[edoc-outline-follow-link] to goto the
corresponding page or \\[edoc-outline-follow-link-and-quit] to
additionally quit the Outline.

\\[edoc-outline-follow-mode] enters a variant of
`next-error-follow-mode'.  Most `outline-mode' commands are
rebound to their respective last character.

\\{edoc-outline-buffer-mode-map}"
  (setq-local outline-regexp "\\( *\\).")
  (setq-local outline-level
              (lambda nil (1+ (/ (length (match-string 1))
                                 edoc-outline-buffer-indent))))

  (toggle-truncate-lines 1)
  (setq buffer-read-only t)
  (when (> (count-lines 1 (point-max))
           (* 1.5 (frame-height)))
    (outline-hide-sublevels 1))
  (message "%s"
           (substitute-command-keys
            (concat
             "Try \\[edoc-outline-display-link], "
             "\\[edoc-outline-select-edoc-window], "
             "\\[edoc-outline-move-to-current-page] or "
             "\\[edoc-outline-follow-link-and-quit]"))))

(define-minor-mode edoc-outline-follow-mode
  "Display links as point moves."
  :group 'edoc-outline
  (setq edoc-outline-follow-mode-last-link nil)
  (cond
   (edoc-outline-follow-mode
    (add-hook 'post-command-hook #'edoc-outline-follow-mode-pch nil t))
   (t
    (remove-hook 'post-command-hook #'edoc-outline-follow-mode-pch t))))

(defun edoc-outline-follow-mode-pch ()
  (let ((link (edoc-outline-link-at-pos (point))))
    (when (and link
               (not (eq link edoc-outline-follow-mode-last-link)))
      (setq edoc-outline-follow-mode-last-link link)
      (edoc-outline-display-link (point)))))

;;;###autoload
(defun edoc-outline (&optional buffer no-select-window-p)
  "Display an PDF outline of BUFFER.

BUFFER defaults to the current buffer.  Select the outline
buffer, unless NO-SELECT-WINDOW-P is non-nil."
  (interactive (list nil (or current-prefix-arg
                             (consp last-nonmenu-event))))
  (let ((win
         (display-buffer
          (edoc-outline-noselect buffer)
          edoc-outline-display-buffer-action)))
    (unless no-select-window-p
      (select-window win))))

(defun edoc-outline-noselect (&optional buffer)
  "Create an PDF outline of BUFFER, but don't display it."
  (save-current-buffer
    (and buffer (set-buffer buffer))
    (edoc-util-assert-edoc-buffer)
    (let* ((edoc-buffer (current-buffer))
           (edoc-file (edoc-view-buffer-file-name))
           (edoc-window (and (eq edoc-buffer (window-buffer))
                            (selected-window)))
           (bname (edoc-outline-buffer-name))
           (buffer-exists-p (get-buffer bname))
           (buffer (get-buffer-create bname)))
      (with-current-buffer buffer
        (setq-local fill-column edoc-outline-fill-column)
        (unless buffer-exists-p
          (when (= 0 (save-excursion
                       (edoc-outline-insert-outline edoc-buffer)))
            (kill-buffer buffer)
            (error "PDF has no outline"))
          (edoc-outline-buffer-mode))
        (set (make-local-variable 'other-window-scroll-buffer)
             edoc-buffer)
        (setq edoc-outline-edoc-window edoc-window
              edoc-outline-edoc-document (or edoc-file edoc-buffer))
        (current-buffer)))))

(defun edoc-outline-buffer-name (&optional edoc-buffer)
  (unless edoc-buffer (setq edoc-buffer (current-buffer)))
  (let ((buf (format "*Outline %s*" (buffer-name edoc-buffer))))
    ;; (when (buffer-live-p (get-buffer buf))
    ;;   (kill-buffer buf))
    buf))

(defun edoc-outline-insert-outline (edoc-buffer)
  (let ((labels (and edoc-outline-display-labels
                     (edoc-info-pagelabels edoc-buffer)))
        (nitems 0))
    (dolist (item (edoc-info-outline edoc-buffer))
      (let-alist item
        (when (eq .type 'goto-dest)
          (insert-text-button
           (concat
            (make-string (* (1- .depth) edoc-outline-buffer-indent) ?\s)
            .title
            (if (> .page 0)
                (format " (%s)"
                        (if labels
                            (nth (1- .page) labels)
                          .page))
              "(invalid)"))
           'type 'edoc-outline
           'help-echo (edoc-links-action-to-string item)
           'edoc-outline-link item)
          (newline)
          (cl-incf nitems))))
    nitems))

(defun edoc-outline-get-edoc-window (&optional if-visible-p)
  (save-selected-window
    (let* ((buffer (cond
                    ((buffer-live-p edoc-outline-edoc-document)
                     edoc-outline-edoc-document)
                    ((bufferp edoc-outline-edoc-document)
                     (error "PDF buffer was killed"))
                    (t
                     (or
                      (find-buffer-visiting
                       edoc-outline-edoc-document)
                      (find-file-noselect
                       edoc-outline-edoc-document)))))
           (edoc-window
            (if (and (window-live-p edoc-outline-edoc-window)
                     (eq buffer
                         (window-buffer edoc-outline-edoc-window)))
                edoc-outline-edoc-window
              (or (get-buffer-window buffer)
                  (and (null if-visible-p)
                       (display-buffer
                        buffer
                        '(nil (inhibit-same-window . t))))))))
      (setq edoc-outline-edoc-window edoc-window))))


;;
;; Commands
;;

(defun edoc-outline-move-to-current-page ()
  "Move to the item corresponding to the current page.

Open nodes as necessary."
  (interactive)
  (let (page)
    (with-selected-window (edoc-outline-get-edoc-window)
      (setq page (edoc-view-current-page)))
    (edoc-outline-move-to-page page)))

(defun edoc-outline-quit-and-kill ()
  "Quit browsing the outline and kill its buffer."
  (interactive)
  (edoc-outline-quit t))

(defun edoc-outline-quit (&optional kill)
  "Quit browsing the outline buffer."
  (interactive "P")
  (let ((win (selected-window)))
    (edoc-outline-select-edoc-window t)
    (quit-window kill win)))

(defun edoc-outline-up-heading (arg &optional invisible-ok)
  "Like `outline-up-heading', but `push-mark' first."
  (interactive "p")
  (let ((pos (point)))
    (outline-up-heading arg invisible-ok)
    (unless (= pos (point))
      (push-mark pos))))

(defun edoc-outline-end-of-buffer ()
  "Move to the end of the outline buffer."
  (interactive)
  (let ((pos (point)))
    (goto-char (point-max))
    (when (and (eobp)
               (not (bobp))
               (null (button-at (point))))
      (forward-line -1))
    (unless (= pos (point))
      (push-mark pos))))

(defun edoc-outline-link-at-pos (&optional pos)
  (unless pos (setq pos (point)))
  (let ((button (or (button-at pos)
                    (button-at (1- pos)))))
    (and button
         (button-get button
                     'edoc-outline-link))))

(defun edoc-outline-follow-link (&optional pos)
  "Select PDF window and move to the page corresponding to POS."
  (interactive)
  (unless pos (setq pos (point)))
  (let ((link (edoc-outline-link-at-pos pos)))
    (unless link
      (error "Nothing to follow here"))
    (select-window (edoc-outline-get-edoc-window))
    (edoc-links-action-perform link)))

(defun edoc-outline-follow-link-and-quit (&optional pos)
  "Select PDF window and move to the page corresponding to POS.

Then quit the outline window."
  (interactive)
  (let ((link (edoc-outline-link-at-pos (or pos (point)))))
    (edoc-outline-quit)
    (unless link
      (error "Nothing to follow here"))
    (edoc-links-action-perform link)))

(defun edoc-outline-display-link (&optional pos)
  "Display the page corresponding to the link at POS."
  (interactive)
  (unless pos (setq pos (point)))
  (let ((inhibit-redisplay t)
        (link (edoc-outline-link-at-pos pos)))
    (unless link
      (error "Nothing to follow here"))
    (with-selected-window (edoc-outline-get-edoc-window)
      (edoc-links-action-perform link))
    (force-mode-line-update t)))

(defun edoc-outline-mouse-display-link (event)
  "Display the page corresponding to the position of EVENT."
  (interactive "@e")
  (edoc-outline-display-link
   (posn-point (event-start event))))

(defun edoc-outline-select-edoc-window (&optional no-create-p)
  "Display and select the PDF document window."
  (interactive)
  (let ((win (edoc-outline-get-edoc-window no-create-p)))
    (and (window-live-p win)
         (select-window win))))

(defun edoc-outline-toggle-subtree ()
  "Toggle hidden state of the current complete subtree."
  (interactive)
  (save-excursion
    (outline-back-to-heading)
    (if (not (outline-invisible-p (line-end-position)))
        (outline-hide-subtree)
      (outline-show-subtree))))

(defun edoc-outline-move-to-page (page)
  "Move to an outline item corresponding to PAGE."
  (interactive
   (list (or (and current-prefix-arg
                  (prefix-numeric-value current-prefix-arg))
             (read-number "Page: "))))
  (goto-char (edoc-outline-position-of-page page))
  (save-excursion
    (while (outline-invisible-p)
      (outline-up-heading 1 t)
      (show-children)))
  (save-excursion
    (when (outline-invisible-p)
      (outline-up-heading 1 t)
      (show-children)))
  (back-to-indentation))

(defun edoc-outline-position-of-page (page)
  (let (curpage)
    (save-excursion
      (goto-char (point-min))
      (while (and (setq curpage (alist-get 'page (edoc-outline-link-at-pos)))
                  (< curpage page))
        (forward-line))
      (point))))



;;
;; Imenu Support
;;


;;;###autoload
(defun edoc-outline-imenu-enable ()
  "Enable imenu in the current PDF buffer."
  (interactive)
  (edoc-util-assert-edoc-buffer)
  (setq-local imenu-create-index-function
              (if edoc-outline-imenu-use-flat-menus
                  'edoc-outline-imenu-create-index-flat
                'edoc-outline-imenu-create-index-tree))
  (imenu-add-to-menubar "PDF Outline"))

(defun edoc-outline-imenu-disable ()
  "Disable imenu in the current PDF buffer."
  (interactive)
  (edoc-util-assert-edoc-buffer)
  (setq-local imenu-create-index-function nil)
  (local-set-key [menu-bar index] nil)
  (when (eq edoc-view-mode-map
            (keymap-parent (current-local-map)))
    (use-local-map (keymap-parent (current-local-map)))))


(defun edoc-outline-imenu-create-item (link &optional labels)
  (let-alist link
    (list (format "%s (%s)" .title (if labels
                                       (nth (1- .page) labels)
                                     .page))
          0
          'edoc-outline-imenu-activate-link
          link)))

(defun edoc-outline-imenu-create-index-flat ()
  (let ((labels (and edoc-outline-display-labels
                     (edoc-info-pagelabels)))
        index)
    (dolist (item (edoc-info-outline))
      (let-alist item
        (when (eq .type 'goto-dest)
          (push (edoc-outline-imenu-create-item item labels)
                index))))
    (nreverse index)))


(defun edoc-outline-imenu-create-index-tree ()
  (edoc-outline-imenu-create-index-tree-1
   (edoc-outline-treeify-outline-list
    (cl-remove-if-not
     (lambda (type)
       (eq type 'goto-dest))
     (edoc-info-outline)
     :key (apply-partially 'alist-get 'type)))
   (and edoc-outline-display-labels
        (edoc-info-pagelabels))))

(defun edoc-outline-imenu-create-index-tree-1 (nodes &optional labels)
  (mapcar (lambda (node)
            (let (children)
              (when (consp (caar node))
                (setq children (cdr node)
                      node (car node)))
              (let ((item
                     (edoc-outline-imenu-create-item node labels)))
                (if children
                    (cons (alist-get 'title node)
                          (cons item (edoc-outline-imenu-create-index-tree-1
                                      children labels)))
                  item))))
          nodes))

(defun edoc-outline-treeify-outline-list (list)
  (when list
    (let ((depth (alist-get 'depth (car list)))
          result)
      (while (and list
                  (>= (alist-get 'depth (car list))
                      depth))
        (when (= (alist-get 'depth (car list)) depth)
          (let ((item (car list)))
            (when (and (cdr list)
                       (>  (alist-get 'depth (cadr list))
                           depth))
              (setq item
                    (cons
                     item
                     (edoc-outline-treeify-outline-list (cdr list)))))
            (push item result)))
        (setq list (cdr list)))
      (reverse result))))

(defun edoc-outline-imenu-activate-link (&rest args)
  ;; bug #14029
  (when (eq (nth 2 args) 'edoc-outline-imenu-activate-link)
    (setq args (cdr args)))
  (edoc-links-action-perform (nth 2 args)))

(defadvice imenu--split-menu (around edoc-outline activate)
  "Advice to keep the original outline order.

 Calls `edoc-outline-imenu--split-menu' instead, if in a PDF
 buffer and `edoc-outline-imenu-keep-order' is non-nil."
  (if (not (and (edoc-util-edoc-buffer-p)
                edoc-outline-imenu-keep-order))
      ad-do-it
    (setq ad-return-value
          (edoc-outline-imenu--split-menu menulist title))))

(defvar imenu--rescan-item)
(defvar imenu-sort-function)
(defvar imenu-create-index-function)
(defvar imenu-max-items)

(defun edoc-outline-imenu--split-menu (menulist title)
  "Replacement function for `imenu--split-menu'.

This function does not move sub-menus to the top, therefore
keeping the original outline order of the document.  Also it does
not call `imenu-sort-function'."
  (let ((menulist (copy-sequence menulist))
        keep-at-top)
    (if (memq imenu--rescan-item menulist)
        (setq keep-at-top (list imenu--rescan-item)
              menulist (delq imenu--rescan-item menulist)))
    (if (> (length menulist) imenu-max-items)
        (setq menulist
              (mapcar
               (lambda (menu)
                 (cons (format "From: %s" (caar menu)) menu))
               (imenu--split menulist imenu-max-items))))
    (cons title
          (nconc (nreverse keep-at-top) menulist))))


(provide 'edoc-outline)

;;; edoc-outline.el ends here

;; Local Variables:
;; byte-compile-warnings: (not obsolete)
;; End:
