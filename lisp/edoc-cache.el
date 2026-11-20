;;; edoc-cache.el --- Cache time-critical or frequent kc queries. -*- lexical-binding:t -*-

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
;;
;;; Code:
;;

(require 'edoc-macs)
(require 'edoc-info)
(require 'edoc-util)


;; * ================================================================== *
;; * Customiazations
;; * ================================================================== *

(defcustom edoc-cache-image-limit 64
  "Maximum number of cached PNG images per buffer."
  :type 'integer
  :group 'edoc-cache
  :group 'edoc-view)

(defcustom edoc-cache-prefetch-delay 0.5
  "Idle time in seconds before prefetching images starts."
  :group 'edoc-view
  :type 'number)

(defcustom edoc-cache-prefetch-pages-function
  'edoc-cache-prefetch-pages-function-default
  "A function returning a list of pages to be prefetched.

It is called with no arguments in the PDF window and should
return a list of page-numbers, determining the pages that should
be prefetched and their order."
  :group 'edoc-view
  :type 'function)


;; * ================================================================== *
;; * Simple Value cache
;; * ================================================================== *

(defvar-local edoc-cache--data nil)

(defvar edoc-annot-modified-functions)

(defun edoc-cache--initialize ()
  "Initialize the cache to store document data.

Note: The cache is only initialized once. After that it needs to
be cleared before this function makes any changes to it. This is
an internal function and not meant to be directly used."
  (unless edoc-cache--data
    (setq edoc-cache--data (make-hash-table))
    (add-hook 'edoc-info-close-document-hook #'edoc-cache-clear-data nil t)
    (add-hook 'edoc-annot-modified-functions
              #'edoc-cache--clear-data-of-annotations
              nil t)))

(defun edoc-cache--clear-data-of-annotations (fn)
  "Clear the data cache when annotations are modified.

FN is a closure as described in `edoc-annot-modified-functions'.

Note: This is an internal function and not meant to be directly used."
  (apply #'edoc-cache-clear-data-of-pages
         (mapcar (lambda (a)
                   (cdr (assq 'page a)))
                 (funcall fn t))))

(defun edoc-cache--data-put (key value &optional page)
  "Put KEY with VALUE in the cache of PAGE, return value."
  (edoc-cache--initialize)
  (puthash page (cons (cons key value)
                      (assq-delete-all
                       key
                       (gethash page edoc-cache--data)))
           edoc-cache--data)
  value)

(defun edoc-cache--data-get (key &optional page)
  "Get value of KEY in the cache of PAGE.

Returns a cons \(HIT . VALUE\), where HIT is non-nil if KEY was
stored previously for PAGE and VALUE its value.  Otherwise HIT
is nil and VALUE undefined."
  (edoc-cache--initialize)
  (let ((elt (assq key (gethash page edoc-cache--data))))
    (if elt
        (cons t (cdr elt))
      (cons nil nil))))

(defun edoc-cache--data-clear (key &optional page)
  "Remove KEY from the cache of PAGE."
  (edoc-cache--initialize)
  (puthash page
           (assq-delete-all key (gethash page edoc-cache--data))
           edoc-cache--data)
  nil)

(defun edoc-cache-clear-data-of-pages (&rest pages)
  "Remove all PAGES from the cache."
  (when edoc-cache--data
    (dolist (page pages)
      (remhash page edoc-cache--data))))

(defun edoc-cache-clear-data ()
  "Remove the entire cache."
  (interactive)
  (when edoc-cache--data
    (clrhash edoc-cache--data)))

(defmacro define-edoc-cache-function (command &optional page-arg-p)
  "Define a simple data cache function.

COMMAND is the name of the command, e.g. number-of-pages.  It
should have a corresponding edoc-info function.  If PAGE-ARG-P is
non-nil, define a one-dimensional cache indexed by the page
number. Otherwise the value is constant for each document, like
e.g. number-of-pages.

Both args are unevaluated."

  (let ((args (if page-arg-p (list 'page)))
        (fn (intern (format "edoc-cache-%s" command)))
        (ifn (intern (format "edoc-info-%s" command)))
        (doc (format "Cached version of `edoc-info-%s', which see.

Make sure, not to modify its return value." command)))
    `(defun ,fn ,args
       ,doc
       (let ((hit-value (edoc-cache--data-get ',command ,(if page-arg-p 'page))))
         (if (car hit-value)
             (cdr hit-value)
           (edoc-cache--data-put
            ',command
            ,(if page-arg-p
                 (list ifn 'page)
               (list ifn))
            ,(if page-arg-p 'page)))))))

(define-edoc-cache-function pagelinks t)
(define-edoc-cache-function number-of-pages)
;; The boundingbox may change if annotations change.
(define-edoc-cache-function boundingbox t)
(define-edoc-cache-function textregions t)
(define-edoc-cache-function pagesize t)


;; * ================================================================== *
;; * PNG image LRU cache
;; * ================================================================== *

(defvar edoc-cache-image-inihibit nil
  "Non-nil, if the image cache should be bypassed.")

(defvar-local edoc-cache--image-cache nil)

(defmacro edoc-cache--make-image (page width data hash)
  "Make the image that we store in the image cache.

An image is a tuple of PAGE WIDTH DATA HASH."
  `(list ,page ,width ,data ,hash))
(defmacro edoc-cache--image/page (img)
  "Return the page value for IMG."
  `(nth 0 ,img))
(defmacro edoc-cache--image/width (img)
  "Return the width value for IMG."
  `(nth 1 ,img))
(defmacro edoc-cache--image/data (img)
  "Return the data value for IMG."
  `(nth 2 ,img))
(defmacro edoc-cache--image/hash (img)
  "Return the hash value for IMG."
  `(nth 3 ,img))

(defun edoc-cache--image-match (image page min-width &optional max-width hash)
  "Match IMAGE with specs.

IMAGE should be a list as created by `edoc-cache--make-image'.

Return non-nil, if IMAGE's page is the same as PAGE, its width
is at least MIN-WIDTH and at most MAX-WIDTH and its stored
hash-value is `eql' to HASH."
  (and (= (edoc-cache--image/page image)
          page)
       (or (null min-width)
           (>= (edoc-cache--image/width image)
               min-width))
       (or (null max-width)
           (<= (edoc-cache--image/width image)
               max-width))
       (eql (edoc-cache--image/hash image)
            hash)))

(defun edoc-cache-lookup-image (page min-width &optional max-width hash)
  "Return PAGE's cached PNG data as a string or nil.

Return an image of at least MIN-WIDTH and, if non-nil, maximum
width MAX-WIDTH and `eql' HASH value.

Does not modify the cache.  See also `edoc-cache-get-image'."
  (let ((image (car (cl-member
                     (list page min-width max-width hash)
                     edoc-cache--image-cache
                     :test (lambda (spec image)
                             (apply #'edoc-cache--image-match image spec))))))
    (and image
         (edoc-cache--image/data image))))

(defun edoc-cache-get-image (page min-width &optional max-width hash)
  "Return PAGE's PNG data as a string.

Return an image of at least MIN-WIDTH and, if non-nil, maximum
width MAX-WIDTH and `eql' HASH value.

Remember that image was recently used.

Returns nil, if no matching image was found."
  (let ((cache edoc-cache--image-cache)
        image)
    ;; Find it in the cache.
    (while (and (setq image (pop cache))
                (not (edoc-cache--image-match
                      image page min-width max-width hash))))
    ;; Remove it and push it to the front.
    (when image
      (setq edoc-cache--image-cache
            (cons image (delq image edoc-cache--image-cache)))
      (edoc-cache--image/data image))))

(defun edoc-cache-put-image (page width data &optional hash)
  "Cache image of PAGE with WIDTH, DATA and HASH.

DATA should the string of a PNG image of width WIDTH and from
page PAGE in the current buffer.  See `edoc-cache-get-image' for
the HASH argument.

This function always returns nil."
  (unless edoc-cache--image-cache
    (add-hook 'edoc-info-close-document-hook #'edoc-cache-clear-images nil t)
    (add-hook 'edoc-annot-modified-functions
              #'edoc-cache--clear-images-of-annotations nil t))
  (push (edoc-cache--make-image page width data hash)
        edoc-cache--image-cache)
  ;; Forget old image(s).
  (when (> (length edoc-cache--image-cache)
           edoc-cache-image-limit)
    (if (> edoc-cache-image-limit 1)
        (setcdr (nthcdr (1- edoc-cache-image-limit)
                        edoc-cache--image-cache)
                nil)
      (setq edoc-cache--image-cache nil)))
  nil)

(defun edoc-cache-clear-images ()
  "Clear the image cache."
  (setq edoc-cache--image-cache nil))

(defun edoc-cache-clear-images-if (fn)
  "Remove images from the cache according to FN.

FN should be function accepting 4 Arguments \(PAGE WIDTH DATA
HASH\).  It should return non-nil, if the image should be removed
from the cache."
  (setq edoc-cache--image-cache
        (cl-remove-if
         (lambda (image)
           (funcall
            fn
            (edoc-cache--image/page image)
            (edoc-cache--image/width image)
            (edoc-cache--image/data image)
            (edoc-cache--image/hash image)))
         edoc-cache--image-cache)))


(defun edoc-cache--clear-images-of-annotations (fn)
  "Clear the images cache when annotations are modified.

FN is a closure as described in `edoc-annot-modified-functions'.

Note: This is an internal function and not meant to be directly used."
  (apply #'edoc-cache-clear-images-of-pages
         (mapcar (lambda (a)
                   (cdr (assq 'page a)))
                 (funcall fn t))))

(defun edoc-cache-clear-images-of-pages (&rest pages)
  "Remove all images of PAGES from the image cache."
  (edoc-cache-clear-images-if
   (lambda (page &rest _) (memq page pages))))

(defun edoc-cache-renderpage (page min-width &optional max-width)
  "Render PAGE according to MIN-WIDTH and MAX-WIDTH.

Return the PNG data of an image as a string, such that its width
is at least MIN-WIDTH and, if non-nil, at most MAX-WIDTH.

If such an image is not available in the cache, call
`edoc-info-renderpage' to create one."
  (if edoc-cache-image-inihibit
      (edoc-info-renderpage page min-width)
    (or (edoc-cache-get-image page min-width max-width)
        (let ((data (edoc-info-renderpage page min-width)))
          (edoc-cache-put-image page min-width data)
          data))))

(defun edoc-cache-renderpage-text-regions (page width single-line-p
                                               &rest selection)
  "Render PAGE according to WIDTH, SINGLE-LINE-P and SELECTION.

See also `edoc-info-renderpage-text-regions' and
`edoc-cache-renderpage'."
  (if edoc-cache-image-inihibit
      (apply #'edoc-info-renderpage-text-regions
             page width single-line-p nil nil selection)
    (let ((hash (sxhash
                 (format "%S" (cons 'renderpage-text-regions
                                    (cons single-line-p selection))))))
      (or (edoc-cache-get-image page width width hash)
          (let ((data (apply #'edoc-info-renderpage-text-regions
                             page width single-line-p nil nil selection)))
            (edoc-cache-put-image page width data hash)
            data)))))

(defun edoc-cache-renderpage-highlight (page width &rest regions)
  "Highlight PAGE according to WIDTH and REGIONS.

See also `edoc-info-renderpage-highlight' and
`edoc-cache-renderpage'."
  (if edoc-cache-image-inihibit
      (apply #'edoc-info-renderpage-highlight
             page width nil regions)
    (let ((hash (sxhash
                 (format "%S" (cons 'renderpage-highlight
                                    regions)))))
      (or (edoc-cache-get-image page width width hash)
          (let ((data (apply #'edoc-info-renderpage-highlight
                             page width nil regions)))
            (edoc-cache-put-image page width data hash)
            data)))))


;; * ================================================================== *
;; * Prefetching images
;; * ================================================================== *

(defvar-local edoc-cache--prefetch-pages nil
  "Pages to be prefetched.")

(defvar-local edoc-cache--prefetch-timer nil
  "Timer used when prefetching images.")

(define-minor-mode edoc-cache-prefetch-minor-mode
  "Try to load images which will probably be needed in a while."
  :group 'edoc-cache
  (edoc-cache--prefetch-cancel)
  (cond
   (edoc-cache-prefetch-minor-mode
    (edoc-util-assert-edoc-buffer)
    (add-hook 'pre-command-hook #'edoc-cache--prefetch-stop nil t)
    ;; FIXME: Disable the time when the buffer is killed or its
    ;; major-mode changes.
    (setq edoc-cache--prefetch-timer
          (run-with-idle-timer (or edoc-cache-prefetch-delay 1) t
                               #'edoc-cache--prefetch-start (current-buffer))))
   (t
    (remove-hook 'pre-command-hook #'edoc-cache--prefetch-stop t))))

(defun edoc-cache-prefetch-pages-function-default ()
  "The default function to prefetch pages.

See `edoc-cache-prefetch-pages-function' for an explanation of
what this function does."
  (let ((page (edoc-view-current-page)))
    (edoc-util-remove-duplicates
     (cl-remove-if-not
      (lambda (page)
        (and (>= page 1)
             (<= page (edoc-cache-number-of-pages))))
      (append
       ;; +1, -1, +2, -2, ...
       (let ((sign 1)
             (incr 1))
         (mapcar (lambda (_)
                   (setq page (+ page (* sign incr))
                         sign (- sign)
                         incr (1+ incr))
                   page)
                 (number-sequence 1 16)))
       ;; First and last
       (list 1 (edoc-cache-number-of-pages))
       ;; Links
       (mapcar
        (apply-partially 'alist-get 'page)
        (cl-remove-if-not
         (lambda (link) (eq (alist-get 'type link) 'goto-dest))
         (edoc-cache-pagelinks
          (edoc-view-current-page)))))))))

(defvar edoc-view-use-scaling)
(defun edoc-cache--prefetch-pages (window image-width)
  "Internal function to prefetch pages and store them in the cache.

WINDOW and IMAGE-WIDTH decide the page and scale of the final image."
  (when (and (eq window (selected-window))
             (edoc-util-edoc-buffer-p))
    (let ((page (pop edoc-cache--prefetch-pages)))
      (while (and page
                  (edoc-cache-lookup-image
                   page
                   image-width
                   (if edoc-view-use-scaling
                       (* 2 image-width)
                     image-width)))
        (setq page (pop edoc-cache--prefetch-pages)))
      (edoc-util-debug
        (when (null page)
          (message  "Prefetching done.")))
      (when page
        (let* ((buffer (current-buffer))
               (edoc-info-asynchronous
                (lambda (status data)
                  (when (and (null status)
                             (eq window
                                 (selected-window))
                             (eq buffer (window-buffer)))
                    (with-current-buffer (window-buffer)
                      (when (derived-mode-p 'edoc-view-mode)
                        (edoc-cache-put-image
                         page image-width data)
                        (image-size (edoc-view-create-page page))
                        (edoc-util-debug
                          (message "Prefetched page %s." page))
                        ;; Avoid max-lisp-eval-depth
                        (run-with-timer
                         0.001 nil
                         #'edoc-cache--prefetch-pages window image-width)))))))
          (condition-case err
              (edoc-info-renderpage page image-width)
            (error
             (edoc-cache-prefetch-minor-mode -1)
             (signal (car err) (cdr err)))))))))

(defvar edoc-cache--prefetch-started-p nil
  "Guard against multiple prefetch starts.

Used solely in `edoc-cache--prefetch-start'.")

(defun edoc-cache--prefetch-start (buffer)
  "Start prefetching images in BUFFER."
  (when (and edoc-cache-prefetch-minor-mode
             (not edoc-cache--prefetch-started-p)
             (edoc-util-edoc-buffer-p)
             (not isearch-mode)
             (null edoc-cache--prefetch-pages)
             (eq (window-buffer) buffer)
             (fboundp edoc-cache-prefetch-pages-function))
    (let* ((edoc-cache--prefetch-started-p t)
           (pages (funcall edoc-cache-prefetch-pages-function)))
      (setq edoc-cache--prefetch-pages
            (butlast pages (max 0 (- (length pages)
                                     edoc-cache-image-limit))))
      (edoc-cache--prefetch-pages
       (selected-window)
       (car (edoc-view-desired-image-size))))))

(defun edoc-cache--prefetch-stop ()
  "Stop prefetching images in current buffer."
  (setq edoc-cache--prefetch-pages nil))

(defun edoc-cache--prefetch-cancel ()
  "Cancel prefetching images in current buffer."
  (edoc-cache--prefetch-stop)
  (when edoc-cache--prefetch-timer
    (cancel-timer edoc-cache--prefetch-timer))
  (setq edoc-cache--prefetch-timer nil))

(provide 'edoc-cache)
;;; edoc-cache.el ends here
