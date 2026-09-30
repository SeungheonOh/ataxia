;;;; Exercise the real entrypoint's presentation choice, independent of assistant loading.
(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-shell")
(in-package #:ataxia.infinite-world)

(let ((original (symbol-function 'ataxia.kernel:run-kernel)))
  (unwind-protect
       (dolist (options '(("--no-status-bar") () ("--status-bar")
                          ("--status-bar" "--world" "niri")
                          ("--status-bar" "--world" "hyprland")))
         (let ((enabled (not (null (member "--status-bar" options :test #'equal))))
               (checked nil) (started-world nil))
           (setf (symbol-function 'ataxia.kernel:run-kernel)
                 (lambda (kernel &rest arguments)
                   (let* ((world (ataxia.kernel:kernel-world kernel))
                          (bars (ataxia.world.shell:status-bars world)))
                     (setf started-world world)
                     (assert (eq enabled (not (null (ataxia.world:world-service world :shell)))))
                     (assert (= (if enabled 1 0) (length bars)))
                     (assert (null (ataxia.world:world-service world :assistant)))
                     (assert (null (find-class 'ataxia.world.shell:rmlui-status-bar nil)))
                     (if enabled
                         (let ((bar (first bars)))
                           (assert (eq (type-of bar) (find-symbol "WEB-STATUS-BAR" :ataxia.world.web.shell)))
                           (let ((timer
                                   (ataxia.runtime:add-event-loop-timer
                                    (ataxia.kernel:kernel-runtime kernel)
                                    (lambda (source)
                                      (let* ((component (ataxia.world:overlay-component bar))
                                             (stats (uiop:symbol-call :ataxia.world.web :web-component-stats component)))
                                        (assert (null (getf stats :error)))
                                        (if (plusp (length (ataxia.kernel:drawable-surfaces component)))
                                            (progn
                                              (unless (equal "bitmap" (uiop:getenv "ATAXIA_WEB_TRANSPORT"))
                                                (assert (eq :dma-buf (getf stats :transport)))
                                                (assert (zerop (getf stats :uploaded-bytes))))
                                              (setf checked t)
                                              (ataxia.kernel:request-kernel-stop kernel :startup-verified))
                                            (ataxia.runtime:update-event-loop-timer source 100)))
                                      0))))
                             (ataxia.runtime:update-event-loop-timer timer 100)))
                         (progn
                           (setf checked t))))
                   (apply original kernel arguments)))
           (assert (zerop (metaworld-main
                           (append '("--backend" "headless" "--no-sly" "--no-persist"
                                     "--no-assistant" "--no-xwayland" "--no-screen-sharing"
                                     "--run-for")
                                   (list (if enabled "10" "0.05")) options))))
           (assert checked)
           (assert (null (ataxia.world:world-service started-world :shell)))
           (assert (null (ataxia.world:world-service started-world :web-ui)))))
    (setf (symbol-function 'ataxia.kernel:run-kernel) original)))
(format t "PASS: HTML shell startup in Metaworld/Niri/Hyprland, real DMA-BUF frames, no assistant or RmlUi shell, headless default/opt-out and teardown.~%")
