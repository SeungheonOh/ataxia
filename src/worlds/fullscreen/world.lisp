;;;; Single-client fullscreen World policy.
;;;;
;;;; The first Wayland application owns every output until it exits. World
;;;; stores placement, cursor, focus, damage, and drawing policy while Kernel
;;;; continues to own protocol objects, frame acquisition, and output commits.

(in-package #:ataxia.fullscreen-world)

(defstruct (%seat-state (:constructor %make-seat-state))
  (x 0d0 :type real)
  (y 0d0 :type real)
  cursor-surface
  (hotspot-x 0 :type integer)
  (hotspot-y 0 :type integer))

(defclass fullscreen-world (ataxia.kernel:world)
  ((kernel :initform nil :accessor %world-kernel)
   (application :initform nil :accessor %world-application)
   (outputs :initform nil :accessor %world-outputs)
   (seats :initform (make-hash-table :test #'eq) :reader %world-seats)
   (renderer :initform nil :accessor %world-renderer)
   (active-p :initform t :accessor %world-active-p))
  (:documentation
   "Minimal World that presents and interacts with exactly one fullscreen client."))

(defun make-fullscreen-world ()
  (make-instance 'fullscreen-world))

(defun %primary-output (world)
  (first (%world-outputs world)))

(defun %output-logical-size (output)
  (let ((scale (ataxia.kernel:output-scale output)))
    (values
     (/ (ataxia.kernel:output-width output) scale)
     (/ (ataxia.kernel:output-height output) scale))))

(defun %request-all-frames (world)
  (when (%world-active-p world)
    (dolist (output (%world-outputs world))
      (when (and (eq (ataxia.kernel:object-state output) :live)
                 (ataxia.kernel:output-enabled-p output))
        (ataxia.kernel:request-output-frame output))))
  world)

(defun %configure-application (world)
  (let ((application (%world-application world))
        (output (%primary-output world)))
    (when (and application output
               (eq (ataxia.kernel:object-state application) :live)
               (plusp
                (ataxia.kernel:surface-commit-sequence
                 (ataxia.kernel:application-root-surface application))))
      (multiple-value-bind (width height) (%output-logical-size output)
        (let ((integer-width (max 1 (round width)))
              (integer-height (max 1 (round height))))
          (ataxia.kernel:request-object-state
           application world :fullscreen t)
          (ataxia.kernel:request-object-configuration
           application world
           (make-instance
            'ataxia.kernel:toplevel-configuration
            :width integer-width
            :height integer-height
            :bounds-width integer-width
            :bounds-height integer-height
            :activated t))))))
  world)

(defun %focus-application (world)
  (let ((application (%world-application world)))
    (when (and application (ataxia.kernel:application-mapped-p application))
      (maphash
       (lambda (seat state)
         (declare (ignore state))
         (ataxia.kernel:interactable-focus
          application world seat :keyboard))
       (%world-seats world))))
  world)

(defun %clear-application-focus (world)
  (maphash
   (lambda (seat state)
     (declare (ignore state))
     (ataxia.kernel:clear-wayland-focus
      seat :pointer t :keyboard t))
   (%world-seats world))
  world)

(defun %drawable-protocol-tokens (drawable)
  (multiple-value-bind (surfaces revision)
      (ataxia.kernel:drawable-surfaces drawable)
    (declare (ignore revision))
    (loop for surface across surfaces
          for token =
            (ataxia.kernel:drawable-surface-presentation-token surface)
          when token collect token)))

(defun %set-drawable-membership (drawable outputs)
  (dolist (token (%drawable-protocol-tokens drawable))
    (ataxia.kernel:set-wayland-surface-output-membership token outputs)))

(defun %cursor-surface-p (world object)
  (loop for state being the hash-values of (%world-seats world)
        thereis (eq object (%seat-state-cursor-surface state))))

(defun %forget-cursor-surface (world surface)
  (maphash
   (lambda (seat state)
     (declare (ignore seat))
     (when (eq surface (%seat-state-cursor-surface state))
       (setf (%seat-state-cursor-surface state) nil)))
   (%world-seats world)))

(defmethod ataxia.kernel:world-attached
    ((world fullscreen-world) kernel)
  (setf (%world-kernel world) kernel
        (%world-active-p world) t)
  world)

(defmethod ataxia.kernel:world-kernel ((world fullscreen-world))
  (%world-kernel world))

(defmethod ataxia.kernel:world-quiescing
    ((world fullscreen-world) reason)
  (declare (ignore reason))
  (setf (%world-active-p world) nil)
  world)

(defmethod ataxia.kernel:world-detached ((world fullscreen-world) kernel)
  (when (eq kernel (%world-kernel world))
    (setf (%world-kernel world) nil
          (%world-application world) nil
          (%world-outputs world) nil)
    (clrhash (%world-seats world)))
  world)

(defmethod ataxia.kernel:world-register-object
    ((world fullscreen-world) (application ataxia.kernel:wayland-application))
  (if (%world-application world)
      (ataxia.kernel:request-object-state application world :close t)
      (progn
        (setf (%world-application world) application)
        (%configure-application world)
        (%set-drawable-membership application (%world-outputs world))
        (%request-all-frames world)))
  application)

(defmethod ataxia.kernel:world-unregister-object
    ((world fullscreen-world) object reason)
  (declare (ignore reason))
  (when (eq object (%world-application world))
    (%set-drawable-membership object nil)
    (%clear-application-focus world)
    (setf (%world-application world) nil)
    (%request-all-frames world))
  object)

(defmethod ataxia.kernel:world-object-changed
    ((world fullscreen-world) object change)
  (when (eq object (%world-application world))
    (case (ataxia.kernel:object-change-kind change)
      (:mapped
       (if (ataxia.kernel:object-change-value change)
           (progn
             (%configure-application world)
             (%focus-application world))
           (%clear-application-focus world))))
    (%request-all-frames world))
  (when (and (typep object 'ataxia.kernel:surface-node)
             (eq (ataxia.kernel:object-change-kind change) :destroying)
             (%cursor-surface-p world object))
    (%forget-cursor-surface world object)
    (%request-all-frames world))
  object)

(defmethod ataxia.kernel:world-object-invalidated
    ((world fullscreen-world) object invalidation)
  (declare (ignore invalidation))
  (when (eq object (%world-application world))
    (%set-drawable-membership object (%world-outputs world))
    (%request-all-frames world))
  (when (%cursor-surface-p world object)
    (%set-drawable-membership object (%world-outputs world))
    (%request-all-frames world))
  object)

(defmethod ataxia.kernel:world-output-added
    ((world fullscreen-world) output)
  (setf (%world-outputs world)
        (append (%world-outputs world) (list output)))
  (when (%world-application world)
    (%set-drawable-membership
     (%world-application world) (%world-outputs world)))
  (%configure-application world)
  (multiple-value-bind (width height) (%output-logical-size output)
    (maphash
     (lambda (seat state)
       (declare (ignore seat))
       (when (and (zerop (%seat-state-x state))
                  (zerop (%seat-state-y state)))
         (setf (%seat-state-x state) (/ width 2d0)
               (%seat-state-y state) (/ height 2d0))))
     (%world-seats world)))
  (ataxia.kernel:request-output-frame output)
  output)

(defmethod ataxia.kernel:world-output-changed
    ((world fullscreen-world) output change)
  (declare (ignore change))
  (when (eq output (%primary-output world))
    (%configure-application world))
  (ataxia.kernel:request-output-frame output)
  output)

(defmethod ataxia.kernel:world-output-removing
    ((world fullscreen-world) output)
  (setf (%world-outputs world)
        (delete output (%world-outputs world) :test #'eq))
  (when (%world-application world)
    (%set-drawable-membership
     (%world-application world) (%world-outputs world)))
  (maphash
   (lambda (seat state)
     (declare (ignore seat))
     (when (%seat-state-cursor-surface state)
       (%set-drawable-membership
        (%seat-state-cursor-surface state) (%world-outputs world))))
   (%world-seats world))
  (%configure-application world)
  output)

(defmethod ataxia.kernel:world-seat-added
    ((world fullscreen-world) seat)
  (let ((state (%make-seat-state)))
    (when (%primary-output world)
      (multiple-value-bind (width height)
          (%output-logical-size (%primary-output world))
        (setf (%seat-state-x state) (/ width 2d0)
              (%seat-state-y state) (/ height 2d0))))
    (setf (gethash seat (%world-seats world)) state))
  (%focus-application world)
  seat)

(defmethod ataxia.kernel:world-seat-removing
    ((world fullscreen-world) seat)
  (remhash seat (%world-seats world))
  seat)

(defun %clamp-coordinate (value extent)
  (max 0d0 (min (max 0d0 (- extent least-positive-double-float)) value)))

(defun %update-cursor-position (world state input)
  (let ((output (%primary-output world)))
    (when output
      (multiple-value-bind (width height) (%output-logical-size output)
        (if (ataxia.kernel:cursor-motion-input-absolute-p input)
            (setf (%seat-state-x state)
                  (%clamp-coordinate
                   (* (ataxia.kernel:cursor-motion-input-x input) width)
                   width)
                  (%seat-state-y state)
                  (%clamp-coordinate
                   (* (ataxia.kernel:cursor-motion-input-y input) height)
                   height))
            (setf (%seat-state-x state)
                  (%clamp-coordinate
                   (+ (%seat-state-x state)
                      (ataxia.kernel:cursor-motion-input-delta-x input))
                   width)
                  (%seat-state-y state)
                  (%clamp-coordinate
                   (+ (%seat-state-y state)
                      (ataxia.kernel:cursor-motion-input-delta-y input))
                   height))))))
  state)

(defun %application-local-position (world state)
  (let ((application (%world-application world))
        (output (%primary-output world)))
    (when (and application output
               (ataxia.kernel:application-mapped-p application))
      (multiple-value-bind (output-width output-height)
          (%output-logical-size output)
        (multiple-value-bind (x y width height)
            (ataxia.kernel:drawable-local-bounds application)
          (values
           (+ x (* (/ (%seat-state-x state) output-width) width))
           (+ y (* (/ (%seat-state-y state) output-height) height))))))))

(defun %deliver-pointer-input (world seat state input function)
  (let ((application (%world-application world)))
    (multiple-value-bind (local-x local-y)
        (%application-local-position world state)
      (if (and application local-x local-y)
          (funcall function
                   application world seat local-x local-y input)
          (ataxia.kernel:clear-wayland-focus seat :pointer t)))))

(defmethod ataxia.kernel:world-cursor-motion
    ((world fullscreen-world) seat input)
  (let ((state (gethash seat (%world-seats world))))
    (when state
      (%update-cursor-position world state input)
      (%deliver-pointer-input
       world seat state input #'ataxia.kernel:interactable-pointer-motion)
      (%request-all-frames world)))
  input)

(defmethod ataxia.kernel:world-cursor-button
    ((world fullscreen-world) seat input)
  (let ((state (gethash seat (%world-seats world))))
    (when state
      (when (eq (ataxia.kernel:cursor-button-input-state input) :pressed)
        (%focus-application world))
      (%deliver-pointer-input
       world seat state input #'ataxia.kernel:interactable-pointer-button)))
  input)

(defmethod ataxia.kernel:world-cursor-axis
    ((world fullscreen-world) seat input)
  (let ((state (gethash seat (%world-seats world))))
    (when state
      (%deliver-pointer-input
       world seat state input #'ataxia.kernel:interactable-pointer-axis)))
  input)

(defmethod ataxia.kernel:world-key-event
    ((world fullscreen-world) seat input)
  (let ((application (%world-application world)))
    (when (and application (ataxia.kernel:application-mapped-p application))
      (ataxia.kernel:interactable-key-event
       application world seat input)))
  input)

(defmethod ataxia.kernel:world-seat-cursor-request
    ((world fullscreen-world) seat request)
  (let ((state (gethash seat (%world-seats world))))
    (when state
      (let ((old-surface (%seat-state-cursor-surface state))
            (new-surface
              (ataxia.kernel:cursor-surface-request-surface request)))
        (when (and old-surface (not (eq old-surface new-surface)))
          (%set-drawable-membership old-surface nil))
        (setf (%seat-state-cursor-surface state) new-surface
              (%seat-state-hotspot-x state)
              (ataxia.kernel:cursor-surface-request-hotspot-x request)
              (%seat-state-hotspot-y state)
              (ataxia.kernel:cursor-surface-request-hotspot-y request))
        (when new-surface
          (%set-drawable-membership new-surface (%world-outputs world)))
        (%request-all-frames world))))
  request)

(defmethod ataxia.kernel:world-client-request
    ((world fullscreen-world) object request)
  (declare (ignore request))
  (when (eq object (%world-application world))
    (%configure-application world)
    (%request-all-frames world))
  object)

(defmethod ataxia.kernel:world-graphics-attached
    ((world fullscreen-world) graphics-context)
  (declare (ignore graphics-context))
  (setf (%world-renderer world) (%make-renderer))
  world)

(defun %draw-application (world output target-width target-height)
  (declare (ignore output))
  (let ((application (%world-application world))
        (tokens nil))
    (when (and application (ataxia.kernel:application-mapped-p application))
      (multiple-value-bind (surfaces revision)
          (ataxia.kernel:drawable-surfaces application)
        (declare (ignore revision))
        (multiple-value-bind (root-x root-y root-width root-height)
            (ataxia.kernel:drawable-local-bounds application)
          (declare (ignore root-x root-y))
          (let ((scale-x (/ target-width (max 1 root-width)))
                (scale-y (/ target-height (max 1 root-height))))
            (loop for surface across surfaces
                  do (%draw-surface
                      (%world-renderer world) surface
                      (* (ataxia.kernel:drawable-surface-local-x surface)
                         scale-x)
                      (* (ataxia.kernel:drawable-surface-local-y surface)
                         scale-y)
                      (* (ataxia.kernel:drawable-surface-width surface)
                         scale-x)
                      (* (ataxia.kernel:drawable-surface-height surface)
                         scale-y)
                      target-width target-height)
                     (let ((token
                             (ataxia.kernel:drawable-surface-presentation-token
                              surface)))
                       (when token
                         (push token tokens))))))))
    tokens))

(defun %draw-cursors (world output target-width target-height)
  (multiple-value-bind (logical-width logical-height)
      (%output-logical-size output)
    (let ((scale-x (/ target-width logical-width))
          (scale-y (/ target-height logical-height))
          (tokens nil))
      (maphash
       (lambda (seat state)
         (declare (ignore seat))
         (let ((cursor (%seat-state-cursor-surface state)))
           (when cursor
             (multiple-value-bind (surfaces revision)
                 (ataxia.kernel:drawable-surfaces cursor)
               (declare (ignore revision))
               (loop for surface across surfaces
                     do (%draw-surface
                         (%world-renderer world) surface
                         (* (+ (- (%seat-state-x state)
                                  (%seat-state-hotspot-x state))
                               (ataxia.kernel:drawable-surface-local-x surface))
                            scale-x)
                         (* (+ (- (%seat-state-y state)
                                  (%seat-state-hotspot-y state))
                               (ataxia.kernel:drawable-surface-local-y surface))
                            scale-y)
                         (* (ataxia.kernel:drawable-surface-width surface)
                            scale-x)
                         (* (ataxia.kernel:drawable-surface-height surface)
                            scale-y)
                         target-width target-height)
                        (let ((token
                                (ataxia.kernel:drawable-surface-presentation-token
                                 surface)))
                          (when token
                            (push token tokens))))))))
       (%world-seats world))
      tokens)))

(defmethod ataxia.kernel:world-render
    ((world fullscreen-world) frame)
  (unless (%world-renderer world)
    (error "Fullscreen World renderer is not attached."))
  (%begin-output-render (%world-renderer world))
  (let* ((output (ataxia.kernel:frame-output frame))
         (width (ataxia.kernel:frame-width frame))
         (height (ataxia.kernel:frame-height frame))
         (tokens
           (nconc
            (%draw-application world output width height)
            (%draw-cursors world output width height))))
    (%finish-output-render)
    (make-instance
     'ataxia.kernel:world-frame-result
     :target-token (ataxia.kernel:frame-target-token frame)
     :damage
     (vector
      (ataxia.kernel:make-frame-damage-rectangle 0 0 width height))
     :presentation-tokens (coerce (remove-duplicates tokens :test #'eq) 'vector)
     :complete-p t
     :world-cookie nil)))

(defmethod ataxia.kernel:world-frame-committed
    ((world fullscreen-world) output result commit-info)
  (declare (ignore world output result commit-info))
  nil)

(defmethod ataxia.kernel:world-frame-failed
    ((world fullscreen-world) output result reason)
  (declare (ignore result))
  (format *error-output* "[fullscreen-world] frame on ~A failed: ~A~%"
          (ataxia.kernel:output-name output) reason)
  (finish-output *error-output*)
  (when (and (%world-active-p world)
             (eq (ataxia.kernel:object-state output) :live))
    (ataxia.kernel:request-output-frame output))
  nil)

(defmethod ataxia.kernel:world-graphics-detaching
    ((world fullscreen-world) graphics-context reason)
  (declare (ignore graphics-context reason))
  (%destroy-renderer (%world-renderer world))
  (setf (%world-renderer world) nil)
  world)
