;;;; Stable drag presentation; wlroots retains protocol and grab ownership.
(in-package #:ataxia.kernel)

(defclass drag-icon (drawable)
  ((root :initarg :root :reader %drag-icon-root)
   (revision :initform 0 :accessor %drag-icon-revision)))

(defmethod drawable-surfaces ((icon drag-icon))
  (let ((root (%drag-icon-root icon)) (records nil))
    (when (and (eq :live (object-state root)) (surface-mapped-p root))
      (%walk-surface-tree
       root
       (lambda (surface x y)
         (when (and (eq :live (object-state surface)) (surface-mapped-p surface))
           (loop for quad across (drawable-surfaces surface) do
             (setf (slot-value quad 'local-x) (+ x (%surface-offset-x root))
                   (slot-value quad 'local-y) (+ y (%surface-offset-y root)))
             (push quad records))))))
    (values (coerce (nreverse records) 'vector) (%drag-icon-revision icon))))

(defun seat-pointer-drag-active-p (seat)
  (and (eq :live (object-state seat))
       (ataxia.runtime:seat-pointer-drag-active-p (seat-runtime-object seat))))

(defun forward-pointer-drag-button (seat input)
  "Deliver a button to the current drag grab without re-entering its origin."
  (when (seat-pointer-drag-active-p seat)
    (ataxia.runtime:seat-pointer-notify-button
     (seat-runtime-object seat) (cursor-button-input-time-msec input)
     (cursor-button-input-code input) (cursor-button-input-state input))
    t))

(defun %set-seat-drag-icon (seat icon)
  (let ((previous (seat-drag-icon seat)))
    (when previous
      (loop for quad across (drawable-surfaces previous)
            for token = (drawable-surface-presentation-token quad)
            when token do (set-wayland-surface-output-membership token nil)))
    (setf (seat-drag-icon seat) icon)
    (%call-world (object-kernel seat) world-seat-drag-icon-changed seat)))

(defun %start-seat-drag (kernel runtime-seat drag)
  (let ((seat (gethash runtime-seat (%kernel-seat-table kernel))))
    (when seat
      (setf (%seat-drag seat) drag
            (%seat-implicit-pointer-grab seat) nil)
      (let ((surface (ataxia.runtime:drag-icon-surface drag)))
        (%set-seat-drag-icon
         seat (when surface
                (make-instance 'drag-icon :root (%ensure-surface-node kernel surface))))))))

(defmethod ataxia.runtime:drag-destroying ((kernel kernel) drag)
  (dolist (seat (kernel-seats kernel))
    (when (eq drag (%seat-drag seat))
      (setf (%seat-drag seat) nil)
      (%set-seat-drag-icon seat nil))))

(defun %drag-icon-contains-surface-p (icon surface)
  (loop for node = surface then (surface-parent node) while node
        thereis (eq node (%drag-icon-root icon))))

(defun %invalidate-surface-drag-icons (kernel surface)
  (dolist (seat (kernel-seats kernel))
    (let ((icon (seat-drag-icon seat)))
      (when (and icon (%drag-icon-contains-surface-p icon surface))
        (incf (%drag-icon-revision icon))
        (%call-world kernel world-seat-drag-icon-changed seat)))))

(defun %remove-destroyed-drag-surface (kernel surface)
  (dolist (seat (kernel-seats kernel))
    (let ((icon (seat-drag-icon seat)))
      (when (and icon (eq surface (%drag-icon-root icon)))
        (%set-seat-drag-icon seat nil))))
  (%invalidate-surface-drag-icons kernel surface))
