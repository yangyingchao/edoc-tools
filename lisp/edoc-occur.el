;;; edoc-occur.el --- Display matching lines of PDF documents. -*- lexical-binding: t -*-

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

(require 'edoc-tools)
(require 'edoc-view)
(require 'edoc-util)
(require 'edoc-info)
(require 'edoc-isearch)
(require 'tablist)
(require 'ibuf-ext)
(require 'dired)
(require 'let-alist)

;;; Code:




;; * ================================================================== *
;; * Custom & Variables
;; * ================================================================== *

(defgroup edoc-occur nil
  "Display matching lines of PDF documents."
  :group 'edoc-tools)

(defface edoc-occur-document-face
  '((default (:inherit font-lock-string-face)))
  "Face used to highlight documents in the list buffer.")

(defface edoc-occur-page-face
  '((default (:inherit font-lock-type-face)))
  "Face used to highlight page numbers in the list buffer.")

(defcustom edoc-occur-search-batch-size 16
  "Maximum number of pages searched in one query.

Lower numbers will make Emacs more responsive when searching at
the cost of slightly increased search time."
  :type 'integer)

(defcustom edoc-occur-prefer-string-search nil
  "If non-nil, reverse the meaning of the regexp-p prefix-arg."
  :type 'boolean)

(defvar edoc-occur-history nil
  "The history variable for search strings.")

(defvar edoc-occur-search-pages-left nil
  "The total number of pages left to search.")

(defvar edoc-occur-search-documents nil
  "The list of searched documents.

Each element should be either the filename of a PDF document or a
cons \(FILENAME . PAGES\), where PAGES is the list of pages to
search.  See `edoc-info-normalize-page-range' for its format.")

(defvar edoc-occur-number-of-matches 0
  "The number of matches in all searched documents.")

(defvar edoc-occur-search-string nil
  "The currently used search string, resp. regexp.")

(defvar edoc-occur-search-regexp-p nil
  "Non-nil, if searching for a regexp.")

(defvar edoc-occur-buffer-mode-map
  (let ((kmap (make-sparse-keymap)))
    (set-keymap-parent kmap tablist-mode-map)
    (define-key kmap (kbd "RET") #'edoc-occur-goto-occurrence)
    (define-key kmap (kbd "C-o") #'edoc-occur-view-occurrence)
    (define-key kmap (kbd "SPC") #'edoc-occur-view-occurrence)
    (define-key kmap (kbd "C-c C-f") #'next-error-follow-minor-mode)
    (define-key kmap (kbd "g") #'edoc-occur-revert-buffer-with-args)
    (define-key kmap (kbd "K") #'edoc-occur-abort-search)
    (define-key kmap (kbd "D") #'edoc-occur-tablist-do-delete)
    (define-key kmap (kbd "x") #'edoc-occur-tablist-do-flagged-delete)
    (define-key kmap (kbd "A") #'edoc-occur-tablist-gather-documents)
    kmap)
  "The keymap used for `edoc-occur-buffer-mode'.")


;; * ================================================================== *
;; * High level functions
;; * ================================================================== *

(define-derived-mode edoc-occur-buffer-mode tablist-mode "PDFOccur"
  "Major mode for output from `edoc-occur`. \\<edoc-occur-buffer-mode-map>

Some useful keys are:

\\[edoc-occur-abort-search] - Abort the search.
\\[edoc-occur-revert-buffer-with-args] - Restart the search.
\\[universal-argument] \\[edoc-occur-revert-buffer-with-args] - Restart search with different regexp.
\\[universal-argument] \\[universal-argument] \\[edoc-occur-revert-buffer-with-args] - Same, but do a plain string search.

\\[tablist-push-regexp-filter] - Filter matches by regexp on current or prefix-th column.
\\[tablist-pop-filter] - Remove last added filter.

\\[edoc-occur-tablist-do-delete] - Remove the current file from the search.
\\[edoc-occur-tablist-gather-documents] - Include marked files from displayed `dired'/`ibuffer' and
    `edoc-view-mode' buffers in the search.

\\{edoc-occur-buffer-mode-map}"
  (setq-local case-fold-search case-fold-search)
  (setq-local next-error-function #'edoc-occur-next-error)
  (setq-local revert-buffer-function
              #'edoc-occur-revert-buffer)
  (setq next-error-last-buffer (current-buffer))
  (setq-local tabulated-list-sort-key nil)
  (setq-local tabulated-list-use-header-line t)
  (setq-local tablist-operations-function
              (lambda (op &rest _)
                (cl-case op
                  (supported-operations '(find-entry))
                  (find-entry
                   (let ((display-buffer-overriding-action
                          '(display-buffer-same-window)))
                     (edoc-occur-goto-occurrence)))))))

;;;###autoload
(defun edoc-occur (string &optional regexp-p)
  "List lines matching STRING or PCRE.

Interactively search for a regexp. Unless a prefix arg was given,
in which case this functions performs a string search.

If `edoc-occur-prefer-string-search' is non-nil, the meaning of
the prefix-arg is inverted."
  (interactive
   (progn
     (edoc-util-assert-edoc-buffer)
     (list
      (edoc-occur-read-string
       (edoc-occur-want-regexp-search-p))
      (edoc-occur-want-regexp-search-p))))
  (edoc-util-assert-edoc-buffer)
  (edoc-occur-search (list (current-buffer)) string regexp-p))

(defvar ibuffer-filtering-qualifiers)
;;;###autoload
(defun edoc-occur-multi-command ()
  "Perform `edoc-occur' on multiple buffer.

For a programmatic search of multiple documents see
`edoc-occur-search'."
  (interactive)
  (ibuffer)
  (with-current-buffer "*Ibuffer*"
    (edoc-occur-ibuffer-minor-mode)
    (unless (member '(derived-mode . edoc-view-mode)
                    ibuffer-filtering-qualifiers)
      (ibuffer-filter-by-derived-mode 'edoc-view-mode))
    (message
     "%s"
     (substitute-command-keys
      "Mark a bunch of PDF buffers and type \\[edoc-occur-ibuffer-do-occur]"))
    (sit-for 3)))

(defun edoc-occur-revert-buffer (&rest _)
  "Restart the search."
  (edoc-occur-assert-occur-buffer-p)
  (unless edoc-occur-search-documents
    (error "No documents to search"))
  (unless edoc-occur-search-string
    (error "Nothing to search for"))
  (let* ((2-columns-p (= 1 (length edoc-occur-search-documents)))
         (filename-width
          (min 24
               (apply #'max
                 (mapcar #'length
                         (mapcar #'edoc-occur-abbrev-document
                                 (mapcar #'car edoc-occur-search-documents))))))
         (page-sorter (tablist-generate-sorter
                       (if 2-columns-p 0 1)
                       '<
                       'string-to-number)))
    (setq tabulated-list-format
          (if 2-columns-p
              `[("Page" 4 ,page-sorter :right-align t)
                ("Line" 0 t)]
            `[("Document" ,filename-width t)
              ("Page" 4 ,page-sorter :right-align t)
              ("Line" 0 t)])
          tabulated-list-entries nil))
  (tabulated-list-revert)
  (edoc-occur-start-search
   edoc-occur-search-documents
   edoc-occur-search-string
   edoc-occur-search-regexp-p)
  (edoc-occur-update-header-line)
  (setq mode-line-process
        '(:propertize ":run" face compilation-mode-line-run)))

(defun edoc-occur-revert-buffer-with-args (string &optional regexp-p documents)
  "Restart the search with modified arguments.

Interactively just restart the search, unless a prefix was given.
In this case read a new search string.  With `C-u C-u' as prefix
additionally invert the current state of
`edoc-occur-search-regexp-p'."
  (interactive
   (progn
     (edoc-occur-assert-occur-buffer-p)
     (cond
      (current-prefix-arg
       (let ((regexp-p
              (if (equal current-prefix-arg '(16))
                  (not edoc-occur-search-regexp-p)
                edoc-occur-search-regexp-p)))
         (list
          (edoc-occur-read-string regexp-p)
          regexp-p)))
      (t
       (list edoc-occur-search-string
             edoc-occur-search-regexp-p)))))
  (setq edoc-occur-search-string string
        edoc-occur-search-regexp-p regexp-p)
  (when documents
    (setq edoc-occur-search-documents
          (edoc-occur-normalize-documents documents)))
  (edoc-occur-revert-buffer))

(defun edoc-occur-abort-search ()
  "Abort the current search.

This immediately kills the search process."
  (interactive)
  (unless (edoc-occur-search-in-progress-p)
    (user-error "No search in progress"))
  (edoc-info-kill-local-server)
  (edoc-occur-search-finished t))


;; * ================================================================== *
;; * Finding occurrences
;; * ================================================================== *


(defun edoc-occur-goto-occurrence (&optional no-select-window-p)
  "Go to the occurrence at point.

If EVENT is nil, use occurrence at current line.  Select the
PDF's window, unless NO-SELECT-WINDOW-P is non-nil.

FIXME: EVENT not used at the moment."
  (interactive)
  (let ((item (tabulated-list-get-id)))
    (when item
      (let* ((doc (plist-get item :document))
             (page (plist-get item :page))
             (match (plist-get item :match-edges))
             (buffer (if (bufferp doc)
                         doc
                       (or (find-buffer-visiting doc)
                           (find-file-noselect doc))))
             window)
        (if no-select-window-p
            (setq window (display-buffer buffer))
          (pop-to-buffer buffer)
          (setq window (selected-window)))
        (with-selected-window window
          (when page
            (edoc-view-goto-page page))
          ;; Abuse isearch.
          (when match
            (let ((pixel-match
                   (edoc-util-scale-relative-to-pixel match))
                  (edoc-isearch-batch-mode t))
              (edoc-isearch-hl-matches pixel-match nil t)
              (edoc-isearch-focus-match-batch pixel-match))))))))

(defun edoc-occur-view-occurrence (&optional _event)
  "View the occurrence at EVENT.

If EVENT is nil, use occurrence at current line."
  (interactive (list last-nonmenu-event))
  (edoc-occur-goto-occurrence t))

(defun edoc-occur-next-error (&optional arg reset)
  "Move to the Nth (default 1) next match in an PDF Occur mode buffer.
Compatibility function for \\[next-error] invocations."
  (interactive "p")
  ;; we need to run edoc-occur-find-match from within the Occur buffer
  (with-current-buffer
      ;; Choose the buffer and make it current.
      (if (next-error-buffer-p (current-buffer))
          (current-buffer)
        (next-error-find-buffer
         nil nil
         (lambda ()
           (eq major-mode 'edoc-occur-buffer-mode))))
    (when (bobp)
      (setq reset t))
    (if reset
        (goto-char (point-min))
      (beginning-of-line))
    (when (/= arg 0)
      (when (eobp)
        (forward-line -1))
      (when reset
        (cl-decf arg))
      (let ((line (line-number-at-pos))
            (limit (line-number-at-pos
                    (if (>= arg 0)
                        (1- (point-max))
                      (point-min)))))
        (when (= line limit)
          (error "No more matches"))
        (forward-line
         (if (>= arg 0)
             (min arg (- limit line))
           (max arg (- limit line))))))
    ;; In case the *Occur* buffer is visible in a nonselected window.
    (tablist-move-to-major-column)
    (let ((win (get-buffer-window (current-buffer) t)))
      (if win (set-window-point win (point))))
    (edoc-occur-goto-occurrence)))


;; * ================================================================== *
;; * Integration with other modes
;; * ================================================================== *

;;;###autoload
(define-minor-mode edoc-occur-global-minor-mode
  "Enable integration of Pdf Occur with other modes.

This global minor mode enables (or disables)
`edoc-occur-ibuffer-minor-mode' and `edoc-occur-dired-minor-mode'
in all current and future ibuffer/dired buffer."
  :global t
  (let ((arg (if edoc-occur-global-minor-mode 1 -1)))
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (cond
         ((derived-mode-p 'dired-mode)
          (edoc-occur-dired-minor-mode arg))
         ((derived-mode-p 'ibuffer-mode)
          (edoc-occur-ibuffer-minor-mode arg)))))
    (cond
     (edoc-occur-global-minor-mode
      (add-hook 'dired-mode-hook #'edoc-occur-dired-minor-mode)
      (add-hook 'ibuffer-mode-hook #'edoc-occur-ibuffer-minor-mode))
     (t
      (remove-hook 'dired-mode-hook #'edoc-occur-dired-minor-mode)
      (remove-hook 'ibuffer-mode-hook #'edoc-occur-ibuffer-minor-mode)))))

(defvar edoc-occur-ibuffer-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap ibuffer-do-occur] #'edoc-occur-ibuffer-do-occur)
    map)
  "Keymap used in `edoc-occur-ibuffer-minor-mode'.")

;;;###autoload
(define-minor-mode edoc-occur-ibuffer-minor-mode
  "Hack into ibuffer's do-occur binding.

This mode remaps `ibuffer-do-occur' to
`edoc-occur-ibuffer-do-occur', which will start the PDF Tools
version of `occur', if all marked buffer's are in `edoc-view-mode'
and otherwise fallback to `ibuffer-do-occur'.")

(defun edoc-occur-ibuffer-do-occur (&optional regexp-p)
  "Uses `edoc-occur-search', if appropriate.

I.e. all marked buffers are in PDFView mode."
  (interactive
   (list (edoc-occur-want-regexp-search-p)))
  (let* ((buffer (or (ibuffer-get-marked-buffers)
                     (and (ibuffer-current-buffer)
                          (list (ibuffer-current-buffer)))))
         (edoc-only-p (cl-every
                      (lambda (buf)
                        (with-current-buffer buf
                          (derived-mode-p 'edoc-view-mode)))
                      buffer)))
    (if (not edoc-only-p)
        (call-interactively 'ibuffer-do-occur)
      (let ((regexp (edoc-occur-read-string regexp-p)))
        (edoc-occur-search buffer regexp regexp-p)))))

(defvar edoc-occur-dired-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap dired-do-search] #'edoc-occur-dired-do-search)
    map)
  "Keymap used in `edoc-occur-dired-minor-mode'.")

;;;###autoload
(define-minor-mode edoc-occur-dired-minor-mode
  "Hack into dired's `dired-do-search' binding.

This mode remaps `dired-do-search' to
`edoc-occur-dired-do-search', which will start the PDF Tools
version of `occur', if all marked buffer's are in `edoc-view-mode'
and otherwise fallback to `dired-do-search'.")

(defun edoc-occur-dired-do-search ()
  "Uses `edoc-occur-search', if appropriate.

I.e. all marked files look like PDF documents."
  (interactive)
  (let ((files (dired-get-marked-files)))
    (if (not (cl-every (lambda (file)
                         (string-match-p
                          (car edoc-tools-auto-mode-alist-entry)
                          file))
                       files))
        (call-interactively 'dired-do-search)
      (let* ((regex-p (edoc-occur-want-regexp-search-p))
             (regexp (edoc-occur-read-string regex-p)))
        (edoc-occur-search files regexp regex-p)))))



;; * ================================================================== *
;; * Search engine
;; * ================================================================== *


(defun edoc-occur-search (documents string &optional regexp-p)
  "Search DOCUMENTS for STRING.

DOCUMENTS should be a list of buffers (objects, not names),
filenames or conses \(BUFFER-OR-FILENAME . PAGES\), where PAGES
determines the scope of the search of the respective document.
See `edoc-info-normalize-page-range' for its format.

STRING is either the string to search for or, if REGEXP-P is
non-nil, a Perl compatible regular expression (PCRE).

Display the occur buffer and start the search asynchronously.

Returns the window where the buffer is displayed."

  (unless documents
    (error "No documents to search"))
  (when (or (null string) (= (length string) 0))
    (error "Not searching for the empty string"))
  (with-current-buffer (get-buffer-create "*PDF-Occur*")
    (edoc-occur-buffer-mode)
    (setq-local edoc-occur-search-documents
                (edoc-occur-normalize-documents documents))
    (setq-local edoc-occur-search-string string)
    (setq-local edoc-occur-search-regexp-p regexp-p)
    (setq-local edoc-occur-search-pages-left 0)
    (setq-local edoc-occur-number-of-matches 0)
    (edoc-occur-revert-buffer)
    (display-buffer
     (current-buffer))))

(advice-add 'tabulated-list-init-header :after #'edoc-occur--update-header)
(defun edoc-occur--update-header (&rest _)
  "We want our own headers, thank you."
  (when (derived-mode-p 'edoc-occur-buffer-mode)
    (save-current-buffer
      (with-no-warnings (edoc-occur-update-header-line)))))

(defun edoc-occur-create-entry (filename page &optional match)
  "Create a `tabulated-list-entries' entry for a search result.

If match is nil, create a fake entry for documents w/o any
matches linked with PAGE."
  (let* ((text (or (car match) "[No matches]"))
         (edges (cdr match))
         (displayed-text
          (if match
              (replace-regexp-in-string "\n" "\\n" text t t)
            (propertize text 'face 'font-lock-warning-face)))
         (displayed-page
          (if match
              (propertize (format "%d" page)
                          'face 'edoc-occur-page-face)
            ""))
         (displayed-document
          (propertize
           (edoc-occur-abbrev-document filename)
           'face 'edoc-occur-document-face))
         (id `(:document ,filename
               :page ,page
               :match-text ,(if match text)
               :match-edges ,(if match edges))))
    (list id
          (if (= (length edoc-occur-search-documents) 1)
              (vector displayed-page displayed-text)
            (vector displayed-document
                    displayed-page
                    displayed-text)))))

(defun edoc-occur-update-header-line ()
  (edoc-occur-assert-occur-buffer-p)
  (save-current-buffer
    ;;force-mode-line-update seems to sometimes spuriously change the
    ;;current buffer.
    (setq header-line-format
          `(:eval (concat
                   (if (= (length edoc-occur-search-documents) 1)
                       (format "%d match%s in document `%s'"
                               edoc-occur-number-of-matches
                               (if (/= 1 edoc-occur-number-of-matches) "es" "")
                               (edoc-occur-abbrev-document
                                (caar edoc-occur-search-documents)))
                     (format "%d match%s in %d documents"
                             edoc-occur-number-of-matches
                             (if (/= 1 edoc-occur-number-of-matches) "es" "")
                             (length edoc-occur-search-documents)))
                   (if (edoc-occur-search-in-progress-p)
                       (propertize
                        (concat " ["
                                (if (numberp edoc-occur-search-pages-left)
                                    (format "%d pages left"
                                            edoc-occur-search-pages-left)
                                  "Searching")
                                "]")
                        'face 'compilation-mode-line-run)))))
    (force-mode-line-update)))

(defun edoc-occur-search-finished (&optional abort-p)
  (setq edoc-occur-search-pages-left 0)
  (setq mode-line-process
        (if abort-p
            '(:propertize
              ":aborted" face compilation-mode-line-fail)
          '(:propertize
            ":exit" face compilation-mode-line-exit)))
  (let ((unmatched
         (mapcar (lambda (doc)
                   (edoc-occur-create-entry doc 1))
                 (cl-set-difference
                  (mapcar #'car
                          edoc-occur-search-documents)
                  (mapcar (lambda (elt)
                            (plist-get (car elt) :document))
                          tabulated-list-entries)
                  :test 'equal))))
    (when (and unmatched
               (> (length edoc-occur-search-documents) 1))
      (edoc-occur-insert-entries unmatched)))
  (tablist-apply-filter)
  (edoc-occur-update-header-line)
  (edoc-isearch-message
   (if abort-p
       "Search aborted."
     (format "Occur search finished with %d matches"
             edoc-occur-number-of-matches))))

(defun edoc-occur-add-matches (filename matches)
  (edoc-occur-assert-occur-buffer-p)
  (when matches
    (let (entries)
      (dolist (match matches)
        (let-alist match
          (push (edoc-occur-create-entry filename .page (cons .text .edges))
                entries)))
      (setq entries (nreverse entries))
      (edoc-occur-insert-entries entries))))

(defun edoc-occur-insert-entries (entries)
  "Insert tabulated-list ENTRIES at the end."
  (edoc-occur-assert-occur-buffer-p)
  (let ((inhibit-read-only t)
        (end-of-buffer (and (eobp) (not (bobp)))))
    (save-excursion
      (goto-char (point-max))
      (dolist (elt entries)
        (apply tabulated-list-printer elt))
      (set-buffer-modified-p nil))
    (when end-of-buffer
      (dolist (win (get-buffer-window-list))
        (set-window-point win (point-max))))
    (setq tabulated-list-entries
          (append tabulated-list-entries
                  entries))))

(defun edoc-occur-search-in-progress-p ()
  (and (numberp edoc-occur-search-pages-left)
       (> edoc-occur-search-pages-left 0)))

(defun edoc-occur-start-search (documents string
                                         &optional regexp-p)
  (edoc-occur-assert-occur-buffer-p)
  (edoc-info-make-local-server nil t)
  (let ((batches (edoc-occur-create-batches
                  documents (or edoc-occur-search-batch-size 1))))
    (edoc-info-local-batch-query
     (lambda (document pages)
       (if regexp-p
           (edoc-info-search-regexp string pages nil document)
         (edoc-info-search-string string pages document)))
     (lambda (status response document pages)
       (if status
           (error "%s" response)
         (when (numberp edoc-occur-search-pages-left)
           (cl-decf edoc-occur-search-pages-left
                    (1+ (- (cdr pages) (car pages)))))
         (when (cl-member document edoc-occur-search-documents
                          :key 'car
                          :test 'equal)
           (cl-incf edoc-occur-number-of-matches
                    (length response))
           (edoc-occur-add-matches document response)
           (edoc-occur-update-header-line))))
     (lambda (status buffer)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (edoc-occur-search-finished (eq status 'killed)))))
     batches)
    (setq edoc-occur-number-of-matches 0)
    (setq edoc-occur-search-pages-left
          (apply #'+ (mapcar (lambda (elt)
                              (1+ (- (cdr (nth 1 elt))
                                     (car (nth 1 elt)))))
                            batches)))))



;; * ================================================================== *
;; * Editing searched documents
;; * ================================================================== *

(defun edoc-occur-tablist-do-delete (&optional arg)
  "Delete ARG documents from the search list."
  (interactive "P")
  (when (edoc-occur-search-in-progress-p)
    (user-error "Can't delete while a search is in progress."))
  (let* ((items (tablist-get-marked-items arg))
         (documents (cl-remove-duplicates
                     (mapcar (lambda (entry)
                               (plist-get (car entry) :document))
                             items)
                     :test 'equal)))
    (unless documents
      (error "No documents selected"))
    (when (tablist-yes-or-no-p
           'Stop\ searching
           nil (mapcar (lambda (d) (cons nil (vector d)))
                       documents))
      (setq edoc-occur-search-documents
            (cl-remove-if (lambda (elt)
                            (member (car elt) documents))
                          edoc-occur-search-documents)
            tabulated-list-entries
            (cl-remove-if (lambda (elt)
                            (when (member (plist-get (car elt) :document)
                                          documents)
                              (when (plist-get (car elt) :match-edges)
                                (cl-decf edoc-occur-number-of-matches))
                              t))
                          tabulated-list-entries))
      (tablist-revert)
      (edoc-occur-update-header-line)
      (tablist-move-to-major-column))))

(defun edoc-occur-tablist-do-flagged-delete (&optional interactive)
  "Stop searching all documents marked with a D."
  (interactive "p")
  (let* ((tablist-marker-char ?D))
    (if (save-excursion
          (goto-char (point-min))
          (re-search-forward (tablist-marker-regexp) nil t))
        (edoc-occur-tablist-do-delete)
      (or (not interactive)
          (message "(No deletions requested)")))))

(defun edoc-occur-tablist-gather-documents ()
  "Gather marked documents in windows.

Examine all dired/ibuffer windows and offer to put marked files
in the search list."
  (interactive)
  (let ((searched (mapcar #'car edoc-occur-search-documents))
        files)
    (dolist (win (window-list))
      (with-selected-window win
        (cond
         ((derived-mode-p 'dired-mode)
          (let ((marked (dired-get-marked-files nil nil nil t)))
            (when (> (length marked) 1)
              (when (eq t (car marked))
                (setq marked (cdr marked)))
              (setq files
                    (append files marked nil)))))
         ((derived-mode-p 'ibuffer-mode)
          (dolist (fname (mapcar #'buffer-file-name
                                 (ibuffer-get-marked-buffers)))
            (when fname
              (push fname files))))
         ((and (derived-mode-p 'edoc-view-mode)
               (buffer-file-name))
          (push (buffer-file-name) files)))))

    (setq files
          (cl-sort                      ;Looks funny.
           (cl-set-difference
            (cl-remove-duplicates
             (cl-remove-if-not
              (lambda (file) (string-match-p
                              (car edoc-tools-auto-mode-alist-entry)
                              file))
              files)
             :test 'file-equal-p)
            searched
            :test 'file-equal-p)
           'string-lessp))
    (if (null files)
        (message "No marked, new PDF files found in windows")
      (when (tablist-yes-or-no-p
             'add nil (mapcar (lambda (file)
                                (cons nil (vector file)))
                              (cl-sort files #'string-lessp)))
        (setq edoc-occur-search-documents
              (append edoc-occur-search-documents
                      (edoc-occur-normalize-documents files)))
        (message "Added %d file%s to the list of searched documents%s"
                 (length files)
                 (dired-plural-s (length files))
                 (substitute-command-keys
                  " - Hit \\[edoc-occur-revert-buffer-with-args]"))))))


;; * ================================================================== *
;; * Utilities
;; * ================================================================== *

(defun edoc-occur-read-string (&optional regexp-p)
  (read-string
   (concat
    (format "List lines %s"
            (if regexp-p "matching PCRE" "containing string"))
    (if edoc-occur-search-string
        (format " (default %s)" edoc-occur-search-string))
    ": ")
   nil 'edoc-occur-history edoc-occur-search-string))

(defun edoc-occur-assert-occur-buffer-p ()
  (unless (derived-mode-p 'edoc-occur-buffer-mode)
    (error "Not in PDF occur buffer")))

(defun edoc-occur-want-regexp-search-p ()
  (or (and current-prefix-arg
           edoc-occur-prefer-string-search)
      (and (null current-prefix-arg)
           (not edoc-occur-prefer-string-search))))

;; FIXME: This will be confusing when searching documents with the
;; same base file-name.
(defun edoc-occur-abbrev-document (file-or-buffer)
  (if (bufferp file-or-buffer)
      (buffer-name file-or-buffer)
    (let ((abbrev (file-name-nondirectory file-or-buffer)))
      (if (> (length abbrev) 0)
          abbrev
        file-or-buffer))))

(defun edoc-occur-create-batches (documents batch-size)
  (let (queries)
    (dolist (d documents)
      (let* ((file-or-buffer (car d))
             (pages (edoc-info-normalize-page-range (cdr d)))
             (first (car pages))
             (last (if (eq (cdr pages) 0)
                       (edoc-info-number-of-pages file-or-buffer)
                     (cdr pages)))
             (npages (1+ (- last first)))
             (nbatches (ceiling
                        (/ (float npages) batch-size))))
        (dotimes (i nbatches)
          (push
           (list file-or-buffer
                 (cons (+ first (* i batch-size))
                       (min last (+ first (1- (* (1+ i) batch-size))))))
           queries))))
    (nreverse queries)))

(defun edoc-occur-normalize-documents (documents)
  "Normalize list of documents.

Replaces buffers with their associated filenames \(if
applicable\) and ensures that every element looks like
\(FILENAME-OR-BUFFER . PAGES\)."
  (cl-sort (mapcar (lambda (doc)
                     (unless (consp doc)
                       (setq doc (cons doc nil)))
                     (when (and (bufferp (car doc))
                                (buffer-file-name (car doc)))
                       (setq doc (cons (buffer-file-name (car doc))
                                       (cdr doc))))
                     (if (stringp (car doc))
                         (cons (expand-file-name (car doc)) (cdr doc))
                       doc))
                   documents)
           (lambda (a b) (string-lessp
                          (if (bufferp a) (buffer-name a) a)
                          (if (bufferp b) (buffer-name b) b)))
           :key 'car))

(provide 'edoc-occur)

;;; edoc-occur.el ends here
