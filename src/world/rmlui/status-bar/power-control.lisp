;;;; Bounded, asynchronous logind controls. Native UI remains on the owner thread.
(in-package #:ataxia.world.shell)

(defun %display-backlight (&optional (root #P"/sys/class/backlight/"))
  (loop for path in (sort (copy-list (ignore-errors (uiop:subdirectories root)))
                         #'string< :key #'namestring)
        for maximum = (%bar-power-number path "max_brightness")
        for value = (%bar-power-number path "brightness")
        when (and maximum (plusp maximum) value (<= 0 value maximum))
          return (list :name (car (last (pathname-directory path))) :maximum maximum
                       :value value :percent (round (* 100 (/ value maximum))))))

(defun %power-command (arguments &optional
                                  (cgroups (ignore-errors (uiop:read-file-lines #P"/proc/self/cgroup"))))
  ;; A compositor launched as a system service has no login-session credentials.
  ;; Run desktop requests in the same user's manager, where logind can authorize
  ;; the active user. This changes no permissions and preserves inhibitors.
  (if (some (lambda (line) (search "/system.slice/" line)) cgroups)
      (append '("systemd-run" "--user" "--quiet" "--wait" "--collect" "--pipe" "--service-type=exec")
              arguments)
      arguments))

(defun %power-logind (object interface method signature &rest arguments)
  ;; Argument vectors avoid shell interpretation. The timeout also bounds teardown
  ;; when a service disappears. Do not bypass logind's authorization or inhibitors.
  (multiple-value-bind (output errors status)
      (uiop:run-program
       (%power-command
        (append (list "busctl" "--system" "--timeout=5" "--allow-interactive-authorization=no"
                      "call" "org.freedesktop.login1" object interface method)
                (when signature (cons signature arguments))))
       :output :string :error-output :string :ignore-error-status t)
    (unless (eql status 0)
      (error "~A" (short-ui-text (string-trim '(#\Space #\Newline #\Return) errors) 180)))
    (string-trim '(#\Space #\Newline #\Return) output)))

(defun %power-suspend-capability (call)
  (let ((reply (funcall call "/org/freedesktop/login1" "org.freedesktop.login1.Manager"
                        "CanSuspend" nil)))
    (cond ((equal reply "s \"yes\"") :yes) ((equal reply "s \"challenge\"") :challenge)
          ((equal reply "s \"no\"") :no) ((equal reply "s \"na\"") :na)
          (t (error "Could not read the system's sleep capability.")))))

(defun %system-power-action (kind value &key (root #P"/sys/class/backlight/")
                                           (call #'%power-logind call-supplied-p))
  (ecase kind
    (:refresh
     (append (list :backlight (%display-backlight root))
             (handler-case (list :suspend-state (%power-suspend-capability call) :suspend-error nil)
               (error (cause) (list :suspend-state :unavailable
                                    :suspend-error (short-ui-text (princ-to-string cause) 180))))))
    (:brightness
     (let ((backlight (%display-backlight root)))
       (unless backlight (error "No controllable display backlight was found."))
       (handler-case
           (progn
             (flet ((fade (writer)
                      (%fade-brightness (getf backlight :value) (getf backlight :maximum) value writer)))
               (if call-supplied-p
                   (fade (lambda (raw)
                           (funcall call "/org/freedesktop/login1/session/auto" "org.freedesktop.login1.Session"
                                    "SetBrightness" "ssu" "backlight" (getf backlight :name) (princ-to-string raw))))
                   (%call-with-brightness-writer (getf backlight :name) #'fade)))
             (list :backlight (%display-backlight root) :brightness-error nil))
         (error (cause)
           (list :backlight (%display-backlight root)
                 :brightness-error (short-ui-text (princ-to-string cause) 180))))))
    (:suspend
     ;; Recheck immediately before sleeping; capability and inhibitors can change.
     (unless (eq :yes (%power-suspend-capability call))
       (error "Sleep is unavailable or requires authorization."))
     (funcall call "/org/freedesktop/login1" "org.freedesktop.login1.Manager" "Suspend" "b" "false")
     (list :suspend-error nil))))

(defstruct power-controller
  (lock (sb-thread:make-mutex :name "Shell power controls"))
  (wake (sb-thread:make-semaphore :count 0))
  (backend #'%system-power-action)
  (state (list :suspend-state :loading))
  queue active stopped thread fd source)

(defun %power-notify (controller)
  ;; Caller holds LOCK, serializing writes against descriptor closure.
  (when (power-controller-fd controller)
    (cffi:with-foreign-object (value :uint64)
      (setf (cffi:mem-ref value :uint64) 1)
      (cffi:foreign-funcall "write" :int (power-controller-fd controller)
                            :pointer value :size 8 :long))))
(defun %power-worker (controller)
  (loop
    (sb-thread:wait-on-semaphore (power-controller-wake controller))
    (loop
      (let ((command
              (sb-thread:with-mutex ((power-controller-lock controller))
                (when (power-controller-stopped controller) (return-from %power-worker nil))
                (let ((command (pop (power-controller-queue controller))))
                  (setf (power-controller-active controller) (car command))
                  command))))
        (unless command (return))
        (let* ((kind (car command))
               (result (handler-case
                           (let ((*brightness-retarget*
                                   (lambda (target) (%power-fade-target controller target))))
                             (funcall (power-controller-backend controller) kind (cdr command)))
                         (error (cause)
                           (list (if (eq kind :brightness) :brightness-error :suspend-error)
                                 (short-ui-text (princ-to-string cause) 180))))))
          (sb-thread:with-mutex ((power-controller-lock controller))
            (when (power-controller-stopped controller) (return-from %power-worker nil))
            (loop for (key value) on result by #'cddr do
              (setf (getf (power-controller-state controller) key) value))
            (setf (power-controller-active controller) nil)
            (%power-notify controller)))))))
(defun %power-fade-target (controller target)
  (sb-thread:with-mutex ((power-controller-lock controller))
    (when (or (power-controller-stopped controller)
              (assoc :suspend (power-controller-queue controller)))
      (return-from %power-fade-target (values target t)))
    (let ((queued (assoc :brightness (power-controller-queue controller))))
      (when queued
        (setf target (cdr queued)
              (power-controller-queue controller) (delete queued (power-controller-queue controller))))
      (values target nil))))
(defun %power-queue (controller kind &optional value)
  (sb-thread:with-mutex ((power-controller-lock controller))
    (when (or (power-controller-stopped controller)
              (and (eq kind :suspend)
                   (or (eq kind (power-controller-active controller))
                       (assoc kind (power-controller-queue controller)))))
      (return-from %power-queue nil))
    (let ((queued (assoc kind (power-controller-queue controller)))
          (idle (and (null (power-controller-queue controller))
                     (null (power-controller-active controller)))))
      (if queued (setf (cdr queued) value)
          (setf (power-controller-queue controller)
                (append (power-controller-queue controller) (list (cons kind value)))))
      (when idle (sb-thread:signal-semaphore (power-controller-wake controller))))
    (when (member kind '(:brightness :suspend))
      (setf (getf (power-controller-state controller)
                  (if (eq kind :brightness) :brightness-error :suspend-error)) nil))
    t))
(defun %power-view (controller)
  (sb-thread:with-mutex ((power-controller-lock controller))
    (append (list :brightness-pending
                  (or (eq :brightness (power-controller-active controller))
                      (not (null (assoc :brightness (power-controller-queue controller)))))
                  :suspend-pending
                  (or (eq :suspend (power-controller-active controller))
                      (not (null (assoc :suspend (power-controller-queue controller))))))
            (copy-tree (power-controller-state controller)))))
(defun %stop-power-controller (controller)
  (when controller
    (sb-thread:with-mutex ((power-controller-lock controller))
      (setf (power-controller-stopped controller) t (power-controller-queue controller) nil)
      (when (power-controller-fd controller)
        (cffi:foreign-funcall "close" :int (power-controller-fd controller) :int)
        (setf (power-controller-fd controller) nil)))
    (when (power-controller-source controller)
      (ataxia.runtime:remove-event-loop-source (power-controller-source controller))
      (setf (power-controller-source controller) nil))
    (sb-thread:signal-semaphore (power-controller-wake controller)))
  nil)
(defun %start-power-controller (world service &optional (backend #'%system-power-action))
  (let* ((controller (make-power-controller :backend backend))
         (kernel (ataxia.kernel:world-kernel world))
         (generation (ataxia.kernel:kernel-world-generation kernel)))
    (handler-case
        (progn
          (setf (power-controller-fd controller)
                ;; Linux EFD_CLOEXEC | EFD_NONBLOCK; no inherited descriptor or idle timer.
                (cffi:foreign-funcall "eventfd" :uint 0 :int #x80800 :int))
          (when (minusp (power-controller-fd controller)) (error "Could not create the power wakeup."))
          (setf (power-controller-source controller)
                (ataxia.runtime:add-event-loop-fd
                 (ataxia.kernel:kernel-runtime kernel) (power-controller-fd controller)
                 ataxia.runtime:+event-readable+
                 (lambda (source fd mask)
                   (declare (ignore source mask))
                   (cffi:with-foreign-object (value :uint64)
                     (cffi:foreign-funcall "read" :int fd :pointer value :size 8 :long))
                   (when (and (eq service (world-service world :shell))
                              (= generation (ataxia.kernel:kernel-world-generation kernel)))
                     (%sync-power-controls world service))
                   0))
                (power-controller-thread controller)
                (sb-thread:make-thread (lambda () (%power-worker controller)) :name "Shell power controls"))
          controller)
      (error (cause) (%stop-power-controller controller) (error cause)))))
