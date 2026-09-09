;;;; Target-agnostic animation scheduling for Worlds.
;;;;
;;;; An animation owns timing only. Its update closure gives concrete meaning
;;;; to a sampled value, allowing unrelated objects and shader parameters to
;;;; animate concurrently without facts such as opacity living in this module.

(in-package #:ataxia.world)

(defclass animator ()
  ((active :initform nil :accessor %active-animations)))

(defstruct (%animation
             (:constructor %make-animation
                 (&key subject channel start-time duration delay easing update
                       finish repeat alternate-p)))
  subject channel start-time duration delay easing update finish repeat alternate-p
  (cancelled-p nil))

(defun make-animator ()
  (make-instance 'animator))

(defun linear-easing (progress)
  progress)

(defun ease-in-cubic (progress)
  (* progress progress progress))

(defun ease-out-cubic (progress)
  (let ((inverse (- 1d0 progress)))
    (- 1d0 (* inverse inverse inverse))))

(defun ease-in-out-cubic (progress)
  (if (< progress 0.5d0)
      (* 4d0 progress progress progress)
      (let ((value (+ (* -2d0 progress) 2d0)))
        (- 1d0 (/ (* value value value) 2d0)))))

(defun cancel-animation (animator subject channel)
  (setf (%active-animations animator)
        (delete-if
         (lambda (animation)
           (when (and (eq subject (%animation-subject animation))
                      (equal channel (%animation-channel animation)))
             (setf (%animation-cancelled-p animation) t)))
         (%active-animations animator)))
  animator)

(defun cancel-subject-animations (animator subject)
  (setf (%active-animations animator)
        (delete-if (lambda (animation)
                     (when (eq subject (%animation-subject animation))
                       (setf (%animation-cancelled-p animation) t)))
                   (%active-animations animator)))
  animator)

(defun start-animation
    (animator subject channel start-time duration update
     &key (delay 0d0) (easing #'linear-easing) finish (repeat 0) alternate-p)
  "Start or replace SUBJECT's CHANNEL with an arbitrary sampled update."
  (check-type duration real)
  (unless (plusp duration)
    (error "Animation duration must be positive."))
  (unless (or (eq repeat :forever)
              (and (integerp repeat) (not (minusp repeat))))
    (error "Animation repeat must be a non-negative integer or :FOREVER."))
  (cancel-animation animator subject channel)
  (push (%make-animation
         :subject subject :channel channel
         :start-time (coerce start-time 'double-float)
         :duration (coerce duration 'double-float)
         :delay (coerce delay 'double-float)
         :easing easing :update update :finish finish
         :repeat repeat :alternate-p alternate-p)
        (%active-animations animator))
  animator)

(defun animation-subjects (animator)
  "Return the subjects with scheduled animation work, without duplicates."
  (remove-duplicates (mapcar #'%animation-subject (%active-animations animator)) :test #'eq))

(defun animations-active-p (animator)
  (not (null (%active-animations animator))))

(defun %animation-progress (animation timestamp)
  (let ((elapsed (- timestamp
                    (%animation-start-time animation)
                    (%animation-delay animation))))
    (when (not (minusp elapsed))
      (let* ((duration (%animation-duration animation))
             (iteration (floor elapsed duration))
             (repeat (%animation-repeat animation))
             (iterations (and (not (eq repeat :forever)) (1+ repeat)))
             (complete-p (and iterations (>= iteration iterations)))
             (effective-iteration (if complete-p (1- iterations) iteration))
             (raw-progress
               (if complete-p 1d0 (/ (rem elapsed duration) duration)))
             (progress
               (if (and (%animation-alternate-p animation)
                        (oddp effective-iteration))
                   (- 1d0 raw-progress)
                   raw-progress)))
        (values progress complete-p)))))

(defun advance-animations (animator timestamp)
  "Sample all animations. Return changed subjects and whether work remains."
  ;; Callbacks may cancel, replace, or chain animations. Sample a snapshot but
  ;; keep the live registry authoritative, so a callback cannot resurrect old
  ;; work or lose a newly scheduled transition at the end of this frame.
  (let ((changed nil)
        (time (coerce timestamp 'double-float)))
    (dolist (animation (copy-list (%active-animations animator)))
      (unless (%animation-cancelled-p animation)
        (multiple-value-bind (progress complete-p)
            (%animation-progress animation time)
          (when progress
            (funcall (%animation-update animation)
                     (%animation-subject animation)
                     (funcall (%animation-easing animation) progress))
            (pushnew (%animation-subject animation) changed :test #'eq)
            (when (and complete-p
                       (not (%animation-cancelled-p animation)))
              (setf (%animation-cancelled-p animation) t)
              (when (%animation-finish animation)
                (funcall (%animation-finish animation)
                         (%animation-subject animation))))))))
    (setf (%active-animations animator)
          (delete-if #'%animation-cancelled-p (%active-animations animator)))
    (values (nreverse changed) (animations-active-p animator))))
