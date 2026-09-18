(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-atlas-world")
(asdf:load-system "ataxia-tiling-world")

(dolist (parser '(ataxia.world:parse-compositor-options
                  ataxia.infinite-world::%parse-main-options
                  ataxia.atlas-world::%parse-main-options
                  ataxia.tiling-world::%parse-main-options))
  (assert (equal '(:backend :auto :width 1280 :height 720 :run-for nil
                  :debug-p nil :damage-debug-p nil :sly-port 4005)
                 (funcall parser nil)))
  (assert (eq :help (funcall parser '("--help" "ignored-after-help"))))
  (assert (equal '(:backend :headless :width 800 :height 600 :run-for 1/2
                  :debug-p t :damage-debug-p t :sly-port 65535)
                 (funcall parser '("--backend" "headless" "--width" "640" "--width" "800"
                                   "--height" "600" "--run-for" "1/2" "--debug"
                                   "--damage-debug" "--no-sly" "--sly-port" "65535"))))
  (assert (null (getf (funcall parser '("--sly-port" "1234" "--no-sly")) :sly-port)))
  (dolist (arguments '(("--unknown") ("--width") ("--backend" "unknown")
                       ("--width" "0") ("--width" "-1") ("--width" "2.5")
                       ("--height" "garbage") ("--run-for" "1 2")
                       ("--run-for" "#.(error \"reader evaluation\")")
                       ("--sly-port" "65536")))
    (assert (handler-case (progn (funcall parser arguments) nil) (error () t)))))
(format t "PASS: shared compositor CLI defaults, help, numeric validation, repeated options and port boundaries.~%")
