;;;; Optional World application. Browser UI + regular scene window + sleeping I/O worker.
(defpackage #:ataxia.world.web.notes
  (:use #:cl)
  (:export #:open-notebook #:close-notebook #:default-notebook-path))
(in-package #:ataxia.world.web.notes)

(defconstant +maximum-bytes+ (* 768 1024))
(defstruct notebook-service
  world widget path
  (lock (sb-thread:make-mutex :name "Commonplace state"))
  (wake (sb-thread:make-semaphore :name "Commonplace save"))
  thread fd source stopped pending results ready loaded document document-sent (revision 0) error)

(defun default-notebook-path ()
  (merge-pathnames "ataxia/commonplace.json"
    (uiop:ensure-directory-pathname
      (or (let ((value (uiop:getenv "XDG_DATA_HOME")))
            (and value (plusp (length value)) (uiop:absolute-pathname-p value) value))
          (merge-pathnames ".local/share/" (user-homedir-pathname))))))

(defun %close-fd (fd)
  (when fd (cffi:foreign-funcall "close" :int fd :int)))
(defun %publish (service result)
  (sb-thread:with-mutex ((notebook-service-lock service))
    (unless (notebook-service-stopped service)
      (push result (notebook-service-results service))
      (cffi:with-foreign-object (value :uint64)
        (setf (cffi:mem-ref value :uint64) 1)
        (cffi:foreign-funcall "write" :int (notebook-service-fd service) :pointer value :size 8 :long)))))

(defun %read-document (path)
  (with-open-file (in path :element-type '(unsigned-byte 8) :if-does-not-exist nil)
    (if (null in) ""
        (let ((size (file-length in)))
          (when (> size +maximum-bytes+) (error "Notebook exceeds the 768 KiB limit; file left unchanged."))
          (let ((bytes (make-array size :element-type '(unsigned-byte 8))))
            (unless (= size (read-sequence bytes in)) (error "Incomplete notebook read; file left unchanged."))
            ;; An existing empty file is invalid, not permission to seed new data.
            (when (zerop size) (error "Notebook file is empty; file left unchanged."))
            (sb-ext:octets-to-string bytes :external-format :utf-8))))))

(defun %write-document (path text)
  (let* ((bytes (sb-ext:string-to-octets text :external-format :utf-8))
         (temporary (pathname (format nil "~A.~A.tmp" (namestring path) (symbol-name (gensym "save-")))))
         (fd nil))
    (when (> (length bytes) +maximum-bytes+) (error "Notebook exceeds the 768 KiB limit."))
    (unwind-protect
         (progn
           (setf fd (cffi:foreign-funcall "open" :string (namestring temporary) :int #x800c1 :int #o600 :int))
           (when (minusp fd) (setf fd nil) (error "Cannot create notebook save file."))
           (let ((out (sb-sys:make-fd-stream fd :output t :element-type '(unsigned-byte 8) :auto-close t)))
             (setf fd nil)
             (unwind-protect
                  (progn (write-sequence bytes out) (finish-output out)
                         (unless (zerop (cffi:foreign-funcall "fsync" :int (sb-sys:fd-stream-fd out) :int))
                           (error "Cannot flush notebook save file.")))
               (close out)))
           (uiop:rename-file-overwriting-target temporary path)
           (let ((directory (cffi:foreign-funcall "open" :string (namestring (uiop:pathname-directory-pathname path)) :int #x90000 :int)))
             (when (minusp directory) (error "Cannot open notebook directory for sync."))
             (unwind-protect
                  (unless (zerop (cffi:foreign-funcall "fsync" :int directory :int))
                    (error "Cannot sync notebook directory."))
               (%close-fd directory))))
      (%close-fd fd)
      (when (probe-file temporary) (delete-file temporary)))))

(defun %run-storage (service)
  (let ((path (notebook-service-path service)) (lock-fd nil))
    (unwind-protect
         (handler-case
             (progn
               (ensure-directories-exist path)
               (setf lock-fd (cffi:foreign-funcall "open" :string (concatenate 'string (namestring path) ".lock")
                                                :int #x80042 :int #o600 :int))
               (when (minusp lock-fd) (setf lock-fd nil) (error "Cannot open notebook lock."))
               (unless (zerop (cffi:foreign-funcall "flock" :int lock-fd :int 6 :int))
                 (error "This notebook is already open in another World."))
               (%publish service (list :loaded (%read-document path)))
               (loop
                 (sb-thread:wait-on-semaphore (notebook-service-wake service))
                 (multiple-value-bind (pending stopped)
                     (sb-thread:with-mutex ((notebook-service-lock service))
                       (values (shiftf (notebook-service-pending service) nil) (notebook-service-stopped service)))
                   (when pending
                     (handler-case
                         (progn (%write-document path (cdr pending))
                                (%publish service (list :saved (car pending) (cdr pending))))
                       (error (cause) (%publish service (list :error (princ-to-string cause))))))
                   ;; A final queued save is drained before releasing the lock.
                   (when stopped (return)))))
           (error (cause) (%publish service (list :error (princ-to-string cause)))))
      (%close-fd lock-fd))))

(defun %sync-model (service)
  (when (and (notebook-service-ready service) (notebook-service-widget service))
    (let ((component (ataxia.world:ui-application-component (notebook-service-widget service))))
      (when (and (notebook-service-loaded service) (not (notebook-service-document-sent service)))
        (ataxia.world.web.ui:set-ui-model component "notebook-document" (notebook-service-document service))
        (setf (notebook-service-document-sent service) t))
      (ataxia.world.web.ui:set-ui-model component "notebook-path" (namestring (notebook-service-path service)))
      (ataxia.world.web.ui:set-ui-model component "saved-revision" (notebook-service-revision service))
      (ataxia.world.web.ui:set-ui-model component "notebook-error" (or (notebook-service-error service) "")))))

(defun %consume-results (service)
  (let ((results (sb-thread:with-mutex ((notebook-service-lock service))
                   (nreverse (shiftf (notebook-service-results service) nil)))))
    (dolist (result results)
      (ecase (first result)
        (:loaded (setf (notebook-service-loaded service) t (notebook-service-document service) (second result)))
        (:saved (setf (notebook-service-revision service) (second result)
                      (notebook-service-document service) (third result) (notebook-service-error service) nil))
        (:error (setf (notebook-service-error service) (second result)))))
    (%sync-model service)))

(defun %queue-save (service value)
  (handler-case
      (let* ((newline (position #\Newline value))
             (revision (and newline (<= 1 newline 15) (parse-integer value :end newline)))
             (text (and revision (subseq value (1+ newline)))))
        (unless (and revision (plusp revision) text (<= (length text) +maximum-bytes+)
                     (notebook-service-loaded service))
          (error "Invalid notebook save request."))
        (setf (notebook-service-error service) nil)
        (%sync-model service)
        (sb-thread:with-mutex ((notebook-service-lock service))
          (unless (notebook-service-stopped service)
            ;; Coalesce the latest whole document without holding a lock during I/O.
            (let ((wake (null (notebook-service-pending service))))
              (setf (notebook-service-pending service) (cons revision text))
              (when wake (sb-thread:signal-semaphore (notebook-service-wake service)))))))
    (error (cause) (setf (notebook-service-error service) (princ-to-string cause)) (%sync-model service))))

(defun %stop (service)
  (when (notebook-service-source service)
    (ataxia.runtime:remove-event-loop-source (notebook-service-source service))
    (setf (notebook-service-source service) nil))
  (sb-thread:with-mutex ((notebook-service-lock service))
    (setf (notebook-service-stopped service) t)
    (%close-fd (notebook-service-fd service))
    (setf (notebook-service-fd service) nil)
    (sb-thread:signal-semaphore (notebook-service-wake service))))

(defmethod ataxia.world:service-quiescing ((service notebook-service) world reason)
  (declare (ignore reason)) (%stop service) (ataxia.world:detach-world-service world :commonplace))
(defun close-notebook (world)
  "Request a close through the page; pending edits are saved before hiding."
  (let* ((service (ataxia.world:world-service world :commonplace))
         (widget (and service (notebook-service-widget service))))
    (when widget
      (ataxia.world.web:evaluate-web-javascript (ataxia.world:ui-application-component widget)
        "document.getElementById('close-notebook').click()"))))

(defun %bind-notebook-window (service)
  (let* ((app (notebook-service-widget service))
         (component (ataxia.world:ui-application-component app))
         (world (notebook-service-world service)))
    (ataxia.world:ui-set-callback component "notebook-ready"
      (lambda (component value) (declare (ignore component value))
        (setf (notebook-service-ready service) t) (%sync-model service)))
    (ataxia.world:ui-set-callback component "notebook-save"
      (lambda (component value) (declare (ignore component)) (%queue-save service value)))
    (ataxia.world:ui-set-callback component "notebook-hide"
      (lambda (component value) (declare (ignore component value)) (ataxia.world:hide-ui-application app)))
    (ataxia.world:ui-set-callback component "notebook-move"
      (lambda (component value) (declare (ignore value))
        (let ((seat (ataxia.world.web.ui:input-seat component)))
          (when seat
            (ataxia.kernel:world-client-request world app
              (make-instance 'ataxia.kernel:move-client-request :seat seat))))))))

(defun open-notebook (world &key (path (default-notebook-path)) output)
  "Open Commonplace as a regular window in a World supporting :UI-WINDOWS. Call on its owner thread.
PATH is a local JSON file; all reads/writes run on a sleeping storage worker."
  (let* ((path (merge-pathnames path))
         (service (ataxia.world:world-service world :commonplace)))
    (declare (ignore output))
    (when (and service (not (equal path (notebook-service-path service))))
      (error "This World already has a different notebook open."))
    (unless service
      (setf service (make-notebook-service :world world :path path))
      (handler-case
          (progn
            (setf (notebook-service-fd service) (cffi:foreign-funcall "eventfd" :uint 0 :int #x80800 :int))
            (when (minusp (notebook-service-fd service))
              (setf (notebook-service-fd service) nil) (error "Cannot create notebook event descriptor."))
            (setf (notebook-service-source service)
                  (ataxia.runtime:add-event-loop-fd
                   (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world)) (notebook-service-fd service)
                   ataxia.runtime:+event-readable+
                   (lambda (source fd mask)
                     (declare (ignore source mask))
                     (cffi:with-foreign-object (value :uint64)
                       (cffi:foreign-funcall "read" :int fd :pointer value :size 8 :long))
                     (%consume-results service) 0)))
            (setf (notebook-service-widget service)
                  (ataxia.world:make-ui-application world
                    (ataxia.world.web.ui:make-ui-component :world world
                      :source-path (asdf:system-relative-pathname "ataxia-web" "src/world/web/notes/index.html")
                      :width 1160d0 :height 800d0)
                    :title "Commonplace" :app-id "ataxia.commonplace"
                    :close (lambda (app) (declare (ignore app)) (close-notebook world))))
            (%bind-notebook-window service)
            (ataxia.world:attach-world-service world :commonplace service)
            (setf (notebook-service-thread service)
                  (sb-thread:make-thread (lambda () (%run-storage service)) :name "Commonplace storage")))
        (error (cause)
          (%stop service)
          (when (notebook-service-widget service)
            (ataxia.world:remove-ui-application (notebook-service-widget service)))
          (ataxia.world:detach-world-service world :commonplace)
          (error cause))))
    (ataxia.world:show-ui-application (notebook-service-widget service))))
