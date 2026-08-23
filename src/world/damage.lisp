;;;; Reusable output-buffer damage history.
;;;;
;;;; The tracker accepts final output-buffer regions. It knows nothing about a
;;;; World's geometry and keeps pending damage until Kernel confirms a commit.

(in-package #:ataxia.world)

(defclass damage-tracker ()
  ((outputs :initform (make-hash-table :test #'eq) :reader %damage-outputs)
   (history-limit :initarg :history-limit :initform 24
                  :reader %damage-history-limit)))

(defstruct (%damage-output (:constructor %make-damage-output))
  generation width height
  (pending nil)
  (full-p t)
  (serial 0)
  (history nil)
  (targets (make-hash-table :test #'eq))
  staged)

(defstruct (%damage-record (:constructor %make-damage-record (serial region)))
  serial region)

(defstruct (%damage-frame
             (:constructor %make-damage-frame
                 (output state target pending full-p new-region region)))
  output state target pending full-p new-region region)

(defun make-damage-tracker (&key (history-limit 24))
  (make-instance 'damage-tracker :history-limit history-limit))

(defun %damage-output (tracker output)
  (or (gethash output (%damage-outputs tracker))
      (setf (gethash output (%damage-outputs tracker))
            (%make-damage-output))))

(defun damage-add-region (tracker output region)
  (let ((state (%damage-output tracker output)))
    (setf (%damage-output-pending state)
          (normalize-region
           (append region (%damage-output-pending state)))))
  tracker)

(defun damage-full-output (tracker output)
  (setf (%damage-output-full-p (%damage-output tracker output)) t)
  tracker)

(defun damage-reset-output (tracker output)
  (remhash output (%damage-outputs tracker))
  (%damage-output tracker output)
  tracker)

(defun damage-forget-output (tracker output)
  (remhash output (%damage-outputs tracker))
  tracker)

(defun damage-pending-p (tracker output)
  (let ((state (gethash output (%damage-outputs tracker))))
    (and state
         (or (%damage-output-full-p state)
             (%damage-output-pending state)))))

(defun %history-repair (state target full-region)
  (let ((last-serial (gethash target (%damage-output-targets state))))
    (cond
      ((null last-serial) full-region)
      ((= last-serial (%damage-output-serial state)) nil)
      (t
       (let* ((history (%damage-output-history state))
              (oldest (and history
                           (%damage-record-serial (car (last history))))))
         (if (or (null oldest) (< last-serial (1- oldest)))
             full-region
             (loop for record in history
                   when (> (%damage-record-serial record) last-serial)
                     append (%damage-record-region record))))))))

(defun damage-begin-frame (tracker output target generation width height)
  "Stage one target repair and return its region and opaque frame cookie."
  (let* ((state (%damage-output tracker output))
         (geometry-changed-p
           (or (not (eql generation (%damage-output-generation state)))
               (not (eql width (%damage-output-width state)))
               (not (eql height (%damage-output-height state)))))
         (full-region (list (make-rectangle 0 0 width height))))
    (when geometry-changed-p
      (setf (%damage-output-generation state) generation
            (%damage-output-width state) width
            (%damage-output-height state) height
            (%damage-output-full-p state) t
            (%damage-output-history state) nil
            (%damage-output-staged state) nil)
      (clrhash (%damage-output-targets state)))
    (when (%damage-output-staged state)
      (error "Damage frame already staged for output ~S." output))
    (let* ((pending (%damage-output-pending state))
           (full-p (%damage-output-full-p state))
           (new-region
             (clip-region (if full-p full-region pending) width height))
           (repair
             (clip-region
              (append new-region
                      (unless full-p
                        (%history-repair state target full-region)))
              width height))
           (frame (%make-damage-frame
                   output state target pending full-p new-region repair)))
      (setf (%damage-output-staged state) frame)
      (values repair frame))))

(defun damage-frame-region (frame)
  (%damage-frame-region frame))

(defun damage-commit-frame (tracker frame)
  (let ((state (%damage-frame-state frame)))
    (unless (eq frame (%damage-output-staged state))
      (error "Damage frame is not the active staged frame."))
    (when (and (eq (%damage-frame-pending frame)
                   (%damage-output-pending state))
               (eql (%damage-frame-full-p frame)
                    (%damage-output-full-p state)))
      (setf (%damage-output-pending state) nil
            (%damage-output-full-p state) nil))
    (let ((serial (incf (%damage-output-serial state))))
      (setf (gethash (%damage-frame-target frame)
                     (%damage-output-targets state))
            serial)
      (push (%make-damage-record serial (%damage-frame-new-region frame))
            (%damage-output-history state))
      (setf (%damage-output-history state)
            (subseq (%damage-output-history state)
                    0 (min (length (%damage-output-history state))
                           (%damage-history-limit tracker)))))
    (setf (%damage-output-staged state) nil))
  frame)

(defun damage-fail-frame (tracker frame)
  (declare (ignore tracker))
  (when frame
    (let ((state (%damage-frame-state frame)))
      (when (eq frame (%damage-output-staged state))
        (setf (%damage-output-staged state) nil))))
  frame)
