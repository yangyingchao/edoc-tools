;; -*- lexical-binding: t -*-

(require 'edoc-loader)
(require 'ert)
(require 'cl-lib)

(ert-deftest edoc-loader-activation ()
  :expected-result :failed ;; Until someone figures out how to run the
                           ;; tests w/o loading all of the package.
  (should-not (memq 'edoc-tools features))
  (edoc-loader-install)
  (with-current-buffer (find-file "test.pdf")
    (should (eq major-mode 'edoc-view-mode))))

(ert-deftest edoc-loader-install/uninstall-alists ()
  (cl-labels ((alists-installed-p ()
                (and (assoc edoc-loader--auto-mode-alist-item
                            auto-mode-alist)
                     (assoc edoc-loader--magic-mode-alist-item
                            magic-mode-alist))))
    (edoc-loader--install #'ignore)
    (should (alists-installed-p))
    (edoc-loader--uninstall)
    (should-not (alists-installed-p))))
