;;; edoc-links.el --- Handle PDF links. -*- lexical-binding: t -*-

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

(require 'edoc-info)
(require 'edoc-util)
(require 'edoc-misc)
(require 'edoc-cache)
(require 'edoc-isearch)
(require 'let-alist)
(require 'org)

;;; Code:



;; * ================================================================== *
;; * Customizations
;; * ================================================================== *

(defgroup edoc-links nil
  "Following links in PDF documents."
  :group 'edoc-tools)

(defface edoc-links-read-link
  '((((background dark)) (:background "red" :foreground "yellow"))
    (((background light)) (:background "red" :foreground "yellow")))
  "Face used to determine the colors when reading links."
  ;; :group 'edoc-links
  :group 'edoc-tools-faces)

(defcustom edoc-links-read-link-convert-commands
  '(;;"-font" "FreeMono"
    "-pointsize" "%P"
    "-undercolor" "%f"
    "-fill" "%b"
    "-draw" "text %X,%Y '%c'")

  "The commands for the convert program, when decorating links for reading.
See `edoc-util-convert' for an explanation of the format.

Aside from the description there, two additional escape chars are
available.

%P -- The scaled font pointsize, i.e. IMAGE-WIDTH * SCALE (See
 `edoc-links-convert-pointsize-scale').
%c -- String describing the current link key (e.g. AA, AB,
 etc.)."
  :group 'edoc-links
  :type '(repeat string)
  :link '(variable-link edoc-isearch-convert-commands)
  :link '(url-link "http://www.imagemagick.org/script/convert.php"))

(defcustom edoc-links-convert-pointsize-scale 0.01
  "The scale factor for the -pointsize convert command.

This determines the relative size of the font, when interactively
reading links."
  :group 'edoc-links
  :type '(restricted-sexp :match-alternatives
                          ((lambda (x) (and (numberp x)
                                            (<= x 1)
                                            (>= x 0))))))

(defcustom edoc-links-browse-uri-function
  'edoc-links-browse-uri-default
  "The function for handling uri links.

This function should accept one argument, the URI to follow, and
do something with it."
  :group 'edoc-links
  :type 'function)


;; * ================================================================== *
;; * Minor Mode
;; * ================================================================== *

(defvar edoc-links-minor-mode-map
  (let ((kmap (make-sparse-keymap)))
    (define-key kmap (kbd "f") 'edoc-links-isearch-link)
    (define-key kmap (kbd "F") 'edoc-links-action-perform)
    kmap))

;;;###autoload
(define-minor-mode edoc-links-minor-mode
  "Handle links in PDF documents.\\<edoc-links-minor-mode-map>

If this mode is enabled, most links in the document may be
activated by clicking on them or by pressing \\[edoc-links-action-perform] and selecting
one of the displayed keys, or by using isearch limited to
links via \\[edoc-links-isearch-link].

\\{edoc-links-minor-mode-map}"
  :group 'edoc-links
  (edoc-util-assert-edoc-buffer)
  (cond
   (edoc-links-minor-mode
    (edoc-view-add-hotspot-function 'edoc-links-hotspots-function 0))
   (t
    (edoc-view-remove-hotspot-function 'edoc-links-hotspots-function)))
  (edoc-view-redisplay t))

(defun edoc-links-hotspots-function (page size)
  "Create hotspots for links on PAGE using SIZE."

  (let ((links (edoc-cache-pagelinks page))
        (id-fmt "link-%d-%d")
        (i 0)
        (pointer 'hand)
        hotspots)
    (dolist (l links)
      (let ((e (edoc-util-scale
                (cdr (assq 'edges l)) size 'round))
            (id (intern (format id-fmt page
                                (cl-incf i)))))
        (push `((rect . ((,(nth 0 e) . ,(nth 1 e))
                         . (,(nth 2 e) . ,(nth 3 e))))
                ,id
                (pointer
                 ,pointer
                 help-echo ,(edoc-links-action-to-string l)))
              hotspots)
        (local-set-key
         (vector id 'mouse-1)
         (lambda nil
           (interactive "@")
           (edoc-links-action-perform l)))
        (local-set-key
         (vector id t)
         'edoc-util-image-map-mouse-event-proxy)))
    (nreverse hotspots)))

(defun edoc-links-action-to-string (link)
  "Return a string representation of ACTION."
  (let-alist link
    (concat
     (cl-case .type
       (goto-dest
        (if (> .page 0)
            (format "Goto page %d" .page)
          "Destination not found"))
       (goto-remote
        (if (and .filename (file-exists-p .filename))
            (format "Goto %sfile '%s'"
                    (if (> .page 0)
                        (format "p.%d of " .page)
                      "")
                    .filename)
          (format "Link to nonexistent file '%s'" .filename)))
       (uri
        (if (> (length .uri) 0)
            (format "Link to uri '%s'" .uri)
          (format "Link to empty uri")))
       (t (format "Unrecognized link type: %s" .type)))
     (if (> (length .title) 0)
         (format " (%s)" .title)))))

;;;###autoload
(defun edoc-links-action-perform (link)
  "Follow LINK, depending on its type.

This may turn to another page, switch to another PDF buffer or
invoke `edoc-links-browse-uri-function'.

Interactively, link is read via `edoc-links-read-link-action'.
This function displays characters around the links in the current
page and starts reading characters (ignoring case).  After a
sufficient number of characters have been read, the corresponding
link's link is invoked.  Additionally, SPC may be used to
scroll the current page."
  (interactive
   (list (or (edoc-links-read-link-action "Activate link (SPC scrolls): ")
             (error "No link selected"))))
  (let-alist link
    (cl-case .type
      ((goto-dest goto-remote)
       (let ((window (selected-window)))
         (cl-case .type
           (goto-dest
            (unless (> .page 0)
              (error "Link points to nowhere")))
           (goto-remote
            (unless (and .filename (file-exists-p .filename))
              (error "Link points to nonexistent file %s" .filename))
            (setq window (display-buffer
                          (or (find-buffer-visiting .filename)
                              (find-file-noselect .filename))))))
         (with-selected-window window
           (when (derived-mode-p 'edoc-view-mode)
             (when (> .page 0)
               (edoc-view-goto-page .page))
             (when .top
               ;; Showing the tooltip delays displaying the page for
               ;; some reason (sit-for/redisplay don't help), do it
               ;; later.
               (run-with-idle-timer 0.001 nil
                 (lambda ()
                   (when (window-live-p window)
                     (with-selected-window window
                       (when (derived-mode-p 'edoc-view-mode)
                         (edoc-util-tooltip-arrow .top)))))))))))
      (uri
       (funcall edoc-links-browse-uri-function .uri))
      (t
       (error "Unrecognized link type: %s" .type)))
    nil))

(defun edoc-links-read-link-action (prompt)
  "Using PROMPT, interactively read a link-action.

See `edoc-links-action-perform' for the interface."

  (edoc-util-assert-edoc-window)
  (let* ((links (edoc-cache-pagelinks
                 (edoc-view-current-page)))
         (keys (edoc-links-read-link-action--create-keys
                (length links)))
         (key-strings (mapcar (apply-partially 'apply 'string)
                              keys))
         (alist (cl-mapcar 'cons keys links))
         (size (edoc-view-image-size))
         (colors (edoc-util-face-colors
                  'edoc-links-read-link edoc-view-dark-minor-mode))
         (args (list
                :foreground (car colors)
                :background (cdr colors)
                :formats
                 `((?c . ,(lambda (_edges) (pop key-strings)))
                   (?P . ,(number-to-string
                           (max 1 (* (cdr size)
                                     edoc-links-convert-pointsize-scale)))))
                 :commands edoc-links-read-link-convert-commands
                 :apply (edoc-util-scale-relative-to-pixel
                         (mapcar (lambda (l) (cdr (assq 'edges l)))
                                 links)))))
    (unless links
      (error "No links on this page"))
    (unwind-protect
        (let ((image-data
               (edoc-cache-get-image
                (edoc-view-current-page)
                (car size) (car size) 'edoc-links-read-link-action)))
          (unless image-data
            (setq image-data (apply 'edoc-util-convert-page args ))
            (edoc-cache-put-image
             (edoc-view-current-page)
             (car size) image-data 'edoc-links-read-link-action))
          (edoc-view-display-image
           (create-image image-data (edoc-view-image-type) t))
          (edoc-links-read-link-action--read-chars prompt alist))
      (edoc-view-redisplay))))

(defun edoc-links-read-link-action--read-chars (prompt alist)
  (catch 'done
    (let (key)
      (while t
        (let* ((chars (append (mapcar 'caar alist)
                              (mapcar 'downcase (mapcar 'caar alist))
                              (list ?\s)))
               (ch (read-char-choice prompt chars)))
          (setq ch (upcase ch))
          (cond
           ((= ch ?\s)
            (when (= (window-vscroll) (image-scroll-up))
              (image-scroll-down (window-vscroll))))
           (t
            (setq alist (delq nil (mapcar (lambda (elt)
                                            (and (eq ch (caar elt))
                                                 (cons (cdar elt)
                                                       (cdr elt))))
                                          alist))
                  key (append key (list ch))
                  prompt (concat prompt (list ch)))
            (when (= (length alist) 1)
              (message nil)
              (throw 'done (cdar alist))))))))))

(defun edoc-links-read-link-action--create-keys (n)
  (when (> n 0)
    (let ((len (1+ (floor (log n 26))))
          keys)
      (dotimes (i n)
        (let (key)
          (dotimes (_x len)
            (push (+ (% i 26) ?A) key)
            (setq i (/ i 26)))
          (push key keys)))
      (nreverse keys))))

(defun edoc-links-isearch-link ()
  (interactive)
  (let* (quit-p
         (isearch-mode-end-hook
          (cons (lambda nil
                  (setq quit-p isearch-mode-end-hook-quit))
                isearch-mode-end-hook))
         (edoc-isearch-filter-matches-function
          'edoc-links-isearch-link-filter-matches)
         (edoc-isearch-narrow-to-page t)
         (isearch-message-prefix-add "(Links)")
         edoc-isearch-batch-mode)
    (isearch-forward)
    (unless (or quit-p (null edoc-isearch-current-match))
      (let* ((page (edoc-view-current-page))
             (match (car edoc-isearch-current-match))
             (size (edoc-view-image-size))
             (links (sort (cl-remove-if
                           (lambda (e)
                             (= 0 (edoc-util-edges-intersection-area (car e) match)))
                           (mapcar (lambda (l)
                                     (cons (edoc-util-scale (alist-get 'edges l) size)
                                           l))
                                   (edoc-cache-pagelinks page)))
                          (lambda (e1 e2)
                            (> (edoc-util-edges-intersection-area
                                (alist-get 'edges e1) match)
                               (edoc-util-edges-intersection-area
                                (alist-get 'edges e2) match))))))
        (unless links
          (error "No link found at this position"))
        (edoc-links-action-perform (car links))))))

(defun edoc-links-isearch-link-filter-matches (matches)
  (let ((links (edoc-util-scale
                (mapcar (apply-partially 'alist-get 'edges)
                        (edoc-cache-pagelinks
                         (edoc-view-current-page)))
                (edoc-view-image-size))))
    (cl-remove-if-not
     (lambda (m)
       (cl-some
        (lambda (edges)
          (cl-some (lambda (link)
                     (edoc-util-with-edges (link edges)
                       (let ((area (min (* link-width link-height)
                                        (* edges-width edges-height))))
                         (>  (/  (edoc-util-edges-intersection-area edges link)
                                 (float area)) 0.5))))
                   links))
        m))
     matches)))

(defun edoc-links-browse-uri-default (uri)
  "Open the string URI using Org.

Wraps the URI in \[\[ ... \]\] and calls `org-open-link-from-string'
on the resulting string."
  (cl-check-type uri string)
  (message "Opening `%s' with Org" uri)
  (cond
   ((fboundp 'org-link-open-from-string)
    (org-link-open-from-string (format "[[%s]]" uri)))
   ;; For Org 9.2 and older
   ((fboundp 'org-open-link-from-string)
    (org-open-link-from-string (format "[[%s]]" uri)))))

(provide 'edoc-links)

;;; edoc-links.el ends here
