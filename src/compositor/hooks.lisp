;;;; Typed synchronous extension hooks.
;;;;
;;;; Hooks are optional policy and observation points. Required compositor
;;;; behavior uses direct calls and never relies on a hook broadcast.

(in-package #:ataxia.compositor)

(defstruct hook-handler
  function
  (priority 0 :type fixnum)
  (sequence 0 :type fixnum)
  name)

(defclass hook-point ()
  ((name :initarg :name :reader hook-point-name)
   (mode :initarg :mode :reader hook-point-mode)
   (limit :initarg :limit :initform 64 :reader hook-point-limit)
   (handlers :initform nil :accessor hook-point-handlers)
   (next-sequence :initform 0 :accessor hook-point-next-sequence)))

(defclass hook-registry ()
  ((points :initform (make-hash-table :test #'eq)
           :reader hook-registry-points)))

(defclass extension-system (compositor-component)
  ((hooks :initform (make-instance 'hook-registry)
          :reader extension-hooks)))

(defclass hook-context (operation-context) ())

(defparameter *standard-hook-points*
  '((before-interactive-operation :veto 64)
    (after-interactive-operation :observe 64)
    (animation-resolving :transform 64)
    (before-animation-start :veto 64)
    (after-animation-start :observe 64)
    (animation-cancelled :observe 64)
    (animation-completed :observe 64)))

(defun ensure-hook-point (registry name mode &key (limit 64))
  (or (gethash name (hook-registry-points registry))
      (setf (gethash name (hook-registry-points registry))
            (make-instance 'hook-point
                           :name name :mode mode :limit limit))))

(defmethod attach-component :after ((extensions extension-system))
  ;; Predeclaring framework hooks prevents the first plugin from accidentally
  ;; selecting incompatible dispatch semantics for a public hook point.
  (dolist (specification *standard-hook-points*)
    (destructuring-bind (name mode limit) specification
      (ensure-hook-point (extension-hooks extensions) name mode :limit limit))))

(defun register-hook
    (registry name function &key (mode :observe) (priority 0) handler-name)
  (check-type registry hook-registry)
  (check-type function function)
  (unless (member mode '(:observe :veto :transform :around) :test #'eq)
    (error 'compositor-error))
  (let ((point (ensure-hook-point registry name mode)))
    (unless (eq mode (hook-point-mode point))
      (error 'compositor-error))
    (when (>= (length (hook-point-handlers point)) (hook-point-limit point))
      (error 'compositor-error))
    (let ((handler
            (make-hook-handler
             :function function :priority priority
             :sequence (incf (hook-point-next-sequence point))
             :name handler-name)))
      (push handler (hook-point-handlers point))
      handler)))

(defun unregister-hook (registry name handler)
  (let ((point (gethash name (hook-registry-points registry))))
    (when point
      (setf (hook-point-handlers point)
            (delete handler (hook-point-handlers point) :test #'eq))))
  nil)

(defun ordered-hook-handlers (point)
  ;; Sequence breaks equal-priority ties so live registration stays predictable.
  (sort (copy-list (hook-point-handlers point))
        (lambda (left right)
          (or (> (hook-handler-priority left)
                 (hook-handler-priority right))
              (and (= (hook-handler-priority left)
                      (hook-handler-priority right))
                   (< (hook-handler-sequence left)
                      (hook-handler-sequence right)))))))

(defun run-hook (registry name context &optional terminal)
  (check-type registry hook-registry)
  (check-type context hook-context)
  (let ((point (gethash name (hook-registry-points registry))))
    (unless point
      (return-from run-hook
        (if terminal (funcall terminal context) context)))
    (let ((handlers (ordered-hook-handlers point)))
      (ecase (hook-point-mode point)
        (:observe
         (dolist (handler handlers context)
           (funcall (hook-handler-function handler) context)))
        (:veto
         (dolist (handler handlers context)
           (unless (funcall (hook-handler-function handler) context)
             (error 'hook-vetoed
                    :hook name :handler (or (hook-handler-name handler)
                                             handler)))))
        (:transform
         (dolist (handler handlers context)
           (let ((replacement
                   (funcall (hook-handler-function handler) context)))
             (when replacement
               (check-type replacement hook-context)
               (setf context replacement)))))
        (:around
         (labels ((invoke (remaining current)
                    (if remaining
                        (funcall (hook-handler-function (first remaining))
                                 current
                                 (lambda (next)
                                   (invoke (rest remaining) next)))
                        (if terminal
                            (funcall terminal current)
                            current))))
           (invoke handlers context)))))))
