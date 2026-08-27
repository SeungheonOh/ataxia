;;;; Seat and input mechanisms.
;;;;
;;;; Kernel owns each real wlr-seat, assigns Runtime input devices, maintains
;;;; capabilities, and performs protocol delivery selected synchronously by
;;;; World. Cursor coordinates and interaction policy do not live here.

(in-package #:ataxia.kernel)

(defun %device-capability (input-device)
  (case (input-type input-device)
    (:pointer ataxia.runtime:+seat-capability-pointer+)
    (:keyboard ataxia.runtime:+seat-capability-keyboard+)
    (:touch 0)
    (otherwise 0)))

(defun %refresh-seat-capabilities (seat)
  (let ((capabilities 0))
    (maphash
     (lambda (input-device present-p)
       (declare (ignore present-p))
       (setf capabilities
             (logior capabilities (%device-capability input-device))))
     (seat-input-devices seat))
    (setf (seat-capabilities seat) capabilities)
    (ataxia.runtime:set-seat-capabilities
     (seat-runtime-object seat) capabilities))
  seat)

(defun create-logical-seat (kernel name)
  "Create one stable logical seat backed by one Runtime wlr-seat."
  (check-type kernel kernel)
  (check-type name string)
  (when (find name (kernel-seats kernel) :key #'seat-name :test #'string=)
    (error "Logical seat ~S already exists." name))
  (let* ((runtime-seat
           (ataxia.runtime:create-seat (kernel-runtime kernel) name))
         (seat
           (make-instance
            'logical-seat
            :kernel kernel
            :id (%allocate-object-id kernel)
            :runtime-object runtime-seat
            :name name)))
    (%register-object kernel seat :runtime-object runtime-seat)
    (setf (gethash runtime-seat (%kernel-seat-table kernel)) seat)
    (ataxia.runtime:set-seat-capabilities runtime-seat 0)
    (%call-world kernel world-seat-added seat)
    seat))

(defun %unassign-input-device (input-device)
  (let ((seat (input-seat input-device)))
    (when seat
      (remhash input-device (seat-input-devices seat))
      (when (eq (input-runtime-object input-device) (%seat-keyboard seat))
        (ataxia.runtime:clear-seat-keyboard (seat-runtime-object seat))
        (setf (%seat-keyboard seat) nil))
      (setf (input-seat input-device) nil)
      (%refresh-seat-capabilities seat)))
  input-device)

(defun assign-input-device (input-device seat)
  "Move INPUT-DEVICE to SEAT and update wl_seat capabilities immediately."
  (check-type input-device kernel-input-device)
  (check-type seat logical-seat)
  (unless (eq (object-kernel input-device) (object-kernel seat))
    (error "Input device and seat belong to different Kernels."))
  (%unassign-input-device input-device)
  (setf (input-seat input-device) seat
        (gethash input-device (seat-input-devices seat)) t)
  (when (eq (input-type input-device) :keyboard)
    (let ((keyboard (input-runtime-object input-device)))
      (ataxia.runtime:set-seat-keyboard (seat-runtime-object seat) keyboard)
      (setf (%seat-keyboard seat) keyboard)))
  (%refresh-seat-capabilities seat)
  input-device)

(defun %retire-logical-seat (seat &key protocol-active-p)
  (when (eq (object-state seat) :live)
    (let ((kernel (object-kernel seat)))
      (%call-world kernel world-seat-removing seat)
      (dolist (input-device
                (loop for input-device being the hash-keys
                        of (seat-input-devices seat)
                      collect input-device))
        (if protocol-active-p
            (%unassign-input-device input-device)
            (setf (input-seat input-device) nil)))
      (clrhash (seat-input-devices seat))
      (setf (%seat-keyboard seat) nil)
      (remhash (seat-runtime-object seat) (%kernel-seat-table kernel))
      (%retire-object
       kernel seat :runtime-object (seat-runtime-object seat))
      (when (eq seat (%kernel-default-seat kernel))
        (setf (%kernel-default-seat kernel) nil))))
  seat)

(defun destroy-logical-seat (seat)
  (check-type seat logical-seat)
  (let ((runtime-seat (seat-runtime-object seat)))
    (when (eq (object-state seat) :live)
      (%retire-logical-seat seat :protocol-active-p t)
      (ataxia.runtime:destroy-seat runtime-seat)))
  nil)

(defun clear-wayland-focus (seat &key pointer keyboard)
  "Clear selected protocol focus kinds without introducing a native target."
  (check-type seat logical-seat)
  (when pointer
    (ataxia.runtime:seat-pointer-notify-clear-focus
     (seat-runtime-object seat)))
  (when keyboard
    (ataxia.runtime:seat-keyboard-notify-clear-focus
     (seat-runtime-object seat)))
  seat)

(defun %event-input-device (kernel runtime-input-device)
  (gethash runtime-input-device (%kernel-input-table kernel)))

(defun %event-seat (kernel runtime-input-device)
  (let ((input-device (%event-input-device kernel runtime-input-device)))
    (and input-device (input-seat input-device))))
