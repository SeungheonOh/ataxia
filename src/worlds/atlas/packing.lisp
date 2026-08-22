;;;; Growing binary-tree rectangle packer.
;;;;
;;;; The packer treats windows like texture-atlas entries. It produces one
;;;; irregular, gap-free subdivision without assigning durable coordinates to
;;;; any window. Repacking is deterministic for a given ordered window set.

(in-package #:ataxia.atlas-world)

(defstruct (%packing-node
             (:constructor %make-packing-node (x y width height)))
  (x 0d0 :type double-float)
  (y 0d0 :type double-float)
  (width 0d0 :type double-float)
  (height 0d0 :type double-float)
  (used-p nil :type boolean)
  right down)

(defun %find-packing-node (node width height)
  (when node
    (if (%packing-node-used-p node)
        (or (%find-packing-node (%packing-node-right node) width height)
            (%find-packing-node (%packing-node-down node) width height))
        (and (<= width (%packing-node-width node))
             (<= height (%packing-node-height node))
             node))))

(defun %split-packing-node (node width height)
  (setf (%packing-node-used-p node) t
        (%packing-node-down node)
        (%make-packing-node
         (%packing-node-x node) (+ (%packing-node-y node) height)
         (%packing-node-width node) (- (%packing-node-height node) height))
        (%packing-node-right node)
        (%make-packing-node
         (+ (%packing-node-x node) width) (%packing-node-y node)
         (- (%packing-node-width node) width) height))
  node)

(defun %grow-packing-right (root width height)
  (let ((grown
          (%make-packing-node
           0d0 0d0 (+ (%packing-node-width root) width)
           (%packing-node-height root))))
    (setf (%packing-node-used-p grown) t
          (%packing-node-down grown) root
          (%packing-node-right grown)
          (%make-packing-node
           (%packing-node-width root) 0d0 width
           (%packing-node-height root)))
    (values grown
            (%split-packing-node
             (%find-packing-node grown width height) width height))))

(defun %grow-packing-down (root width height)
  (let ((grown
          (%make-packing-node
           0d0 0d0 (%packing-node-width root)
           (+ (%packing-node-height root) height))))
    (setf (%packing-node-used-p grown) t
          (%packing-node-right grown) root
          (%packing-node-down grown)
          (%make-packing-node
           0d0 (%packing-node-height root)
           (%packing-node-width root) height))
    (values grown
            (%split-packing-node
             (%find-packing-node grown width height) width height))))

(defun %grow-packing (root width height)
  (let* ((can-grow-down (<= width (%packing-node-width root)))
         (can-grow-right (<= height (%packing-node-height root)))
         (prefer-right
           (and can-grow-right
                (>= (%packing-node-height root)
                    (+ (%packing-node-width root) width))))
         (prefer-down
           (and can-grow-down
                (>= (%packing-node-width root)
                    (+ (%packing-node-height root) height)))))
    (cond (prefer-right (%grow-packing-right root width height))
          (prefer-down (%grow-packing-down root width height))
          (can-grow-right (%grow-packing-right root width height))
          (can-grow-down (%grow-packing-down root width height))
          (t (error "Atlas packer cannot grow around ~Dx~D." width height)))))

(defun %packing-order (windows)
  (stable-sort
   (copy-list windows)
   (lambda (left right)
     (let ((left-side (max (atlas-window-width left)
                           (atlas-window-height left)))
           (right-side (max (atlas-window-width right)
                            (atlas-window-height right))))
       (> left-side right-side)))))

(defun %pack-atlas (windows)
  "Return a placement table and the packed extent for visible WINDOWS."
  (let ((ordered (%packing-order windows))
        (placements (make-hash-table :test #'eq)))
    (if (null ordered)
        (values placements 0d0 0d0)
        (let* ((first (first ordered))
               (root
                 (%make-packing-node
                  0d0 0d0 (atlas-window-width first)
                  (atlas-window-height first))))
          (dolist (window ordered)
            (let* ((width (atlas-window-width window))
                   (height (atlas-window-height window))
                   (node (%find-packing-node root width height)))
              (if node
                  (setf node (%split-packing-node node width height))
                  (multiple-value-setq (root node)
                    (%grow-packing root width height)))
              (setf (gethash window placements)
                    (%make-atlas-placement
                     window (%packing-node-x node) (%packing-node-y node)
                     width height))))
          (values placements
                  (%packing-node-width root)
                  (%packing-node-height root))))))

(defun %layout-transition-progress (layout timestamp)
  (if (%atlas-layout-previous layout)
      (max 0d0
           (min 1d0
                (/ (- timestamp (%atlas-layout-transition-start layout))
                   (%atlas-layout-transition-duration layout))))
      1d0))

(defun %placement-geometry (layout window timestamp)
  (let ((target (gethash window (%atlas-layout-placements layout))))
    (when target
      (let* ((previous
               (and (%atlas-layout-previous layout)
                    (gethash window (%atlas-layout-previous layout))))
             (progress (%layout-transition-progress layout timestamp))
             (eased (ataxia.world:ease-out-cubic progress)))
        (if previous
            (flet ((blend (old new)
                     (+ old (* (- new old) eased))))
              (values (blend (%atlas-placement-x previous)
                             (%atlas-placement-x target))
                      (blend (%atlas-placement-y previous)
                             (%atlas-placement-y target))
                      (blend (%atlas-placement-width previous)
                             (%atlas-placement-width target))
                      (blend (%atlas-placement-height previous)
                             (%atlas-placement-height target))))
            (values (%atlas-placement-x target)
                    (%atlas-placement-y target)
                    (%atlas-placement-width target)
                    (%atlas-placement-height target)))))))
