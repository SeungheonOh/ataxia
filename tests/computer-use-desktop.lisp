;;;; An unrelated World supplies its own layout language and viewport implementation.
(load (merge-pathnames "system-support.lisp" *load-truename*))
(asdf:load-system "ataxia-computer-use")

(defpackage #:ataxia.test.computer-desktop
  (:use #:cl #:ataxia.world)
  (:local-nicknames (#:cu #:ataxia.computer-use)))
(in-package #:ataxia.test.computer-desktop)

(defclass desktop-world (ataxia.kernel:world)
  ((kernel :accessor ataxia.kernel:world-kernel)
   (outputs :initarg :outputs :reader world-outputs)
   (position :initform 0 :accessor desktop-position)
   (camera :initform 0 :accessor desktop-camera)))
(defmethod world-supports-p ((world desktop-world) capability)
  (member capability '(:desktop :layout :viewport-navigation)))
(defmethod world-active-operation-p ((world desktop-world)) nil)
(defmethod world-desktop-state ((world desktop-world))
  (list :windows (vector (list :id 42 :title "Fixture" :position (desktop-position world)))
        :outputs #() :camera (desktop-camera world)))
(defmethod world-layout-schema ((world desktop-world))
  (values (ataxia.world.wire:decode
           "{\"type\":\"object\",\"properties\":{\"op\":{\"enum\":[\"position\"]},\"value\":{\"type\":\"integer\"}}}")
          "position sets the fixture's one-dimensional placement."))
(defmethod validate-world-layout ((world desktop-world) operations)
  (loop for operation across operations do
    (assert (equal "position" (gethash "op" operation)))
    (assert (integerp (gethash "value" operation)))))
(defmethod apply-world-layout ((world desktop-world) operations)
  (validate-world-layout world operations)
  (loop for operation across operations do
    (setf (desktop-position world) (gethash "value" operation))))
(defmethod navigate-world-viewport ((world desktop-world) output action &key x y dx dy zoom rotation width height window padding)
  (declare (ignore y dx dy zoom rotation width height window padding))
  (assert (member output (world-outputs world)))
  (assert (eq action :set))
  (setf (desktop-camera world) x))

(let* ((output (make-instance 'ataxia.kernel:kernel-output :id 1))
       (world (make-instance 'desktop-world :outputs (list output)))
       (controller (cu::%make-computer-controller :world world))
       (first (cu::%make-computer-session :world world :output output :state :active
                                         :input-state (cu::make-computer-input-state)))
       (second (cu::%make-computer-session :world world :output output :state :active
                                          :input-state (cu::make-computer-input-state))))
  (setf (ataxia.kernel:world-kernel world) (ataxia.kernel:make-kernel world)
        (cu::computer-session-seat first) (make-instance 'cu::computer-seat :session first)
        (cu::computer-session-seat second) (make-instance 'cu::computer-seat :session second))
  (attach-world-service world :computer-use controller)
  (unwind-protect
       (labels ((revision (session) (getf (cu::%computer-desktop-snapshot session) :revision))
                (operation (value)
                  (let ((data (make-hash-table :test #'equal)))
                    (setf (gethash "op" data) "position" (gethash "value" data) value)
                    (vector data))))
         (assert (not (find-package :ataxia.infinite-world)))
         (let ((snapshot (cu::%computer-desktop-snapshot first)))
           (assert (hash-table-p (getf snapshot :layout-schema)))
           (assert (not (getf snapshot :groups))))
         (let ((revision (revision second)))
           (cu::%computer-desktop-action first "arrange"
             (list :revision (revision first) :operations (operation 75)))
           (assert (= 75 (desktop-position world)))
           (assert (handler-case
                       (progn (cu::%computer-desktop-action second "arrange"
                                (list :revision revision :operations (operation 90))) nil)
                     (cu::computer-use-rejected () t)))
           (assert (= 75 (desktop-position world))))
         (cu::%computer-desktop-action first "viewport"
           (list :revision (revision first) :action "set" :output 1 :x -4200))
         (assert (= -4200 (desktop-camera world)))
         (assert (not (eq (cu::computer-session-desktop-state first)
                         (cu::computer-session-desktop-state second))))
         ;; No native seat was allocated; exercise session-owned state cleanup.
         (setf (cu::computer-session-seat first) nil)
         (cu:close-session first)
         (assert (null (cu::computer-session-desktop-state first)))
         (assert (cu::computer-session-desktop-state second)))
    (detach-world-service world :computer-use)))
(format t "PASS: host-defined layout operations and explicit viewport navigation; direct arrangement and stale revisions, isolated session state and cleanup.~%")
