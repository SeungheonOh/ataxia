;;;; Subsurface discovery and parent-relative state.
;;;;
;;;; This module adopts concrete wlr_subsurface objects, relates each child to
;;;; typed parent and child surfaces, tracks applied offsets, and reports
;;;; lifecycle changes without assigning any world-space interpretation.

(in-package #:ataxia.runtime.raw)

(define-signal-binding %subsurface-event-destroy
  "ataxia_subsurface_event_destroy" subsurface)
(defcfun ("ataxia_subsurface_surface" %subsurface-surface) :pointer
  (subsurface :pointer))
(defcfun ("ataxia_subsurface_parent" %subsurface-parent) :pointer
  (subsurface :pointer))
(defcfun ("ataxia_subsurface_x" %subsurface-x) :int32
  (subsurface :pointer))
(defcfun ("ataxia_subsurface_y" %subsurface-y) :int32
  (subsurface :pointer))
(defcfun ("ataxia_subsurface_synchronized" %subsurface-synchronized)
    :boolean
  (subsurface :pointer))
(defcfun ("wlr_surface_surface_at" %wlr-surface-surface-at) :pointer
  (surface :pointer)
  (surface-x :double)
  (surface-y :double)
  (subsurface-x :pointer)
  (subsurface-y :pointer))

(in-package #:ataxia.runtime)

(defclass wlr-subsurface (native-object)
  ((surface :initarg :surface :reader subsurface-surface)
   (parent :initarg :parent :reader subsurface-parent)
   (x :initform 0 :accessor subsurface-x)
   (y :initform 0 :accessor subsurface-y)
   (synchronized-p :initform nil :accessor subsurface-synchronized-p)))

(defgeneric surface-new-subsurface (sink parent subsurface))
(defgeneric subsurface-state-changed (sink subsurface))
(defgeneric subsurface-destroying (sink subsurface))

(defmethod surface-new-subsurface
    ((sink runtime-sink) parent subsurface)
  (declare (ignore sink parent subsurface)))
(defmethod subsurface-state-changed ((sink runtime-sink) subsurface)
  (declare (ignore sink subsurface)))
(defmethod subsurface-destroying ((sink runtime-sink) subsurface)
  (declare (ignore sink subsurface)))

(defmethod surface-new-subsurface
    ((sink diagnostic-sink) parent subsurface)
  (declare (ignore parent))
  (%diagnostic-line
   sink "[runtime] new-subsurface address=~X offset=~D,~D synchronized=~A"
   (native-object-address subsurface)
   (subsurface-x subsurface) (subsurface-y subsurface)
   (subsurface-synchronized-p subsurface)))

(defmethod subsurface-destroying
    ((sink diagnostic-sink) subsurface)
  (%diagnostic-line sink "[runtime] subsurface-destroy address=~X"
                    (native-object-address subsurface)))

(defun %refresh-subsurface (subsurface)
  (let ((pointer (%object-pointer subsurface)))
    (setf (subsurface-x subsurface)
          (ataxia.runtime.raw:%subsurface-x pointer)
          (subsurface-y subsurface)
          (ataxia.runtime.raw:%subsurface-y pointer)
          (subsurface-synchronized-p subsurface)
          (ataxia.runtime.raw:%subsurface-synchronized pointer)))
  subsurface)

(defun %handle-new-subsurface (runtime pointer)
  (let ((key (%pointer-key pointer)))
    (unless (gethash key (%runtime-subsurface-table runtime))
      (let* ((surface-pointer
               (%require-pointer
                (ataxia.runtime.raw:%subsurface-surface pointer)
                :subsurface-surface))
             (parent-pointer
               (%require-pointer
                (ataxia.runtime.raw:%subsurface-parent pointer)
                :subsurface-parent))
             (surface (%adopt-core-surface runtime surface-pointer))
             (parent (%adopt-core-surface runtime parent-pointer))
             (subsurface
               (%refresh-subsurface
                (%wrap-pointer 'wlr-subsurface pointer runtime
                               :surface surface :parent parent)))
             (sink (%runtime-sink runtime)))
        (setf (gethash key (%runtime-subsurface-table runtime)) subsurface)
        (%attach-object-signal
         subsurface :subsurface-parent-commit
         (ataxia.runtime.raw:%surface-event-commit parent-pointer)
         (lambda (data)
           (declare (ignore data))
           (let ((old-x (subsurface-x subsurface))
                 (old-y (subsurface-y subsurface))
                 (old-sync (subsurface-synchronized-p subsurface)))
             (%refresh-subsurface subsurface)
             (unless (and (= old-x (subsurface-x subsurface))
                          (= old-y (subsurface-y subsurface))
                          (eq old-sync
                              (subsurface-synchronized-p subsurface)))
               (subsurface-state-changed sink subsurface)))))
        (%attach-object-signal
         subsurface :subsurface-destroy
         (ataxia.runtime.raw:%subsurface-event-destroy pointer)
         (lambda (data)
           (declare (ignore data))
           (unwind-protect
                (subsurface-destroying sink subsurface)
             (%retire-object-listeners subsurface :immediate-p t)
             (%invalidate-native-object subsurface)
             (remhash key (%runtime-subsurface-table runtime)))))
        (surface-new-subsurface sink parent subsurface)))))

(defun %install-subsurface-discovery (surface)
  (let ((runtime (%native-runtime surface)))
    (%attach-object-signal
     surface :surface-new-subsurface
     (ataxia.runtime.raw:%surface-event-new-subsurface
      (%object-pointer surface))
     (lambda (subsurface-pointer)
       (%handle-new-subsurface runtime subsurface-pointer))))
  surface)

(defun surface-at (surface surface-x surface-y)
  (check-type surface wlr-surface)
  (let ((runtime (%native-runtime surface)))
    (%assert-runtime-live runtime :surface-at)
    (cffi:with-foreign-objects ((subsurface-x :double)
                                (subsurface-y :double))
      (let ((pointer
              (ataxia.runtime.raw:%wlr-surface-surface-at
               (%object-pointer surface)
               (coerce surface-x 'double-float)
               (coerce surface-y 'double-float)
               subsurface-x subsurface-y)))
        (unless (ataxia.runtime.raw:null-pointer-p pointer)
          (values (%adopt-core-surface runtime pointer)
                  (cffi:mem-ref subsurface-x :double)
                  (cffi:mem-ref subsurface-y :double)))))))
