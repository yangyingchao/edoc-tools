;;; edoc-history.el --- A simple stack-based history in PDF buffers. -*- lexical-binding: t -*-

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

;;; Code:

(defgroup edoc-history nil
  "A simple stack-based history."
  :group 'edoc-tools)

(defvar-local edoc-history-stack nil
  "The stack of history items.")

(defvar-local edoc-history-index nil
  "The current index into the `edoc-history-stack'.")

(defvar edoc-history-minor-mode-map
  (let ((kmap (make-sparse-keymap)))
    (define-key kmap (kbd "B") #'edoc-history-backward)
    (define-key kmap (kbd "N") #'edoc-history-forward)
    (define-key kmap (kbd "l") #'edoc-history-backward)
    (define-key kmap (kbd "r") #'edoc-history-forward)
    kmap)
  "Keymap used in `edoc-history-minor-mode'.")

;;;###autoload
(define-minor-mode edoc-history-minor-mode
  "Keep a history of previously visited pages.

This is a simple stack-based history.  Turning the page or
following a link pushes the left-behind page on the stack, which
may be navigated with the following keys.

\\{edoc-history-minor-mode-map}"
  :group 'edoc-history
  (edoc-util-assert-edoc-buffer)
  (edoc-history-clear)
  (cond
   (edoc-history-minor-mode
    (edoc-history-push)
    (add-hook 'edoc-view-after-change-page-hook
              #'edoc-history-before-change-page-hook nil t))
   (t
    (remove-hook 'edoc-view-after-change-page-hook
                 #'edoc-history-before-change-page-hook t))))

(defun edoc-history-before-change-page-hook ()
  "Push a history item, before leaving this page."
  (when (and edoc-history-minor-mode
             (not (bound-and-true-p edoc-isearch-active-mode))
             (edoc-view-current-page))
    (edoc-history-push)))

(defun edoc-history-push ()
  "Push the current page on the stack.

This function does nothing, if current stack item already
represents the current page."
  (interactive)
  (let ((item (edoc-history-create-item)))
    (unless (and edoc-history-stack
                 (equal (nth edoc-history-index
                             edoc-history-stack) item))
      (setq edoc-history-stack
            (last edoc-history-stack
                  (- (length edoc-history-stack)
                     edoc-history-index))
            edoc-history-index 0)
      (push item edoc-history-stack))))

(defun edoc-history-clear ()
  "Remove all history items."
  (interactive)
  (setq edoc-history-stack nil
        edoc-history-index 0)
  (edoc-history-push))

(defun edoc-history-create-item ()
  "Create a history item representing the current page."
  (list
   (edoc-view-current-page)))

(defun edoc-history-beginning-of-history-p ()
  "Return t, if at the beginning of the history."
  (= edoc-history-index 0))

(defun edoc-history-end-of-history-p ()
  "Return t, if at the end of the history."
  (= edoc-history-index
     (1- (length edoc-history-stack))))

(defun edoc-history-backward (n)
  "Go N times backward in the history."
  (interactive "p")
  (cond
   ((and (> n 0)
         (edoc-history-end-of-history-p))
    (error "End of history"))
   ((and (< n 0)
         (edoc-history-beginning-of-history-p))
    (error "Beginning of history"))
   ((/= n 0)
    (let ((i (min (max 0 (+ edoc-history-index n))
                  (1- (length edoc-history-stack)))))
      (prog1
          (- (+ edoc-history-index n) i)
        (edoc-history-goto i))))
   (t 0)))

(defun edoc-history-forward (n)
  "Go N times forward in the history."
  (interactive "p")
  (edoc-history-backward (- n)))

(defun edoc-history-goto (n)
  "Go to item N in the history."
  (interactive "p")
  (when (null edoc-history-stack)
    (error "The history is empty"))
  (cond
   ((>= n (length edoc-history-stack))
    (error "End of history"))
   ((< n 0)
    (error "Beginning of history"))
   (t
    (setq edoc-history-index n)
    (edoc-view-goto-page
     (car (nth n edoc-history-stack))))))

(defun edoc-history-debug ()
  "Visualize the history in the header-line."
  (interactive)
  (setq header-line-format
        '(:eval
          (let ((pages (mapcar 'car edoc-history-stack))
                (index edoc-history-index)
                header)
            (dotimes (i (length pages))
              (push (propertize
                     (format "%s" (nth i pages))
                     'face
                     (and (= i index) 'match))
                    header))
            (concat
             "(" (format "%d" index) ")  "
             (mapconcat 'identity (nreverse header) " | "))))))

(provide 'edoc-history)

;;; edoc-history.el ends here
