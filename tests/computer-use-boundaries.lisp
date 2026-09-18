;;;; Load in a fresh process: optional World services must not grow the core API.
(load (merge-pathnames "system-support.lisp" *load-truename*))
(asdf:load-system "ataxia-kernel")

(defun assert-no-computer-use-in-core ()
  (dolist (package '("ATAXIA.KERNEL" "ATAXIA.RUNTIME" "ATAXIA.RUNTIME.RAW"))
    (dolist (name '("COMPUTER-SESSION" "COMPUTER-CONTROLLER" "*CUA-LIBRARY*"
                    "ENSURE-CUA-LIBRARY" "%CUA-SURFACE-PID" "%CUA-SET-CLIPBOARD"
                    "CREATE-SYNTHETIC-INPUT" "DESTROY-SYNTHETIC-INPUT"
                    "*SYNTHETIC-INPUTS*" "SYNTHETIC-KEY" "SYNTHETIC-KEYCODE"
                    "SURFACE-CLIENT-PID" "SEAT-SET-CLIPBOARD-CONTENT"
                    "APPLICATION-SEAT-INPUT-CAPABILITIES"))
      (assert (null (find-symbol name package)) () "~A leaked into ~A." name package))))

(assert-no-computer-use-in-core)
(assert (not (find-package :ataxia.computer-use)))
(assert (not (find-package :ataxia.world.synthetic-input)))
(assert (not (asdf:component-loaded-p (asdf:find-system "ataxia-world"))))

(asdf:load-system "ataxia-world")
(assert (not (find-package :ataxia.computer-use)))
(assert (not (find-package :ataxia.world.synthetic-input)))

(asdf:load-system "ataxia-computer-use")
(assert-no-computer-use-in-core)
(dolist (package '(:ataxia.infinite-world :ataxia.metaworld :ataxia.atlas))
  (assert (not (find-package package))))
(let ((world (make-instance 'ataxia.kernel:world)))
  (assert (handler-case
              (progn (ataxia.computer-use:enable world :start-server nil) nil)
            (error () t)))
  (assert (null (ataxia.world:world-service world :computer-use))))

;; A concrete World alone does not acquire CUA rendering or a controller.
(asdf:load-system "ataxia-infinite-world")
(let ((world (ataxia.infinite-world:make-infinite-world)))
  (assert (not (ataxia.world:world-supports-p world :window-capture)))
  (assert (handler-case
              (progn (ataxia.computer-use:enable world :start-server nil) nil)
            (error () t)))
  (assert (null (ataxia.world:world-service world :computer-use))))

(asdf:load-system "ataxia-computer-use/infinite-world")
(let ((world (ataxia.infinite-world:make-infinite-world)))
  (assert (ataxia.world:world-supports-p world :window-capture))
  (assert (not (ataxia.world:world-supports-p world :layout)))
  (assert (not (ataxia.world:world-supports-p world :shell-navigation)))
  (assert (null (ataxia.world:world-service world :computer-use))))

(asdf:load-system "ataxia-computer-use/metaworld")
(let ((world (ataxia.metaworld:make-metaworld :state-file nil)))
  (dolist (capability '(:ui :desktop :window-capture :layout :shell-navigation))
    (assert (ataxia.world:world-supports-p world capability)))
  (assert (null (ataxia.world:world-service world :computer-use))))
(assert-no-computer-use-in-core)
(format t "PASS: core stays CUA-free; portable service and World adapters load separately and never auto-enable.~%")
