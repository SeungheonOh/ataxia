;;;; Reusable output-buffer damage history.
;;;;
;;;; The tracker accepts final output-buffer regions. It knows nothing about a
;;;; World's geometry and keeps pending damage until Kernel confirms a commit.

(in-package #:ataxia.world)

(defun coalesce-damage-region (rectangles &key width height (rectangle-limit 32) (merge-cost 1024))
  "Bound pixel damage while trading extra pixels against repeated draw passes.
MERGE-COST is the estimated per-rectangle overhead expressed in pixels. Work on
at most RECTANGLE-LIMIT+1 candidates at a time, even for a large client update.
The result always covers the input and must never be used as opaque coverage."
  (check-type rectangle-limit (integer 1))
  (check-type merge-cost (real 0))
  (let ((region nil)
        (bounds (and width height (make-rectangle 0 0 width height))))
    (labels ((cost (a b)
               (- (rectangle-area (rectangle-union a b)) (rectangle-area a) (rectangle-area b)))
             (insert (rectangle)
               (loop
                 (let ((best nil) (best-cost nil))
                   (dolist (candidate region)
                     (let ((extra (cost rectangle candidate)))
                       (when (and (<= extra merge-cost) (or (null best-cost) (< extra best-cost)))
                         (setf best candidate best-cost extra))))
                   (unless best (push rectangle region) (return))
                   (setf rectangle (rectangle-union rectangle best)
                         region (delete best region :test #'eq :count 1)))))
             (reduce-count ()
               (let ((left nil) (right nil) (best-cost nil))
                 (loop for tail on region do
                   (dolist (candidate (cdr tail))
                     (let ((extra (cost (car tail) candidate)))
                       (when (or (null best-cost) (< extra best-cost))
                         (setf left (car tail) right candidate best-cost extra)))))
                 (setf region (delete left region :test #'eq :count 1)
                       region (delete right region :test #'eq :count 1))
                 (insert (rectangle-union left right)))))
      (dolist (rectangle rectangles)
        (unless (rectangle-empty-p rectangle)
          (let* ((x (floor (rectangle-x rectangle))) (y (floor (rectangle-y rectangle)))
                 (pixels (make-rectangle x y (- (ceiling (rectangle-right rectangle)) x)
                                               (- (ceiling (rectangle-bottom rectangle)) y)))
                 (clipped (if bounds (rectangle-intersection pixels bounds) pixels)))
            (when clipped
              (insert clipped)
              (when (> (length region) rectangle-limit) (reduce-count))))))
      (when region
        (let* ((box (reduce #'rectangle-union region))
               (cost (+ (reduce #'+ region :key #'rectangle-area) (* merge-cost (length region)))))
          (cond
            ((and bounds (<= (+ (rectangle-area bounds) merge-cost) cost)) (setf region (list bounds)))
            ((<= (+ (rectangle-area box) merge-cost) cost) (setf region (list box)))))))
    (nreverse region)))

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
    ;; Before a full frame is staged, its existing full damage covers everything.
    ;; During staging, preserve a new list identity so commit cannot eat changes
    ;; that arrived after the frame snapshot.
    (unless (and (%damage-output-full-p state) (null (%damage-output-staged state)))
      (setf (%damage-output-pending state)
            (coalesce-damage-region
             (append region (%damage-output-pending state))
             :width (%damage-output-width state) :height (%damage-output-height state)))))
  tracker)

(defun damage-full-output (tracker output)
  (let ((state (%damage-output tracker output)))
    (setf (%damage-output-full-p state) t)
    (when (%damage-output-staged state)
      (setf (%damage-output-pending state)
            (list (make-rectangle 0 0 (%damage-output-width state) (%damage-output-height state))))))
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
             (coalesce-damage-region (if full-p full-region pending) :width width :height height))
           (repair
             (coalesce-damage-region
              (append new-region
                      (unless full-p
                        (%history-repair state target full-region)))
              :width width :height height))
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
