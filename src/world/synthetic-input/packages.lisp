;;;; Optional synthetic input provider for World services and test fixtures.
(defpackage #:ataxia.world.synthetic-input
  (:use #:cl)
  (:export #:create-synthetic-input #:destroy-synthetic-input
           #:synthetic-key #:synthetic-keycode #:set-keyboard-keymap-from-string))
