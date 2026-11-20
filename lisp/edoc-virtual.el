;;; edoc-virtual.el --- Virtual PDF documents         -*- lexical-binding: t; -*-

;; Copyright (C) 2015  Andreas Politz

;; Author: Andreas Politz <politza@hochschule-trier.de>
;; Keywords: multimedia, files

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

;; A virtual PDF is a collection of pages, or parts thereof, of
;; arbitrary documents in one particular order.  This library acts as
;; an intermediate between edoc-info.el and all other packages, in
;; order to transparently make this collection appear as one single
;; document.
;;
;; The trickiest part is to make these intermediate functions behave
;; like the edoc-info-* equivalents in both the synchronous and
;; asynchronous case.

;;; Code:
(require 'let-alist)
(require 'edoc-info)
(require 'edoc-util)

(declare-function edoc-view-mode "edoc-view.el")

;; * ================================================================== *
;; * Variables
;; * ================================================================== *

(defconst edoc-virtual-magic-mode-regexp "^ *;+ *%VPDF\\_>"
  "A regexp matching the first line in a vpdf file.")

(defvar-local edoc-virtual-document nil
  "A list representing the virtual document.")

(put 'edoc-virtual-document 'permanent-local t)

(defvar edoc-virtual-adapter-alist nil
  "Alist of server functions.

Each element looks like \(PDF-VIRTUAL-FN . PDF-INFO-FN\).  This
list is filled by the macro `edoc-virtual-define-adapter' and used
to enable/disable the corresponding advices.")


;; * ================================================================== *
;; * VPDF datastructure
;; * ================================================================== *

(defun edoc-virtual-pagespec-normalize (page-spec &optional filename)
  "Normalize PAGE-SPEC using FILENAME.

PAGE-SPEC should be as described in
`edoc-virtual-document-create'.  FILENAME is used to determine the
last page number, if needed.  The `current-buffer', if it is nil.

Returns a list \(\(FIRST . LAST\) . REGION\)\)."

  (let ((page-spec (cond
                    ((natnump page-spec)
                     (list (cons page-spec page-spec)))
                    ((null (car page-spec))
                     (let ((npages (edoc-info-number-of-pages filename)))
                       (cons (cons 1 npages)
                             (cdr page-spec))))
                    ((natnump (car page-spec))
                     (cond
                      ((natnump (cdr page-spec))
                       (list page-spec))
                      (t
                       (cons (cons (car page-spec)
                                   (car page-spec))
                             (cdr page-spec)))))
                    (t page-spec))))
    (when (equal (cdr page-spec)
                 '(0 0 1 1))
      (setq page-spec `((,(caar page-spec) . ,(cdar page-spec)))))
    page-spec))

(cl-defstruct edoc-virtual-range
  ;; The PDF's filename.
  filename
  ;; First page in this range.
  first
  ;; Last page.
  last
  ;; The edges selected for these pages.
  region
  ;; The page-index corresponding to the first page in this range.
  index-start)

(cl-defstruct edoc-virtual-document
  ;; Array of shared edoc-virtual-range structs, one element for each
  ;; page.
  page-array
  ;; An alist mapping filenames to a list of pages.
  file-map)

(defun edoc-virtual-range-length (page)
  "Return the number of pages in PAGE."
  (1+ (- (edoc-virtual-range-last page)
         (edoc-virtual-range-first page))))

(defun edoc-virtual-document-create (list &optional directory
                                         file-error-handler)
  "Create a virtual PDF from LIST using DIRECTORY.

LIST should be a list of elements \(FILENAME . PAGE-SPECS\),
where FILENAME is a PDF document and PAGE-SPECS is a list of
PAGE-RANGE and/or \(PAGE-RANGE . EDGES\).  In the later case,
EDGES should be a list of relative coordinates \(LEFT TOP RIGHT
BOT\) selecting a region of the page(s) in PAGE-RANGE.  Giving no
PAGE-SPECs at all is equivalent to all pages of FILENAME.

See `edoc-info-normalize-page-range' for the valid formats of
PAGE-RANGE.
"

  (unless (cl-every 'consp list)
    (error "Every element should be a cons: %s" list))
  (unless (cl-every 'stringp (mapcar 'car list))
    (error "The car of every element should be a filename."))
  (unless (cl-every (lambda (elt)
                      (cl-every (lambda (page)
                                  (or (edoc-info-valid-page-spec-p page)
                                      (and (consp page)
                                           (edoc-info-valid-page-spec-p (car page))
                                           (edoc-util-edges-p (cdr page) 'relative))))
                                elt))
                    (mapcar 'cdr list))
    (error
     "The cdr of every element should be a list of page-specs"))
  (let* ((doc (edoc-virtual-document--normalize
               list (or directory default-directory)
               file-error-handler))
         (npages 0)
         document file-map)
    (while doc
      (let* ((elt (pop doc))
             (filename (car elt))
             (mapelt (assoc filename file-map))
             (page-specs (cdr elt)))
        (if mapelt
            (setcdr mapelt (cons (1+ npages) (cdr mapelt)))
          (push (list filename (1+ npages)) file-map))
        (while page-specs
          (let* ((ps (pop page-specs))
                 (first (caar ps))
                 (last (cdar ps))
                 (region (cdr ps))
                 (clx (make-edoc-virtual-range
                       :filename filename
                       :first first
                       :last last
                       :region region
                       :index-start npages)))
            (cl-incf npages (1+ (- last first)))
            (push (make-vector (1+ (- last first)) clx)
                  document)))))
    (make-edoc-virtual-document
     :page-array (apply 'vconcat (nreverse document))
     :file-map (nreverse
                (mapcar (lambda (f)
                          (setcdr f (nreverse (cdr f)))
                          f)
                        file-map)))))

(defun edoc-virtual-document--normalize (list &optional directory
                                            file-error-handler)
  (unless file-error-handler
    (setq file-error-handler
          (lambda (filename err)
            (signal (car err)
                    (append (cdr err) (list filename))))))
  (let ((default-directory
          (or directory default-directory)))
    (setq list (cl-remove-if-not
                (lambda (filename)
                  (condition-case err
                      (progn
                        (unless (file-readable-p filename)
                          (signal 'file-error
                                  (list "File not readable: " filename)))
                        (edoc-info-open filename)
                        t)
                    (error
                     (funcall file-error-handler filename err)
                     nil)))
                list
                :key 'car))
    (let* ((file-attributes (make-hash-table :test 'equal))
           (file-equal-p (lambda (f1 f2)
                           (let ((a1 (gethash f1 file-attributes))
                                 (a2 (gethash f2 file-attributes)))
                             (if (and a1 a2)
                                 (equal a1 a2)
                               (file-equal-p f1 f2)))))
           files normalized)
      ;; Optimize file-equal-p by caching file-attributes, which is slow
      ;; and would be called quadratic times otherwise.  (We don't want
      ;; the same file under different names.)
      (dolist (f (mapcar 'car list))
        (unless (find-file-name-handler f 'file-equal-p)
          (puthash f (file-attributes f) file-attributes)))
      (dolist (elt list)
        (let ((file (cl-find (car elt) files :test file-equal-p)))
          (unless file
            (push (car elt) files)
            (setq file (car elt)))
          (let ((pages (mapcar (lambda (p)
                                 (edoc-virtual-pagespec-normalize p file))
                               (or (cdr elt) '(nil))))
                newpages)
            (while pages
              (let* ((spec (pop pages))
                     (first (caar spec))
                     (last (cdar spec))
                     (region (cdr spec)))
                (while (and pages
                            (eq (1+ last)
                                (caar (car pages)))
                            (equal region (cdr (car pages))))
                  (setq last (cdar (pop pages))))
                (push `((,first . ,last) . ,region) newpages)))
            (push (cons file (nreverse newpages))
                  normalized))))
      (nreverse normalized))))

(defmacro edoc-virtual-document-defun (name args &optional documentation &rest body)
  "Define a PDF Document function.

Args are just like for `defun'.  This macro will ensure, that the
DOCUMENT argument, which should be last, is setup properly in
case it is nil, i.e. check that the buffer passes
`edoc-virtual-buffer-assert-p' and use the variable
`edoc-virtual-document'."

  (declare (doc-string 3) (indent defun)
           (debug (&define name lambda-list
                           [&optional stringp]
                           def-body)))
  (unless (stringp documentation)
    (push documentation body)
    (setq documentation nil))
  (unless (memq '&optional args)
    (setq args (append (butlast args)
                       (list '&optional)
                       (last args))))
  (when (memq '&rest args)
    (error "&rest argument not supported"))
  (let ((doc-arg (car (last args)))
        (fn (intern (format "edoc-virtual-document-%s" name))))
    `(progn
       (put ',fn 'definition-name ',name)
       (defun ,fn
           ,args ,documentation
           (setq ,doc-arg
                 (or ,doc-arg
                     (progn (edoc-virtual-buffer-assert-p)
                            edoc-virtual-document)))
           (cl-check-type ,doc-arg edoc-virtual-document)
           ,@body))))

(edoc-virtual-document-defun filenames (doc)
  "Return the list of filenames in DOC."
  (mapcar 'car (edoc-virtual-document-file-map doc)))

(edoc-virtual-document-defun normalize-pages (pages doc)
  "Normalize PAGES using DOC.

Like `edoc-info-normalize-page-range', except 0 is replaced by
DOC's last page."

  (setq pages (edoc-info-normalize-page-range pages))
  (if (eq 0 (cdr pages))
      `(,(car pages) . ,(edoc-virtual-document-number-of-pages doc))
    pages))

(edoc-virtual-document-defun page (page doc)
  "Get PAGE of DOC.

Returns a list \(FILENAME FILE-PAGE REGION\)."
  (let ((page (car (edoc-virtual-document-pages (cons page page) doc))))
    (when page
      (cl-destructuring-bind (filename first-last region)
          page
        (list filename (car first-last) region)))))

(edoc-virtual-document-defun pages (pages doc)
  "Get PAGES of DOC.

PAGES should be a cons \(FIRST . LAST\).  Return a list of
ranges corresponding to PAGES. Each element has the form

     \(FILENAME \(FILE-FIRT-PAGE . FILE-LAST-PAGE\) REGION\)
.
"

  (let ((begin (car pages))
        (end (cdr pages)))
    (unless (<= begin end)
      (error "begin should not exceed end: %s" (cons begin end)))
    (let ((arr (edoc-virtual-document-page-array doc))
          result)
      (when (or (< begin 1)
                (> end (length arr)))
        (signal 'args-out-of-range (list 'pages pages)))
      (while (<= begin end)
        (let* ((page (aref arr (1- begin)))
               (filename (edoc-virtual-range-filename page))
               (offset (- (1- begin)
                          (edoc-virtual-range-index-start page)))
               (first (+ (edoc-virtual-range-first page)
                         offset))
               (last (min (+ first (- end begin))
                          (edoc-virtual-range-last page)))
               (region (edoc-virtual-range-region page)))
          (push `(,filename (,first . ,last) ,region) result)
          (cl-incf begin (1+ (- last first)))))
      (nreverse result))))

(edoc-virtual-document-defun number-of-pages (doc)
  "Return the number of pages in DOC."
  (length (edoc-virtual-document-page-array doc)))

(edoc-virtual-document-defun page-of (filename &optional file-page limit doc)
  "Return a page number displaying FILENAME's page FILE-PAGE in DOC.

If FILE-PAGE is nil, return the first page displaying FILENAME.
If LIMIT is non-nil, it should be a range \(FIRST . LAST\) in
which the returned page should fall. This is useful if there are
more than one page displaying FILE-PAGE. LIMIT is ignored, if
FILE-PAGE is nil.

Return nil if there is no matching page."

  (if (null file-page)
      (cadr (assoc filename (edoc-virtual-document-file-map doc)))
    (let ((pages (edoc-virtual-document-page-array doc)))
      (catch 'found
        (mapc
         (lambda (pn)
           (while (and (<= pn (length pages))
                       (equal (edoc-virtual-range-filename (aref pages (1- pn)))
                              filename))
             (let* ((page (aref pages (1- pn)))
                    (first (edoc-virtual-range-first page))
                    (last (edoc-virtual-range-last page)))
               (when (and (>= file-page first)
                          (<= file-page last))
                 (let ((r (+ (edoc-virtual-range-index-start page)
                             (- file-page (edoc-virtual-range-first page))
                             1)))
                   (when (or (null limit)
                             (and (>= r (car limit))
                                  (<= r (cdr limit))))
                     (throw 'found r))))
               (cl-incf pn (1+ (- last first))))))
         (cdr (assoc filename (edoc-virtual-document-file-map doc))))
        nil))))

(edoc-virtual-document-defun find-matching-page (page predicate
                                                     &optional
                                                     backward-p doc)
  (unless (and (>= page 1)
               (<= page (length (edoc-virtual-document-page-array doc))))
    (signal 'args-out-of-range (list 'page page)))
  (let* ((pages (edoc-virtual-document-page-array doc))
         (i (1- page))
         (this (aref pages i))
         other)
    (while (and (< i (length pages))
                (>= i 0)
                (null other))
      (setq i
            (if backward-p
                (1- (edoc-virtual-range-index-start this))
              (+ (edoc-virtual-range-length this)
                 (edoc-virtual-range-index-start this))))
      (when (and (< i (length pages))
                 (>= i 0))
        (setq other (aref pages i))
        (unless (funcall predicate this other)
          (setq other nil))))
    other))

(edoc-virtual-document-defun next-matching-page (page predicate doc)
  (edoc-virtual-document-find-matching-page page predicate nil doc))

(edoc-virtual-document-defun previous-matching-page (page predicate doc)
  (declare (indent 1))
  (edoc-virtual-document-find-matching-page page predicate t doc))

(edoc-virtual-document-defun next-file (page doc)
  "Return the next page displaying a different file than PAGE.

PAGE should be a page-number."
  (let ((page (edoc-virtual-document-next-matching-page
               page
               (lambda (this other)
                 (not (equal (edoc-virtual-range-filename this)
                             (edoc-virtual-range-filename other)))))))
    (when page
      (1+ (edoc-virtual-range-index-start page)))))

(edoc-virtual-document-defun previous-file (page doc)
  "Return the previous page displaying a different file than PAGE.

PAGE should be a page-number."
  (let ((page (edoc-virtual-document-previous-matching-page
               page
               (lambda (this other)
                 (not (equal (edoc-virtual-range-filename this)
                             (edoc-virtual-range-filename other)))))))
    (when page
      (1+ (edoc-virtual-range-index-start page)))))


;; * ================================================================== *
;; * Modes
;; * ================================================================== *

(defvar edoc-virtual-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map emacs-lisp-mode-map)
    (define-key map (kbd "C-c C-c") 'edoc-virtual-view-mode)
    map))


;;;###autoload
(define-derived-mode edoc-virtual-edit-mode emacs-lisp-mode "VPDF-Edit"
  "Major mode when editing a virtual PDF buffer."
  (buffer-enable-undo)
  (setq-local buffer-read-only nil)
  (unless noninteractive
    (message (substitute-command-keys "Press \\[edoc-virtual-view-mode] to view."))))

;; FIXME: Provide filename/region from-windows-gathering functions.
(defvar edoc-virtual-view-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map edoc-view-mode-map)
    (define-key map (kbd "C-c C-c") 'edoc-virtual-edit-mode)
    (define-key map [remap backward-paragraph] 'edoc-virtual-buffer-backward-file)
    (define-key map [remap forward-paragraph] 'edoc-virtual-buffer-forward-file)
    (define-key map (kbd "C-c C-c") 'edoc-virtual-edit-mode)
    map))

;;;###autoload
(define-derived-mode edoc-virtual-view-mode edoc-view-mode "VPDF-View"
  "Major mode in virtual PDF buffers."
  (setq-local write-contents-functions nil)
  (remove-hook 'kill-buffer-hook 'edoc-view-close-document t)
  (setq-local header-line-format
              `(:eval (edoc-virtual-buffer-current-file)))
  (unless noninteractive
    (message (substitute-command-keys "Press \\[edoc-virtual-edit-mode] to edit."))))

;;;###autoload
(define-minor-mode edoc-virtual-global-minor-mode
  "Enable recognition and handling of VPDF files."
  :global t
  :group 'edoc-tools
  (let ((elt `(,edoc-virtual-magic-mode-regexp . edoc-virtual-view-mode)))
    (cond
     (edoc-virtual-global-minor-mode
      (add-to-list 'magic-mode-alist elt))
     (t
      (setq magic-mode-alist
            (remove elt magic-mode-alist))))
    (dolist (elt edoc-virtual-adapter-alist)
      (let ((fn (car elt))
            (orig (cdr elt)))
        (advice-remove orig fn)
        (when edoc-virtual-global-minor-mode
          (advice-add orig :around fn))))))

(advice-add 'edoc-virtual-view-mode
            :around 'edoc-virtual-view-mode-prepare)

;; This needs to run before edoc-view-mode does its thing.
(defun edoc-virtual-view-mode-prepare (fn)
  (let (list unreadable)
    (save-excursion
      (goto-char 1)
      (unless (looking-at edoc-virtual-magic-mode-regexp)
        (edoc-virtual-buffer-assert-p))
      (setq list (read (current-buffer))))
    (setq edoc-virtual-document
          (edoc-virtual-document-create
           list
           nil
           (lambda (filename _error)
             (push filename unreadable))))
    (when unreadable
      (display-warning
       'edoc-virtual
       (format "Some documents could not be opened:\n%s"
               (mapconcat (lambda (f)
                            (concat " " f))
                          unreadable "\n"))))
    (if (= (edoc-virtual-document-number-of-pages) 0)
        (error "Document is empty.")
      (unless edoc-virtual-global-minor-mode
        (edoc-virtual-global-minor-mode 1))
      (funcall fn))))


;; * ================================================================== *
;; * Buffer handling
;; * ================================================================== *

;;;###autoload
(defun edoc-virtual-buffer-create (&optional filenames buffer-name display-p)
  (interactive
   (list (directory-files default-directory nil "\\.pdf\\'")
         (read-string
          "Buffer name (default: all.vpdf): " nil nil "all.vpdf") t))
  (with-current-buffer (generate-new-buffer buffer-name)
    (insert ";; %VPDF 1.0\n\n")
    (insert ";; File Format
;;
;; FORMAT    ::= ( FILES* )
;; FILES     ::= ( FILE . PAGE-SPEC* )
;; PAGE-SPEC ::= PAGE | ( PAGE . REGION )
;; PAGE      ::= NUMBER | ( FIRST . LAST )
;; REGION    ::= ( LEFT TOP RIGHT BOT )
;;
;; 0 <= X <= 1, forall X in REGION .

")
    (if (null filenames)
        (insert "nil\n")
      (insert "(")
      (dolist (f filenames)
        (insert (format "(%S)\n " f)))
      (delete-char -2)
      (insert ")\n"))
    (edoc-virtual-edit-mode)
    (when display-p
      (pop-to-buffer (current-buffer)))
    (current-buffer)))

(defun edoc-virtual-buffer-p (&optional buffer)
  (save-current-buffer
    (when buffer (set-buffer buffer))
    (or (derived-mode-p 'edoc-virtual-view-mode 'edoc-virtual-edit-mode)
        edoc-virtual-document)))

(defun edoc-virtual-view-window-p (&optional window)
  (save-selected-window
    (when window (select-window window 'norecord))
    (derived-mode-p 'edoc-virtual-view-mode)))

(defun edoc-virtual-filename-p (filename)
  (and (stringp filename)
       (file-exists-p filename)
       (with-temp-buffer
         (save-excursion (insert-file-contents filename nil 0 128))
         (looking-at edoc-virtual-magic-mode-regexp))))

(defun edoc-virtual-buffer-assert-p (&optional buffer)
  (unless (edoc-virtual-buffer-p buffer)
    (error "Buffer is not a virtual PDF buffer")))

(defun edoc-virtual-view-window-assert-p (&optional window)
  (unless (edoc-virtual-view-window-p window)
    (error "Window's buffer is not in `edoc-virtual-view-mode'.")))

(defun edoc-virtual-buffer-current-file (&optional window)
  (edoc-virtual-view-window-assert-p window)
  (edoc-virtual-range-filename
   (aref (edoc-virtual-document-page-array
          edoc-virtual-document)
         (1- (edoc-view-current-page window)))))

(defun edoc-virtual-buffer-forward-file (&optional n interactive-p)
  (interactive "p\np")
  (edoc-virtual-view-window-assert-p)
  (let* ((pn (edoc-view-current-page))
         (pages (edoc-virtual-document-page-array
                 edoc-virtual-document))
         (page (aref pages (1- pn)))
         (first-filepage (1+ (edoc-virtual-range-index-start page))))

    (when (and (< n 0)
               (not (= first-filepage pn)))
      (cl-incf n))
    (setq pn first-filepage)

    (let (next)
      (while (and (> n 0)
                  (setq next (edoc-virtual-document-next-file pn)))
        (setq pn next)
        (cl-decf n)))
    (let (previous)
      (while (and (< n 0)
                  (setq previous (edoc-virtual-document-previous-file pn)))
        (setq pn previous)
        (cl-incf n)))
    (when interactive-p
      (when (< n 0)
        (message "First file."))
      (when (> n 0)
        (message "Last file.")))
    (edoc-view-goto-page pn)
    n))

(defun edoc-virtual-buffer-backward-file (&optional n interactive-p)
  (interactive "p\np")
  (edoc-virtual-buffer-forward-file (- (or n 1)) interactive-p))


;; * ================================================================== *
;; * Helper functions
;; * ================================================================== *


(defmacro edoc-virtual-dopages (bindings pages &rest body)
  (declare (indent 2) (debug (sexp form &rest form)))
  (let ((page (make-symbol "page")))
    `(dolist (,page ,pages)
       (cl-destructuring-bind ,bindings
           ,page
         ,@body))))

(defun edoc-virtual--perform-search (string pages &optional regexp-p no-error)
  (let* ((pages (edoc-virtual-document-normalize-pages pages))
         (file-pages (edoc-virtual-document-pages pages)))
    (edoc-info-compose-queries
        ((responses
          (edoc-virtual-dopages (filename pages _region)
              file-pages
            (if regexp-p
                (edoc-info-search-string string pages filename)
              ;; FIXME: no-error won't work with synchronous calls.
              (edoc-info-search-regexp string pages no-error filename)))))
      (let (result)
        (edoc-virtual-dopages (filename _ region)
          file-pages
          (let ((matches (pop responses)))
            (when region
              (setq matches
                    (mapcar
                     (lambda (m)
                       (let-alist m
                         `((edges . ,(edoc-util-edges-transform region .edges t))
                           ,@m)))
                     (edoc-virtual--filter-edges
                      region matches
                      (apply-partially 'alist-get 'edges)))))
            (dolist (m matches)
              (push `((page . ,(edoc-virtual-document-page-of
                                filename (alist-get 'page m)
                                pages))
                      ,@m)
                    result))))
        (nreverse result)))))

(defun edoc-virtual--filter-edges (region elts &optional edges-key-fn)
  (if (null region)
      elts
    (cl-remove-if-not
     (lambda (edges)
       (or (null edges)
           (if (consp (car edges))
               (cl-some (apply-partially 'edoc-util-edges-intersection region) edges)
             (edoc-util-edges-intersection region edges))))
     elts
     :key edges-key-fn)))

(defun edoc-virtual--transform-goto-dest (link filename region)
  (let-alist link
    (let ((local-page (edoc-virtual-document-page-of
                       filename .page)))
      (if local-page
          `((type . ,'goto-dest)
            (title . , .title)
            (page . ,local-page)
            (top . ,(car (edoc-util-edges-transform
                          region (cons .top .top) t))))
        `((type . ,'goto-remote)
          (title . , .title)
          (filename . ,filename)
          (page . , .page)
          (top . , .top))))))


;; * ================================================================== *
;; * Server adapter
;; * ================================================================== *

(defmacro edoc-virtual-define-adapter (name arglist &optional doc &rest body)
  ;; FIXME: Handle &optional + &rest argument.
  (declare (doc-string 3) (indent 2)
           (debug (&define name lambda-list
                           [&optional stringp]
                           def-body)))
  (unless (stringp doc)
    (push doc body)
    (setq doc nil))
  (let ((fn (intern (format "edoc-virtual-%s" name)))
        (base-fn (intern (format "edoc-info-%s" name)))
        (base-fn-arg (make-symbol "fn"))
        (true-file-or-buffer (make-symbol "true-file-or-buffer"))
        (args (cl-remove-if (lambda (elt)
                              (memq elt '(&optional &rest)))
                            arglist)))
    (unless (fboundp base-fn)
      (error "Base function is undefined: %s" base-fn))
    (unless (memq 'file-or-buffer arglist)
      (error "Argument list is missing a `file-or-buffer' argument: %s" arglist))
    `(progn
       (put ',fn 'definition-name ',name)
       (add-to-list 'edoc-virtual-adapter-alist ',(cons fn base-fn))
       (defun ,fn ,(cons base-fn-arg arglist)
         ,(format "%sPDF virtual adapter to `%s'.

This function delegates to `%s',
unless the FILE-OR-BUFFER argument denotes a VPDF document."
                  (if doc (concat doc "\n\n") "")
                  base-fn
                  base-fn)
         (let ((,true-file-or-buffer
                (cond
                 ((or (bufferp file-or-buffer)
                      (stringp file-or-buffer)) file-or-buffer)
                 ((or (null file-or-buffer)
                      ,(not (null (memq '&rest arglist))))
                  (current-buffer)))))
           (if (cond
                ((null ,true-file-or-buffer) t)
                ((bufferp ,true-file-or-buffer)
                 (not (edoc-virtual-buffer-p ,true-file-or-buffer)))
                ((stringp ,true-file-or-buffer)
                 (not (edoc-virtual-filename-p ,true-file-or-buffer))))
               (,(if (memq '&rest arglist) 'apply 'funcall) ,base-fn-arg ,@args)
             (when (stringp ,true-file-or-buffer)
               (setq ,true-file-or-buffer
                     (find-file-noselect ,true-file-or-buffer)))
             (save-current-buffer
               (when (bufferp ,true-file-or-buffer)
                 (set-buffer ,true-file-or-buffer))
               ,@body)))))))

(define-error 'edoc-virtual-unsupported-operation
  "Operation not supported in VPDF buffer")

(edoc-virtual-define-adapter open (&optional file-or-buffer password)
  (mapc (lambda (file)
          (edoc-info-open file password))
        (edoc-virtual-document-filenames)))

(edoc-virtual-define-adapter close (&optional file-or-buffer)
  (let ((files (cl-remove-if 'find-buffer-visiting
                             (edoc-virtual-document-filenames))))
    (edoc-info-compose-queries
        ((results (mapc 'edoc-info-close files)))
      (cl-some 'identity results))))

(edoc-virtual-define-adapter metadata (&optional file-or-buffer)
  (edoc-info-compose-queries
      ((md (mapc 'edoc-info-metadata (edoc-virtual-document-filenames))))
    (apply 'cl-mapcar (lambda (&rest elts)
                        (cons (caar elts)
                              (cl-mapcar 'cdr elts)))
           md)))

(edoc-virtual-define-adapter search-string (string &optional pages file-or-buffer)
  (edoc-virtual--perform-search
   string (edoc-virtual-document-normalize-pages pages)))

(edoc-virtual-define-adapter search-regexp (pcre &optional
                                                pages no-error file-or-buffer)
  (edoc-virtual--perform-search
   pcre (edoc-virtual-document-normalize-pages pages) 'regexp no-error))

(edoc-virtual-define-adapter pagelinks (page &optional file-or-buffer)
  (cl-destructuring-bind (filename ext-page region)
      (edoc-virtual-document-page page)
    (edoc-info-compose-queries
        ((links (edoc-info-pagelinks ext-page filename)))
      (mapcar
       (lambda (link)
         (let-alist link
           (if (not (eq .type 'goto-dest))
               link
             `((edges .  ,(edoc-util-edges-transform region .edges t))
               ,@(edoc-virtual--transform-goto-dest link filename region)))))
       (edoc-virtual--filter-edges region (car links) 'car)))))

(edoc-virtual-define-adapter number-of-pages (&optional file-or-buffer)
  (edoc-info-compose-queries nil (edoc-virtual-document-number-of-pages)))

(edoc-virtual-define-adapter outline (&optional file-or-buffer)
  (let ((files (edoc-virtual-document-filenames)))
    (edoc-info-compose-queries
        ((outlines (mapc 'edoc-info-outline files)))
      (cl-mapcan
       (lambda (outline filename)
         `(((depth . 1)
            (type . goto-dest)
            (title . ,filename)
            (page . ,(edoc-virtual-document-page-of filename))
            (top . 0))
           ,@(delq
              nil
              (mapcar
               (lambda (item)
                 (let-alist item
                   (if (not (eq .type 'goto-dest))
                       `((depth . ,(1+ .depth))
                         ,@item)
                     (cl-check-type filename string)
                     (let ((page (edoc-virtual-document-page-of
                                  filename .page)))
                       (when page
                         `((depth . ,(1+ .depth))
                           ,@(edoc-virtual--transform-goto-dest
                              item filename
                              (nth 2 (edoc-virtual-document-page page)))))))))
               outline))))
       outlines files))))

(edoc-virtual-define-adapter gettext (page edges &optional
                                          selection-style file-or-buffer)
  (cl-destructuring-bind (filename file-page region)
      (edoc-virtual-document-page page)
    (let ((edges (edoc-util-edges-transform region edges)))
      (edoc-info-gettext file-page edges selection-style filename))))

(edoc-virtual-define-adapter getselection (page edges &optional
                                               selection-style file-or-buffer)
  (cl-destructuring-bind (filename file-page region)
      (edoc-virtual-document-page page)
    (let ((edges (edoc-util-edges-transform region edges)))
      (edoc-info-compose-queries
          ((results (edoc-info-getselection file-page edges selection-style filename)))
        (edoc-util-edges-transform
         region
         (edoc-virtual--filter-edges region (car results)) t)))))

(edoc-virtual-define-adapter charlayout (page &optional edges-or-pos file-or-buffer)
  (cl-destructuring-bind (filename file-page region)
      (edoc-virtual-document-page page)
    (let ((edges-or-pos (edoc-util-edges-transform region edges-or-pos)))
      (edoc-info-compose-queries
          ((results (edoc-info-charlayout file-page edges-or-pos filename)))
        (mapcar (lambda (elt)
                  `(,(car elt)
                    . ,(edoc-util-edges-transform region (cdr elt) t)))
                (edoc-virtual--filter-edges region (car results) 'cadr))))))

(edoc-virtual-define-adapter pagesize (page &optional file-or-buffer)
  (cl-destructuring-bind (filename file-page region)
      (edoc-virtual-document-page page)
    (edoc-info-compose-queries
        ((result (edoc-info-pagesize file-page filename)))
      (if (null region)
          (car result)
        (edoc-util-with-edges (region)
          (edoc-util-scale
           (car result) (cons region-width region-height)))))))

(edoc-virtual-define-adapter getannots (&optional pages file-or-buffer)
  (let* ((pages (edoc-virtual-document-normalize-pages pages))
         (file-pages (edoc-virtual-document-pages pages)))
    (edoc-info-compose-queries
        ((annotations
          (edoc-virtual-dopages (filename file-pages _region)
              file-pages
            (edoc-info-getannots file-pages filename))))
      (let ((page (car pages))
            result)
        (edoc-virtual-dopages (_filename file-pages region)
            file-pages
          (dolist (a (pop annotations))
            (let ((edges (delq nil `(,(cdr (assq 'edges a))
                                     ,@(cdr (assq 'markup-edges a))))))
              (when (edoc-virtual--filter-edges region edges)
                (let-alist a
                  (setcdr (assq 'page a)
                          (+ page (- .page (car file-pages))))
                  (setcdr (assq 'id a)
                          (intern (format "%s/%d" .id (cdr (assq 'page a)))))
                  (when region
                    (when .edges
                      (setcdr (assq 'edges a)
                              (edoc-util-edges-transform region .edges t)))
                    (when .markup-edges
                      (setcdr (assq 'markup-edges a)
                              (edoc-util-edges-transform region .markup-edges t))))
                  (push a result)))))
          (cl-incf page (1+ (- (cdr file-pages) (car file-pages)))))
        (nreverse result)))))

(edoc-virtual-define-adapter getannot (id &optional file-or-buffer)
  (let ((name (symbol-name id))
        page)
    (save-match-data
      (when (string-match "\\(.*\\)/\\([0-9]+\\)\\'" name)
        (setq id  (intern (match-string 1 name))
              page (string-to-number (match-string 2 name)))))
    (if page
        (cl-destructuring-bind (filename _ _)
            (edoc-virtual-document-page page)
          (edoc-info-compose-queries
              ((result (edoc-info-getannot id filename)))
            (let ((a (car result)))
              (cl-destructuring-bind (_ _ region)
                  (edoc-virtual-document-page page)
                (setcdr (assq 'page a) page)
                (let-alist a
                  (setcdr (assq 'id a)
                          (intern (format "%s/%d" .id (cdr (assq 'page a)))))
                  (when region
                    (when .edges
                      (setcdr (assq 'edges a)
                              (edoc-util-edges-transform region .edges t)))
                    (when .markup-edges
                      (setcdr (assq 'markup-edges a)
                              (edoc-util-edges-transform region .markup-edges t))))))
              a)))
      (edoc-info-compose-queries nil
        (error "No such annotation: %s" id)))))

(edoc-virtual-define-adapter addannot (page edges type &optional
                                           file-or-buffer &rest markup-edges)
  (signal 'edoc-virtual-unsupported-operation (list 'addannot)))

(edoc-virtual-define-adapter delannot (id &optional file-or-buffer)
  (signal 'edoc-virtual-unsupported-operation (list 'delannot)))

(edoc-virtual-define-adapter mvannot (id edges &optional file-or-buffer)
  (signal 'edoc-virtual-unsupported-operation (list 'mvannot)))

(edoc-virtual-define-adapter editannot (id modifications &optional file-or-buffer)
  (signal 'edoc-virtual-unsupported-operation (list 'editannot)))

(edoc-virtual-define-adapter save (&optional file-or-buffer)
  (signal 'edoc-virtual-unsupported-operation (list 'save)))

;;(defvar-local edoc-virtual-annotation-mapping nil)

(edoc-virtual-define-adapter getattachment-from-annot
    (id &optional do-save file-or-buffer)
  (let ((name (symbol-name id))
        page)
    (save-match-data
      (when (string-match "\\(.*\\)/\\([0-9]+\\)\\'" name)
        (setq id  (intern (match-string 1 name))
              page (string-to-number (match-string 2 name)))))
    (if page
        (cl-destructuring-bind (filename _ _)
            (edoc-virtual-document-page page)
          (edoc-info-getattachment-from-annot id do-save filename))
      (edoc-info-compose-queries nil
        (error "No such annotation: %s" id)))))

(edoc-virtual-define-adapter getattachments (&optional do-save file-or-buffer)
  (edoc-info-compose-queries
      ((results (mapc
                 (lambda (f)
                   (edoc-info-getattachments do-save f))
                 (edoc-virtual-document-filenames))))
    (apply 'append results)))

(edoc-virtual-define-adapter synctex-forward-search
    (source &optional line column file-or-buffer)
  (signal 'edoc-virtual-unsupported-operation (list 'synctex-forward-search)))

(edoc-virtual-define-adapter synctex-backward-search (page &optional x y file-or-buffer)
  (cl-destructuring-bind (filename file-page region)
      (edoc-virtual-document-page page)
    (cl-destructuring-bind (x &rest y)
        (edoc-util-edges-transform region (cons x y))
      (edoc-info-synctex-backward-search file-page x y filename))))

(edoc-virtual-define-adapter renderpage (page width &optional file-or-buffer
                                             &rest commands)
  (when (keywordp file-or-buffer)
    (push file-or-buffer commands)
    (setq file-or-buffer nil))
  (cl-destructuring-bind (filename file-page region)
      (edoc-virtual-document-page page)
    (when region
      (setq commands (append (list :crop-to region) commands)
            width (edoc-util-with-edges (region)
                    (round (* width (max 1 (/ 1.0 (max 1e-6 region-width))))))))
    (apply 'edoc-info-renderpage file-page width filename commands)))

(edoc-virtual-define-adapter boundingbox (page &optional file-or-buffer)
  (cl-destructuring-bind (filename file-page region)
      (edoc-virtual-document-page page)
    (edoc-info-compose-queries
        ((results (unless region (edoc-info-boundingbox file-page filename))))
      (if region
          (list 0 0 1 1)
        (car results)))))

(edoc-virtual-define-adapter pagelabels (&optional file-or-buffer)
  (signal 'edoc-virtual-unsupported-operation (list 'pagelabels)))

(edoc-virtual-define-adapter setoptions (&optional file-or-buffer &rest options)
  (when (keywordp file-or-buffer)
    (push file-or-buffer options)
    (setq file-or-buffer nil))
  (edoc-info-compose-queries
      ((_ (dolist (f (edoc-virtual-document-filenames))
            (apply 'edoc-info-setoptions f options))))
    nil))

(edoc-virtual-define-adapter getoptions (&optional file-or-buffer)
  (signal 'edoc-virtual-unsupported-operation (list 'getoptions)))

(edoc-virtual-define-adapter encrypted-p (&optional file-or-buffer)
  nil)

(provide 'edoc-virtual)
;;; edoc-virtual.el ends here
