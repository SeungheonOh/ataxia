(in-package #:ataxia.runtime)

(cffi:defcstruct gesture-sample
  (time-msec :uint32) (fingers :uint32) (cancelled :uint32)
  (dx :double) (dy :double) (scale :double) (rotation :double))
(cffi:defcfun ("ataxia_pointer_gesture_signal" %gesture-signal) :pointer
  (pointer :pointer) (kind :uint32) (phase :uint32))
(cffi:defcfun ("ataxia_pointer_gesture_read" %gesture-read) :void
  (event :pointer) (kind :uint32) (phase :uint32) (sample :pointer))
(defstruct (pointer-gesture-event (:conc-name pointer-gesture-)) pointer kind phase time-msec fingers cancelled-p dx dy scale rotation)
(defgeneric pointer-gesture (sink event))
(defmethod pointer-gesture ((sink runtime-sink) event) (declare (ignore event)) nil)
(defvar *gesture-pointers* (make-hash-table :test #'eq :weakness :key))

(defun %gesture-snapshot (pointer event kind phase)
  (cffi:with-foreign-object (sample '(:struct gesture-sample))
    (%gesture-read event kind phase sample)
    (cffi:with-foreign-slots ((time-msec fingers cancelled dx dy scale rotation) sample (:struct gesture-sample))
      (make-pointer-gesture-event :pointer pointer :kind (nth kind '(:swipe :pinch :hold))
       :phase (nth phase '(:begin :update :end)) :time-msec time-msec :fingers fingers
       :cancelled-p (not (zerop cancelled)) :dx dx :dy dy :scale scale :rotation rotation))))

(defun %install-pointer-gesture-signals (pointer)
  (unless (gethash pointer *gesture-pointers*)
    (dotimes (kind 3)
      (dotimes (phase 3)
        (let* ((kind kind) (phase phase)
               (signal (%gesture-signal (%object-pointer pointer) kind phase)))
          (unless (cffi:null-pointer-p signal)
            (%attach-object-signal pointer (list :gesture kind phase) signal
             (lambda (event)
               (pointer-gesture (%runtime-sink (%native-runtime pointer))
                                (%gesture-snapshot pointer event kind phase))))))))
    (setf (gethash pointer *gesture-pointers*) t))
  pointer)
