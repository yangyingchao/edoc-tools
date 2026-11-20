;; -*- lexical-binding: t; -*-

;; * ================================================================== *
;; * Tests for edoc-sync.el
;; * ================================================================== *

(require 'ert)
(require 'edoc-sync)

(ert-deftest edoc-sync-backward--source-strip-comments ()
  (should-not (cl-remove-if
               (lambda (ch)
                 (memq ch '(?\\ ?\s ?\n)))
               (append (edoc-sync-backward--source-strip-comments
                        (concat "%comment\n"
                                "     %comment\n"
                                "\\\\%comment\n"
                                "\\\\   %comment\n"
                                "      \\\\   %comment\n"
                                "      \\\\%comment\n"))
                       nil)))
  (let ((source (concat "\\%comment\n"
                        "     \\%comment\n"
                        "\\   %comment\n"
                        "      \\   %comment\n"
                        "      \\%comment\n")))
    (should (equal (edoc-sync-backward--source-strip-comments source)
                   source))))

(ert-deftest edoc-sync-backward--get-text-context ()
  (edoc-test-with-test-pdf
    (should (= 3 (length (edoc-sync-backward--get-text-context 1 0.5 0.25))))
    ;; Empty page
    (should (equal '(-1 0 nil)
                   (edoc-sync-backward--get-text-context 6 0.5 0.5)))))

(ert-deftest edoc-sync-backward--get-source-context ()
  (with-temp-buffer
    (should-not (edoc-sync-backward--get-source-context))
    (insert "\\begin{foo}\nsource\n\\end{foo}")
    (should (cl-every 'stringp (edoc-sync-backward--get-source-context)))))

(ert-deftest edoc-sync-backward--find-position ()
  (let ((context '(3 2 ("000" "1111" "222222" "333333" "4444" "55555")))
        (prefix "000 XXXX 222222 YYYY 333")
        (suffix "333 4444 XXXX"))
    (with-temp-buffer
      (insert prefix suffix)
      (should (progn (edoc-sync-backward--find-position 1 -1 context)
                     (eq (length prefix) (point)))))))
