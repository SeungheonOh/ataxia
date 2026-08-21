;;;; Live compositor object model.
;;;;
;;;; Surface records own retained client buffers. Desktop objects interpret XDG
;;;; roles as applications, views, popups, and stacking relationships.

(in-package #:ataxia.compositor)

(defparameter *trace-graphics-p*
  (not (null (uiop:getenv "ATAXIA_TRACE_GRAPHICS"))))

(defclass presentation-state ()
  ((opacity :initform 1d0 :accessor presentation-opacity)
   (scale :initform 1d0 :accessor presentation-scale)
   (offset-x :initform 0d0 :accessor presentation-offset-x)
   (offset-y :initform 0d0 :accessor presentation-offset-y)
   (shader-uniforms :initform (make-hash-table :test #'equal)
                    :reader presentation-shader-uniforms)))

(defclass behavior-view-state ()
  ((placement :initarg :placement :initform nil
              :accessor behavior-state-placement)
   (width :initarg :width :initform 900
          :accessor behavior-state-width)
   (height :initarg :height :initform 650
           :accessor behavior-state-height)
   (restore-state :initarg :restore-state :initform nil
                  :accessor behavior-state-restore-state)
   (animation-policy :initarg :animation-policy :initform nil
                     :accessor behavior-state-animation-policy)
   (shader-program-name :initarg :shader-program-name :initform nil
                        :accessor behavior-state-shader-program-name)
   (presentation-state :initarg :presentation-state
                       :initform (make-instance 'presentation-state)
                       :reader behavior-state-presentation-state)))

(defclass surface-record ()
  ((native :initarg :native :reader surface-record-native)
   (buffer :initform nil :accessor surface-record-buffer)
   (texture :initform nil :accessor surface-record-texture)
   (width :initform 0 :accessor surface-record-width)
   (height :initform 0 :accessor surface-record-height)
   (mapped-p :initform nil :accessor surface-record-mapped-p)
   (commit-sequence :initform 0 :accessor surface-record-commit-sequence)))

(defclass surface-system (compositor-component)
  ((records :initform (make-hash-table :test #'eq)
            :reader surface-records)
   (subsurfaces :initform (make-hash-table :test #'eq)
                :reader surface-subsurfaces)
   (children :initform (make-hash-table :test #'eq)
             :reader surface-children)))

(defclass application ()
  ((id :initarg :id :reader application-id)
   (app-id :initarg :app-id :accessor application-app-id)
   (views :initform nil :accessor application-views)))

(defclass view ()
  ((id :initarg :id :reader view-id)
   (native :initarg :native :reader view-native)
   (surface :initarg :surface :reader view-surface)
   (application :initarg :application :accessor view-application)
   (behavior-state :initform (make-instance 'behavior-view-state)
                   :accessor view-behavior-state)
   (title :initarg :title :initform nil :accessor view-title)
   (decoration-mode :initform :client-side :accessor view-decoration-mode)
   (initialized-p :initform nil :accessor view-initialized-p)
   (mapped-p :initform nil :accessor view-mapped-p)
   (presentable-p :initform nil :accessor view-presentable-p)
   (maximized-p :initform nil :accessor view-maximized-p)
   (fullscreen-p :initform nil :accessor view-fullscreen-p)
   (minimized-p :initform nil :accessor view-minimized-p)
   (revision :initform 0 :accessor view-revision)))

(defun view-placement (view)
  (behavior-state-placement (view-behavior-state view)))

(defun (setf view-placement) (placement view)
  (setf (behavior-state-placement (view-behavior-state view)) placement))

(defun view-width (view)
  (behavior-state-width (view-behavior-state view)))

(defun (setf view-width) (width view)
  (setf (behavior-state-width (view-behavior-state view)) width))

(defun view-height (view)
  (behavior-state-height (view-behavior-state view)))

(defun (setf view-height) (height view)
  (setf (behavior-state-height (view-behavior-state view)) height))

(defun view-restore-placement (view)
  (behavior-state-restore-state (view-behavior-state view)))

(defun (setf view-restore-placement) (state view)
  (setf (behavior-state-restore-state (view-behavior-state view)) state))

(defun view-animation-policy (view)
  (behavior-state-animation-policy (view-behavior-state view)))

(defun (setf view-animation-policy) (policy view)
  (setf (behavior-state-animation-policy (view-behavior-state view)) policy))

(defun view-shader-program-name (view)
  (behavior-state-shader-program-name (view-behavior-state view)))

(defun (setf view-shader-program-name) (name view)
  (setf (behavior-state-shader-program-name (view-behavior-state view)) name))

(defun view-presentation-state (view)
  (behavior-state-presentation-state (view-behavior-state view)))

(defun view-server-decorated-p (view)
  (eq :server-side (view-decoration-mode view)))

(defclass popup-view ()
  ((native :initarg :native :reader popup-native)
   (surface :initarg :surface :reader popup-surface)
   (parent :initarg :parent :reader popup-parent)
   (x :initform 0d0 :accessor popup-x)
   (y :initform 0d0 :accessor popup-y)
   (mapped-p :initform nil :accessor popup-mapped-p)))

(defclass desktop-system (compositor-component)
  ((applications :initform (make-hash-table :test #'equal)
                 :reader desktop-application-table)
   (views :initform (make-hash-table :test #'eq)
          :reader desktop-view-table)
   (popups :initform (make-hash-table :test #'eq)
           :reader desktop-popup-table)
   (stacking :initform nil :accessor desktop-stacking)
   (next-application-id :initform 0 :accessor desktop-next-application-id)
   (next-view-id :initform 0 :accessor desktop-next-view-id)))

(defun desktop-views (desktop)
  (loop for view being the hash-values of (desktop-view-table desktop)
        collect view))

(defun desktop-applications (desktop)
  (loop for application being the hash-values
          of (desktop-application-table desktop)
        collect application))

(defun desktop-stacking-order (desktop)
  (copy-list (desktop-stacking desktop)))

(defun ensure-surface-record (surfaces native)
  (or (gethash native (surface-records surfaces))
      (setf (gethash native (surface-records surfaces))
            (make-instance 'surface-record :native native))))

(defun release-surface-content (record)
  (let ((buffer (surface-record-buffer record)))
    (when buffer
      (ataxia.runtime:release-buffer buffer)))
  (setf (surface-record-buffer record) nil
        (surface-record-texture record) nil
        (surface-record-width record) 0
        (surface-record-height record) 0)
  record)

(defun refresh-surface-record (record commit)
  ;; Acquire the new buffer before releasing the old one so a failed import
  ;; cannot erase the last complete frame unexpectedly.
  (let* ((surface (surface-record-native record))
         (mapped-p (ataxia.runtime:surface-commit-mapped-p commit))
         (new-buffer
           (when mapped-p
             (ataxia.runtime:retain-surface-buffer surface)))
         (new-texture
           (when new-buffer
             (ataxia.runtime:buffer-texture new-buffer))))
    (when (and new-buffer (null new-texture))
      (ataxia.runtime:release-buffer new-buffer)
      (setf new-buffer nil))
    (release-surface-content record)
    (setf (surface-record-buffer record) new-buffer
          (surface-record-texture record) new-texture
          (surface-record-width record)
          (if new-buffer (ataxia.runtime:buffer-width new-buffer) 0)
          (surface-record-height record)
          (if new-buffer (ataxia.runtime:buffer-height new-buffer) 0)
          (surface-record-mapped-p record) mapped-p
          (surface-record-commit-sequence record)
          (ataxia.runtime:surface-commit-sequence commit)))
  (when (and *trace-graphics-p* (surface-record-texture record))
    (let ((attributes
            (ataxia.runtime:texture-gles-attributes
             (surface-record-texture record))))
      (format *error-output*
              "[graphics] surface ~X buffer=~Dx~D texture=~D target=0x~X alpha=~A~%"
              (ataxia.runtime:native-object-address
               (surface-record-native record))
              (surface-record-width record) (surface-record-height record)
              (ataxia.runtime:gles-texture-name attributes)
              (ataxia.runtime:gles-texture-target attributes)
              (ataxia.runtime:gles-texture-has-alpha-p attributes))
      (finish-output *error-output*)))
  record)

(defun retire-surface-record (surfaces native)
  (let ((record (gethash native (surface-records surfaces))))
    (when record
      (release-surface-content record)
      (remhash native (surface-records surfaces)))
    record))

(defun register-subsurface (surfaces parent subsurface)
  (setf (gethash subsurface (surface-subsurfaces surfaces)) parent)
  (let ((children (gethash parent (surface-children surfaces))))
    (setf (gethash parent (surface-children surfaces))
          (append (delete subsurface children :test #'eq)
                  (list subsurface))))
  subsurface)

(defun unregister-subsurface (surfaces subsurface)
  (let ((parent (gethash subsurface (surface-subsurfaces surfaces))))
    (when parent
      (setf (gethash parent (surface-children surfaces))
            (delete subsurface (gethash parent (surface-children surfaces))
                    :test #'eq))
      (when (null (gethash parent (surface-children surfaces)))
        (remhash parent (surface-children surfaces))))
    (remhash subsurface (surface-subsurfaces surfaces))
    parent))

(defun surface-child-subsurfaces (surfaces parent)
  (copy-list (gethash parent (surface-children surfaces))))

(defun application-key (desktop app-id)
  (if (and app-id (plusp (length app-id)))
      app-id
      (gensym "ANONYMOUS-")))

(defun ensure-application (desktop app-id)
  (let ((key (application-key desktop app-id)))
    (or (gethash key (desktop-application-table desktop))
        (setf (gethash key (desktop-application-table desktop))
              (make-instance 'application
                             :id (incf (desktop-next-application-id desktop))
                             :app-id app-id)))))

(defun desktop-register-view (desktop native surface-record app-id title)
  (let* ((application (ensure-application desktop app-id))
         (view
           (make-instance 'view
                          :id (incf (desktop-next-view-id desktop))
                          :native native :surface surface-record
                          :application application :title title)))
    (setf (gethash native (desktop-view-table desktop)) view
          (application-views application)
          (append (application-views application) (list view))
          (desktop-stacking desktop)
          (append (desktop-stacking desktop) (list view)))
    view))

(defun desktop-find-view (desktop native)
  (gethash native (desktop-view-table desktop)))

(defun desktop-find-view-by-surface (desktop native-surface)
  (find native-surface (desktop-views desktop)
        :key (lambda (view)
               (surface-record-native (view-surface view)))
        :test #'eq))

(defun desktop-find-popup-by-surface (desktop native-surface)
  (find native-surface (desktop-popups desktop)
        :key (lambda (popup)
               (surface-record-native (popup-surface popup)))
        :test #'eq))

(defun popup-parent-view (popup)
  (let ((parent (popup-parent popup)))
    (typecase parent
      (view parent)
      (popup-view (popup-parent-view parent))
      (t nil))))

(defun desktop-raise-view (desktop view)
  (setf (desktop-stacking desktop)
        (append (delete view (desktop-stacking desktop) :test #'eq)
                (list view)))
  view)

(defun desktop-remove-view (desktop native)
  (let ((view (gethash native (desktop-view-table desktop))))
    (when view
      (remhash native (desktop-view-table desktop))
      (setf (desktop-stacking desktop)
            (delete view (desktop-stacking desktop) :test #'eq))
      (let ((application (view-application view)))
        (setf (application-views application)
              (delete view (application-views application) :test #'eq))
        (when (null (application-views application))
          (let ((application-key nil))
            (maphash
             (lambda (key candidate)
               (when (eq application candidate)
                 (setf application-key key)))
             (desktop-application-table desktop))
            (when application-key
              (remhash application-key
                       (desktop-application-table desktop)))))))
    view))

(defmethod detach-component :before ((surfaces surface-system) reason)
  (declare (ignore reason))
  (maphash (lambda (native record)
             (declare (ignore native))
             (release-surface-content record))
           (surface-records surfaces))
  (clrhash (surface-records surfaces))
  (clrhash (surface-subsurfaces surfaces))
  (clrhash (surface-children surfaces)))

(defun desktop-update-view-identity (desktop view app-id title)
  (when title
    (setf (view-title view) title))
  (when (and app-id
             (not (equal app-id
                         (application-app-id (view-application view)))))
    (let ((old (view-application view))
          (new (ensure-application desktop app-id)))
      (setf (application-views old)
            (delete view (application-views old) :test #'eq)
            (view-application view) new)
      (pushnew view (application-views new) :test #'eq)))
  (incf (view-revision view))
  view)

(defun desktop-register-popup (desktop native surface-record parent)
  (let ((popup
          (make-instance 'popup-view :native native
                         :surface surface-record :parent parent)))
    (setf (gethash native (desktop-popup-table desktop)) popup)
    popup))

(defun desktop-find-popup (desktop native)
  (gethash native (desktop-popup-table desktop)))

(defun desktop-remove-popup (desktop native)
  (prog1 (gethash native (desktop-popup-table desktop))
    (remhash native (desktop-popup-table desktop))))

(defun desktop-popups (desktop)
  (loop for popup being the hash-values of (desktop-popup-table desktop)
        collect popup))
