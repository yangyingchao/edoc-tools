;; -*- lexical-binding: t -*-

(ert-deftest edoc-info-open/close ()
  (edoc-test-with-test-pdf
   (should-not (edoc-info-open))
   (should (edoc-info-close)))
  (edoc-test-with-encrypted-pdf
   (should-error (edoc-info-open nil "Invalid Password"))
   (should-not (edoc-info-open nil "pdftool"))))

(ert-deftest edoc-info-metadata ()
  (edoc-test-with-test-pdf
    (should (cl-every (lambda (elt)
                        (and (consp elt)
                             (symbolp (car elt))))
                      (edoc-info-metadata)))))

(ert-deftest edoc-info-search-string ()
  (edoc-test-with-test-pdf
   (let (matches)
     (should (setq matches (edoc-info-search-string "PDF Tools")))
     (should (= 2 (length matches)))
     (should (cl-every (lambda (m)
                         (let-alist m
                           (and (stringp .text)
                                (cl-every 'edoc-test-relative-edges-p .edges)
                                (= 1 .page))))
                       matches)))))


(ert-deftest edoc-info-search-regexp ()
  (edoc-test-with-test-pdf
    (let (case-fold-search matches)
      (should (setq matches (edoc-info-search-regexp "PDF Tools")))
      (should (= 2 (length matches)))
      (should (cl-every (lambda (m)
                          (let-alist m
                            (and (stringp .text)
                                 (cl-every 'edoc-test-relative-edges-p .edges)
                                 (= 1 .page))))
                        matches)))))

(ert-deftest edoc-info-pagelinks ()
  (edoc-test-with-test-pdf
    (let ((links (edoc-info-pagelinks 3)))
      (should (= 2 (length links)))
      (should (cl-every 'edoc-test-relative-edges-p
                        (mapcar (apply-partially 'alist-get 'edges)
                                links)))
      (should (equal (mapcar (apply-partially 'alist-get 'type) links)
                     '(goto-dest uri)))
      (should (equal (mapcar (apply-partially 'alist-get 'uri)
                             links)
                     '(nil "http://www.gnu.org")))
      (should (equal (mapcar (apply-partially 'alist-get 'page)
                             links)
                     '(1 nil))))))

(ert-deftest edoc-info-number-of-pages ()
  (edoc-test-with-test-pdf
    (should (= 6 (edoc-info-number-of-pages)))))

(ert-deftest edoc-info-outline ()
  (edoc-test-with-test-pdf
   (let ((outline (edoc-info-outline)))
     (should (= 7 (length outline)))
     (should (equal (mapcar (apply-partially 'alist-get 'depth) outline)
                    '(1 1 1 1 1 2 3)))
     (should (cl-every (lambda (elt)
                         (eq (alist-get 'type elt)
                             'goto-dest))
                       outline)))))

(ert-deftest edoc-info-gettext ()
  (edoc-test-with-test-pdf
    (should (string-match "PDF Tools\\(?:.\\|\n\\)*in memory"
                          (edoc-info-gettext 1 '(0 0 1 1))))))

(ert-deftest edoc-info-getselection ()
  (edoc-test-with-test-pdf
    (should (consp (edoc-info-getselection 1 '(0 0 1 1))))
    (should (cl-every 'edoc-test-relative-edges-p
                      (edoc-info-getselection 1 '(0 0 1 1))))))

(ert-deftest edoc-info-textregions ()
  (edoc-test-with-test-pdf
    (should (consp (edoc-info-textregions 1)))))

(ert-deftest edoc-info-pagesize ()
  (edoc-test-with-test-pdf
    (should (cl-every (lambda (size)
                        (and (consp size)
                             (natnump (car size))
                             (natnump (cdr size))))
                      (list (edoc-info-pagesize 1))))))

(ert-deftest edoc-info-quit ()
  (edoc-test-with-test-pdf
    (edoc-info-quit)
    (let (edoc-info-restart-process-p)
      (should-error (edoc-info-open)))
    (let ((edoc-info-restart-process-p t))
      (edoc-info-open)
      (should (edoc-info-close)))))

(ert-deftest edoc-info-getannots ()
  (skip-unless (edoc-info-writable-annotations-p))
  (edoc-test-with-test-pdf
    (when (memq 'markup-annotations
                (edoc-info-features))
      (cl-labels ((alists-get (alists key)
                    (mapcar (lambda (alist)
                              (cdr (assoc key alist)))
                            alists)))
        (let (annots)
          (should (= 5 (length (setq annots (cl-remove-if
                                             (lambda (elt)
                                               (memq (cdr (assq 'type elt))
                                                     '(file link)))
                                             (edoc-info-getannots))))))
          (should (equal (alists-get annots 'page)
                         '(2 2 2 2 2)))
          (should (equal (sort (copy-sequence (alists-get annots 'type)) 'string-lessp)
                         (sort (copy-sequence
                                '(text strike-out highlight underline squiggly))
                               'string-lessp)))
          (should (equal (alists-get annots 'color)
                         '("#ff0000" "#ff0000" "#ff0000"
                           "#ff0000" "#ff0000")))
          (should (cl-every 'edoc-test-relative-edges-p
                            (alists-get annots 'edges))))))))

(ert-deftest edoc-info-getannot ()
  (skip-unless (edoc-info-writable-annotations-p))
  (edoc-test-with-test-pdf
    (let* ((text-annot (car
                        (cl-remove-if-not (lambda (elt)
                                            (eq (cdr (assq 'type elt)) 'text))
                                          (edoc-info-getannots))))
           (key (cdr (assq 'id text-annot))))
      (should (consp text-annot))
      (should (symbolp key))
      (should key)
      (should (equal (cl-sort text-annot 'string-lessp :key 'car)
                     (cl-sort (edoc-info-getannot key)
                              'string-lessp :key 'car))))))

(ert-deftest edoc-info-addannot ()
  (skip-unless (edoc-info-writable-annotations-p))
  (edoc-test-with-test-pdf
    (let (annot)
      (should (consp (setq annot
                           (edoc-info-addannot 1 '(0 0 1 1) 'text))))
      (should (eq 1 (cdr (assq 'page annot))))
      (should (eq 'text (cdr (assq 'type annot))))
      (should (equal "" (cdr (assq 'contents annot)))))))

(ert-deftest edoc-info-delannot ()
  (skip-unless (edoc-info-writable-annotations-p))
  (edoc-test-with-test-pdf
    (let ((nannots (length (edoc-info-getannots)))
          annots)
      (push (edoc-info-addannot 1 '(0 0 1 1) 'text)
            annots)
      (when (memq 'markup-annotations
                  (edoc-info-features))

         (push (edoc-info-addannot 1 '(0 0 1 1) 'squiggly nil nil '(0 0 1 1)) annots)
         (push (edoc-info-addannot 1 '(0 0 1 1) 'highlight 'word nil '(0 0 1 1)) annots)
         (push (edoc-info-addannot 1 '(0 0 1 1) 'underline 'line nil '(0 0 1 1)) annots)
        (push (edoc-info-addannot 1 '(0 0 1 1) 'strike-out 'glyph nil '(0 0 1 1)) annots))
      (dolist (a annots)
        (edoc-info-delannot (cdr (assq 'id a))))
      (should (= nannots (length (edoc-info-getannots)))))))

(ert-deftest edoc-info-mvannot ()
  (skip-unless (edoc-info-writable-annotations-p))
  (edoc-test-with-test-pdf
    (let ((edges '(0.25 0.25 1.0 1.0))
          (id (cdr (assq 'id (car (edoc-info-getannots))))))
      (edoc-info-mvannot id edges)
      (should (equal (cdr (assq 'edges (edoc-info-getannot id)))
                     edges)))))

(ert-deftest edoc-info-editannot ()
  (skip-unless (edoc-info-writable-annotations-p))
  (edoc-test-with-test-pdf
    (let ((color "#ffa500")
          (id (cdr (assq 'id (car (edoc-info-getannots))))))
      (should (and id (symbolp id)))
      (edoc-info-editannot id `((color . ,color)))
      (should (equal (cdr (assq 'color (edoc-info-getannot id)))
                     color)))))

(ert-deftest edoc-info-save ()
  (skip-unless (edoc-info-writable-annotations-p))
  (edoc-test-with-test-pdf
    (dolist (id (mapcar (lambda (a)
                          (cdr (assq 'id a)))
                        (edoc-info-getannots)))
      (edoc-info-delannot id))
    (let (tempfile)
      (unwind-protect
          (progn
            (setq tempfile (edoc-info-save))
            (should (file-exists-p tempfile))
            (should (= 0 (length (edoc-info-getannots nil tempfile)))))
        (when (file-exists-p tempfile)
          (delete-file tempfile))))))

(ert-deftest edoc-info-check-kc ()
  (should (progn (edoc-info-check-kc) t))
  (should-error
   (let (edoc-info-kc-program)
     (edoc-info-check-kc)))
  (should-error
   (let ((edoc-info-kc-program 42))
     (edoc-info-check-kc)))
  (should-error
   (let ((edoc-info-kc-program
          (make-temp-name "edoc-info")))
     (edoc-info-check-kc))))

;; FIXME: Write me.
;; (ert-deftest edoc-info-getattachment-from-annot ()
;;   (edoc-test-with-test-pdf
;;     ))

;; (ert-deftest edoc-info-getattachments ()
;;   (edoc-test-with-test-pdf
;;     ))

;; (ert-deftest edoc-info-synctex-forward-search ()
;;   (edoc-test-with-test-pdf
;;     ))

;; (ert-deftest edoc-info-synctex-backward-search ()
;;   (edoc-test-with-test-pdf
;;     ))

;; (ert-deftest edoc-info-renderpage ()
;;   (edoc-test-with-test-pdf
;;     ))

;; (ert-deftest edoc-info-renderpage-text-regions ()
;;   (edoc-test-with-test-pdf
;;     ))

;; (ert-deftest edoc-info-renderpage-highlight ()
;;   (edoc-test-with-test-pdf
;;     ))

;; (ert-deftest edoc-info-boundingbox ()
;;   (edoc-test-with-test-pdf
;;     ))
