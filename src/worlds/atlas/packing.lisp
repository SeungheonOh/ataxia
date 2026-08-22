;;;; Clockwise outward component packer.
;;;;
;;;; Only mappings that opt into the packed plane participate. The algorithm
;;;; operates on ATLAS-OBJECT dimensions and never inspects their components.

(in-package #:ataxia.atlas-world)

(defparameter *packing-shape-weight* 0.22d0)
(defparameter *packing-sprawl-weight* 0.018d0)

(defun %placement-right (placement)
  (+ (%atlas-placement-x placement) (%atlas-placement-width placement)))

(defun %placement-bottom (placement)
  (+ (%atlas-placement-y placement) (%atlas-placement-height placement)))

(defun %placements-overlap-p (left right)
  (and (< (%atlas-placement-x left) (%placement-right right))
       (< (%atlas-placement-x right) (%placement-right left))
       (< (%atlas-placement-y left) (%placement-bottom right))
       (< (%atlas-placement-y right) (%placement-bottom left))))

(defun %interval-overlap (left-start left-end right-start right-end)
  (max 0d0 (- (min left-end right-end) (max left-start right-start))))

(defun %placement-contact (candidate placements)
  (loop for placement in placements
        sum
        (cond
          ((or (= (%atlas-placement-x candidate) (%placement-right placement))
               (= (%placement-right candidate) (%atlas-placement-x placement)))
           (%interval-overlap
            (%atlas-placement-y candidate) (%placement-bottom candidate)
            (%atlas-placement-y placement) (%placement-bottom placement)))
          ((or (= (%atlas-placement-y candidate) (%placement-bottom placement))
               (= (%placement-bottom candidate) (%atlas-placement-y placement)))
           (%interval-overlap
            (%atlas-placement-x candidate) (%placement-right candidate)
            (%atlas-placement-x placement) (%placement-right placement)))
          (t 0d0))))

(defun %packing-alignments (placements axis size)
  (remove-duplicates
   (loop for placement in placements
         append
         (ecase axis
           (:x (list (%atlas-placement-x placement)
                     (- (%placement-right placement) size)))
           (:y (list (%atlas-placement-y placement)
                     (- (%placement-bottom placement) size)))))
   :test #'=))

(defun %packing-candidates (object placements)
  (let* ((width (atlas-object-width object))
         (height (atlas-object-height object))
         (x-alignments (%packing-alignments placements :x width))
         (y-alignments (%packing-alignments placements :y height))
         (seen (make-hash-table :test #'equal))
         (candidates nil))
    (labels ((consider (direction x y)
               (let* ((key (list direction x y))
                      (candidate
                        (%make-atlas-placement object x y width height)))
                 (unless (or (gethash key seen)
                             (some (lambda (placement)
                                     (%placements-overlap-p candidate placement))
                                   placements))
                   (setf (gethash key seen) t)
                   (when (plusp (%placement-contact candidate placements))
                     (push (cons direction candidate) candidates))))))
      (dolist (anchor placements)
        (dolist (y y-alignments)
          (when (plusp
                 (%interval-overlap
                  y (+ y height)
                  (%atlas-placement-y anchor) (%placement-bottom anchor)))
            (consider :right (%placement-right anchor) y)
            (consider :left (- (%atlas-placement-x anchor) width) y)))
        (dolist (x x-alignments)
          (when (plusp
                 (%interval-overlap
                  x (+ x width)
                  (%atlas-placement-x anchor) (%placement-right anchor)))
            (consider :down x (%placement-bottom anchor))
            (consider :up x (- (%atlas-placement-y anchor) height))))))
    candidates))

(defun %direction-distance (direction preferred)
  (let ((directions '(:right :down :left :up)))
    (mod (- (position direction directions)
            (position preferred directions))
         4)))

(defun %packing-score (candidate direction preferred placements occupied-area)
  (let* ((all (cons candidate placements))
         (min-x (reduce #'min all :key #'%atlas-placement-x))
         (min-y (reduce #'min all :key #'%atlas-placement-y))
         (max-x (reduce #'max all :key #'%placement-right))
         (max-y (reduce #'max all :key #'%placement-bottom))
         (width (- max-x min-x))
         (height (- max-y min-y))
         (area (* width height))
         (square-area (expt (max width height) 2))
         (direction-distance (%direction-distance direction preferred))
         (compact-cost
           (+ area
              (* *packing-shape-weight* (- square-area area))
              (* *packing-sprawl-weight* area direction-distance)))
         (unused-area
           (- area occupied-area
              (* (%atlas-placement-width candidate)
                 (%atlas-placement-height candidate))))
         (contact (%placement-contact candidate placements)))
    (list compact-cost unused-area (- contact) area min-y min-x)))

(defun %score-less-p (left right)
  (loop for left-value in left
        for right-value in right
        when (< left-value right-value) return t
        when (> left-value right-value) return nil
        finally (return nil)))

(defun %best-packing-candidate (object placements preferred occupied-area)
  (let ((best nil)
        (best-score nil))
    (dolist (entry (%packing-candidates object placements))
      (let ((score
              (%packing-score
               (cdr entry) (car entry) preferred placements occupied-area)))
        (when (or (null best-score) (%score-less-p score best-score))
          (setf best entry
                best-score score))))
    (or best (error "No edge-adjacent atlas placement is available."))))

(defun %normalize-packed-placements (placements min-x min-y)
  (dolist (placement placements)
    (decf (%atlas-placement-x placement) min-x)
    (decf (%atlas-placement-y placement) min-y))
  placements)

(defun %pack-atlas (objects)
  "Pack visible OBJECTS clockwise by insertion order and return their extent."
  (let ((table (make-hash-table :test #'eq)))
    (if (null objects)
        (values table 0d0 0d0)
        (let* ((first (first objects))
               (first-placement
                 (%make-atlas-placement
                  first 0d0 0d0
                  (atlas-object-width first) (atlas-object-height first)))
               (placed (list first-placement))
               (occupied-area
                 (* (%atlas-placement-width first-placement)
                    (%atlas-placement-height first-placement)))
               (min-x 0d0)
               (min-y 0d0)
               (max-x (%placement-right first-placement))
               (max-y (%placement-bottom first-placement)))
          (setf (gethash first table) first-placement)
          (loop for object in (rest objects)
                for index from 0
                for preferred = (nth (mod index 4) '(:right :down :left :up))
                for entry =
                  (%best-packing-candidate
                   object placed preferred occupied-area)
                for placement = (cdr entry)
                do (push placement placed)
                   (incf occupied-area
                         (* (%atlas-placement-width placement)
                            (%atlas-placement-height placement)))
                   (setf (gethash object table) placement
                         min-x (min min-x (%atlas-placement-x placement))
                         min-y (min min-y (%atlas-placement-y placement))
                         max-x (max max-x (%placement-right placement))
                         max-y (max max-y (%placement-bottom placement))))
          (%normalize-packed-placements placed min-x min-y)
          (values table (- max-x min-x) (- max-y min-y))))))

(defun %layout-transition-progress (layout timestamp)
  (if (%atlas-layout-previous layout)
      (max 0d0
           (min 1d0
                (/ (- timestamp (%atlas-layout-transition-start layout))
                   (%atlas-layout-transition-duration layout))))
      1d0))

(defun %placement-geometry (layout object timestamp)
  (let ((target (gethash object (%atlas-layout-placements layout))))
    (when target
      (let* ((previous
               (and (%atlas-layout-previous layout)
                    (gethash object (%atlas-layout-previous layout))))
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
