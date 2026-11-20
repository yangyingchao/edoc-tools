;; -*- lexical-binding: t; -*-

;; * ================================================================== *
;; * Tests for edoc-cache.el
;; * ================================================================== *

(require 'edoc-cache)
(require 'ert)

(ert-deftest edoc-cache-get-image ()
  (let (edoc-cache--image-cache)
    (should-not (edoc-cache-get-image 1 1))
    (setq edoc-cache--image-cache
          (list
           (edoc-cache--make-image 1 1 "1" nil)
           (edoc-cache--make-image 2 1 "2" nil)
           (edoc-cache--make-image 3 1 "3" nil)))
    (should (equal (edoc-cache-get-image 1 1) "1"))
    (should (equal edoc-cache--image-cache
                   (list
                    (edoc-cache--make-image 1 1 "1" nil)
                    (edoc-cache--make-image 2 1 "2" nil)
                    (edoc-cache--make-image 3 1 "3" nil))))
    (should (equal (edoc-cache-get-image 2 1) "2"))
    (should (equal edoc-cache--image-cache
                   (list
                    (edoc-cache--make-image 2 1 "2" nil)
                    (edoc-cache--make-image 1 1 "1" nil)
                    (edoc-cache--make-image 3 1 "3" nil))))
    (should-not (edoc-cache-get-image 4 1))))
