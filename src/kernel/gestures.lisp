(in-package #:ataxia.kernel)

(defstruct cursor-gesture-input device kind phase (time-msec 0) (fingers 0)
  cancelled-p (dx 0d0) (dy 0d0) (scale 1d0) (rotation 0d0))
(defgeneric world-cursor-gesture (world seat input)
  (:documentation "Interpret a copied touchpad gesture; no native event pointers escape Runtime."))
(defmethod world-cursor-gesture ((world world) seat input)
  (declare (ignore seat input)) nil)
(defmethod ataxia.runtime:pointer-gesture ((kernel kernel) event)
  (let* ((device (%event-input-device kernel (ataxia.runtime:pointer-gesture-pointer event)))
         (seat (and device (input-seat device))))
    (when seat
      (%call-world kernel world-cursor-gesture seat
       (make-cursor-gesture-input :device device
        :kind (ataxia.runtime:pointer-gesture-kind event)
        :phase (ataxia.runtime:pointer-gesture-phase event)
        :time-msec (ataxia.runtime:pointer-gesture-time-msec event)
        :fingers (ataxia.runtime:pointer-gesture-fingers event)
        :cancelled-p (ataxia.runtime:pointer-gesture-cancelled-p event)
        :dx (ataxia.runtime:pointer-gesture-dx event) :dy (ataxia.runtime:pointer-gesture-dy event)
        :scale (ataxia.runtime:pointer-gesture-scale event)
        :rotation (ataxia.runtime:pointer-gesture-rotation event))))))
