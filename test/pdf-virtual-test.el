;; -*- lexical-binding: t -*-

(require 'edoc-virtual)
(require 'ert)

(defvar edoc-virtual-test-document
  '(("test.pdf"
     ;; Annotations 3,4,5
     (2 . (0.1805 0.2462 0.4046 0.3392))
     ;; Should match first paragraph.
     (1 . (0.2163 0.1879 0.7848 0.22))
     4 3 5 6)))

(defmacro with-edoc-virtual-test-document (var &rest body)
  (declare (indent 1) (debug t))
  `(let ((,var (edoc-virtual-document-create
                edoc-virtual-test-document)))
     ,@body))

(defmacro with-edoc-virtual-test-buffer (&rest body)
  (declare (indent 0) (debug t))
  `(let ((doc edoc-virtual-test-document))
     (edoc-info-process-assert-running t)
     (with-temp-buffer
       (insert ";; %VPDF 1.0\n\n")
       (let (print-length)
         (pp doc (current-buffer)))
       (edoc-virtual-view-mode)
       (progn ,@body))))

(ert-deftest edoc-virtual-document-create ()
  (let ((doc (edoc-virtual-document-create
              edoc-virtual-test-document)))
    (should (edoc-virtual-document-p doc))
    (should (= (length (edoc-virtual-document-page-array doc))
               6))
    (should (equal (edoc-virtual-document-file-map doc)
                   '(("test.pdf" 1))))))

(ert-deftest edoc-virtual-document-filenames ()
  (with-edoc-virtual-test-document doc
                                  (should (equal (edoc-virtual-document-filenames doc)
                                                 '("test.pdf")))))

(ert-deftest edoc-virtual-document-pages ()
  (with-edoc-virtual-test-document doc
                                  (should (equal '(("test.pdf" (4 . 4) nil)
                                                   ("test.pdf" (3 . 3) nil)
                                                   ("test.pdf" (5 . 6) nil))
                                                 (edoc-virtual-document-pages '(3 . 6) doc)))))

(ert-deftest edoc-virtual-document-page ()
  (with-edoc-virtual-test-document doc
                                  (should (equal '("test.pdf" 6 nil)
                                                 (edoc-virtual-document-page 6 doc)))))

(ert-deftest edoc-virtual-document-page-of ()
  (with-edoc-virtual-test-document doc
                                  (let ((pages '(2 1 4 3 5 6)))
                                    (dotimes (i (length pages))
                                      (should (equal (1+ i)
                                                     (edoc-virtual-document-page-of
                                                      "test.pdf" (nth i pages) nil doc)))))))

(ert-deftest edoc-virtual-open ()
  (with-edoc-virtual-test-buffer
   (should (progn (edoc-info-open) t))))

(ert-deftest edoc-virtual-close ()
  (with-edoc-virtual-test-buffer
   (should (progn (edoc-info-close) t))))

(ert-deftest edoc-virtual-metadata ()
  (with-edoc-virtual-test-buffer
   (should (consp (edoc-info-metadata)))))

(ert-deftest edoc-virtual-search ()
  (with-edoc-virtual-test-buffer
   (dolist (m (list (edoc-info-search-string "PDF" 2)
                    (edoc-info-search-regexp "PDF" 2)))
     (should (= 2 (length m)))
     (should (equal (mapcar (apply-partially 'alist-get 'page)
                            m)
                    '(2 2)))
     (should (cl-every (lambda (elt)
                         (cl-every 'edoc-test-relative-edges-p elt))
                       (mapcar (apply-partially 'alist-get 'edges)
                               m))))))

(ert-deftest edoc-virtual-pagelinks ()
  (with-edoc-virtual-test-buffer
   (let ((links (edoc-info-pagelinks 4)))
     (should (cl-every 'edoc-test-relative-edges-p
                       (mapcar (apply-partially 'alist-get 'edges)
                               links)))
     (should (equal (mapcar (apply-partially 'alist-get 'type)
                            links)
                    '(goto-dest uri)))
     (should (equal (mapcar (apply-partially 'alist-get 'uri)
                            links)
                    '(nil "http://www.gnu.org"))))))

(ert-deftest edoc-virtual-number-of-pages ()
  (with-edoc-virtual-test-buffer
   (should (= 6 (edoc-info-number-of-pages)))))

(ert-deftest edoc-virtual-outline ()
  (with-edoc-virtual-test-buffer
   (let ((outline (edoc-info-outline)))
     (should (= 8 (length outline)))
     (should (equal (mapcar (apply-partially 'alist-get 'depth)
                            outline)
                    '(1 2 2 2 2 2 3 4)))
     (should (cl-every (lambda (type)
                         (equal type 'goto-dest))
                       (mapcar (apply-partially 'alist-get 'type)
                               (cdr outline)))))))

(ert-deftest edoc-virtual-gettext ()
  (with-edoc-virtual-test-buffer
   (let ((text (edoc-info-gettext 2 '(0 0 1 1))))
     (should
      (= 2 (with-temp-buffer
             (insert text)
             (count-matches "PDF" 1 (point))))))))

(ert-deftest edoc-virtual-getselection ()
  (with-edoc-virtual-test-buffer
   (should (consp (edoc-info-getselection 1 '(0 0 1 1))))
   (should (cl-every 'edoc-test-relative-edges-p
                     (edoc-info-getselection 1 '(0 0 1 1))))))

(ert-deftest edoc-virtual-charlayout ()
  (with-edoc-virtual-test-buffer
   (let ((cl (edoc-info-charlayout 1)))
     (should (eq ?3 (car (car cl))))
     (should (eq ?y (car (car (last cl)))))
     (should (cl-every 'characterp (mapcar 'car cl)))
     (should (cl-every
              (apply-partially
               'cl-every 'edoc-test-relative-edges-p)
              (mapcar 'cdr cl))))))

(ert-deftest edoc-virtual-pagesize ()
  (with-edoc-virtual-test-buffer
   (let* ((os '(612 . 792))
          (s (edoc-info-pagesize 1))
          (ds (cons (* (- 0.4046 0.1879) (car os))
                    (* (- 0.3392 0.2462) (cdr os)))))
     (should (< (abs (- (car s) (car ds))) 10))
     (should (< (abs (- (cdr s) (cdr ds))) 10)))))

(ert-deftest edoc-virtual-getannots ()
  (with-edoc-virtual-test-buffer
   (let ((a (edoc-info-getannots 1)))
     (should (= 3 (length a)))
     (should (equal (sort (copy-sequence '(highlight underline squiggly))
                          'string<)
                    (sort (mapcar (lambda (elt)
                                    (cdr (assq 'type elt)))
                                  a)
                          'string<))))))

(ert-deftest edoc-virtual-getannot ()
  (with-edoc-virtual-test-buffer
   (let* ((a1 (car (edoc-info-getannots 1)))
          (a2 (edoc-info-getannot (cdr (assq 'id a1)))))
     (should (equal a1 a2)))))

(ert-deftest edoc-virtual-addannot ()
  (with-edoc-virtual-test-buffer
   (should-error (edoc-info-addannot 1 '(0 0 1 1) 'text))))

(ert-deftest edoc-virtual-delannot ()
  (skip-unless (edoc-info-writable-annotations-p))
  (with-edoc-virtual-test-buffer
   (should-error (edoc-info-delannot
                  (cdr (assq 'id (car (edoc-info-getannots 1))))))))

(ert-deftest edoc-virtual-mvannot ()
  (skip-unless (edoc-info-writable-annotations-p))
  (with-edoc-virtual-test-buffer
   (should-error (edoc-info-mvannot
                  (cdr (assq 'id (car (edoc-info-getannots 1))))
                  '(0 0 0 0)))))

(ert-deftest edoc-virtual-editannot ()
  (skip-unless (edoc-info-writable-annotations-p))
  (with-edoc-virtual-test-buffer
   (should-error (edoc-info-editannot
                  (cdr (assq 'id (car (edoc-info-getannots 1))))
                  '((color . "blue"))))))

(ert-deftest edoc-virtual-save ()
  (skip-unless (edoc-info-writable-annotations-p))
  (with-edoc-virtual-test-buffer
   (should-error (edoc-info-save))))

(ert-deftest edoc-virtual-adapter-argument-handling ()
  (let ((enabled-p edoc-virtual-global-minor-mode))
    (unwind-protect
        (progn
          (edoc-virtual-global-minor-mode 1)
          (with-edoc-virtual-test-buffer
           (should (stringp (edoc-info-renderpage 1 100 :alpha 0.1)))
           (should (stringp (edoc-info-renderpage
                             1 100 (current-buffer) :alpha 0.2))))
          (edoc-test-with-test-pdf
           (should (plist-get (edoc-info-setoptions
                               :render/printed t)
                              :render/printed))
           (should-not (plist-get (edoc-info-setoptions
                                   (current-buffer)
                                   :render/printed nil)
                                  :render/printed))
           (should (plist-get (edoc-info-setoptions
                               (buffer-file-name)
                               :render/printed t)
                              :render/printed))))
      (unless enabled-p
        (edoc-virtual-global-minor-mode -1)))))

;; (ert-deftest edoc-virtual-getattachment-from-annot ()
;;   )

;; (ert-deftest edoc-virtual-getattachments ()
;;   )

;; (ert-deftest edoc-virtual-synctex-forward-search ()
;;   )

;; (ert-deftest edoc-virtual-synctex-backward-search ()
;;   )

;; (ert-deftest edoc-virtual-renderpage ()
;;   )

;; (ert-deftest edoc-virtual-boundingbox ()
;;   )

;; (ert-deftest edoc-virtual-pagelabels ()
;;   )

;; (ert-deftest edoc-virtual-setoptions ()
;;   )

;; (ert-deftest edoc-virtual-getoptions ()
;;   )
