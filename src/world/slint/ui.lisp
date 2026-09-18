(in-package #:ataxia.world.slint)
(defmethod ataxia.world:ui-raster-scale ((component slint-component))
  (slint-component-scale component))
(defmethod ataxia.world:ui-resize ((component slint-component) width height
                                  &key (scale (slint-component-scale component)))
  (resize-slint-component component width height :scale scale))
(defmethod ataxia.world:ui-destroy ((component slint-component))
  (destroy-slint-component component))
(defmethod ataxia.world:ui-set-invalidator ((component slint-component) function)
  (set-slint-component-invalidator component function))
(defmethod ataxia.world:ui-set-property ((component slint-component) name value)
  (set-slint-property component name value))
(defmethod ataxia.world:ui-set-callback ((component slint-component) name function)
  (set-slint-callback component name function))
(defmethod ataxia.world:ui-service-key ((component slint-component)) :slint)
(defmethod ataxia.world:ui-service ((component slint-component)) (update-slint-timers))
(defmethod ataxia.world:ui-dispatch-callbacks ((component slint-component))
  (poll-slint-callbacks component))
(defmethod ataxia.world:ui-next-update-delay ((component slint-component))
  (if (slint-component-needs-redraw-p component) 0
      (let ((delay (slint-next-timer-milliseconds)))
        ;; A global timer may change no pixels, or only another component.
        ;; Service it on the timer source before deciding which outputs draw.
        (unless (= delay #xffffffffffffffff) (max 1 delay)))))
