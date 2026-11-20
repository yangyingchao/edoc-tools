;; -*- lexical-binding: t; -*-

;; * ================================================================== *
;; * Tests not fitting anywhere else
;; * ================================================================== *

(require 'ert)

(ert-deftest edoc-tools-semantic-workaround ()
  (let (python-mode-hook)
    (require 'tablist)
    (should (null python-mode-hook))))
