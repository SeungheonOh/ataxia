;;;; Smooth, retargetable backlight fades on the power worker, never the UI thread.
(in-package #:ataxia.world.shell)

(defvar *brightness-retarget* nil
  "Worker-local function returning the latest percentage and a cancellation flag.")
(defparameter *brightness-fade-seconds* 0.25d0)
(defparameter *brightness-frame-seconds* (/ 1d0 60))
(defun %brightness-time () (/ (get-internal-real-time) (float internal-time-units-per-second 1d0)))
(defun %brightness-raw (maximum percent)
  (max 1 (round (* maximum (/ (max 1 (min 100 percent)) 100)))))
(defun %fade-brightness (initial maximum target write-value
                         &key (retarget *brightness-retarget*)
                              (clock #'%brightness-time) (wait #'sleep))
  "Fade from INITIAL; retarget from the last written value without a discontinuity."
  (let* ((current initial) (origin initial) (start (funcall clock))
         (destination (%brightness-raw maximum target)))
    (loop
      (when retarget
        (multiple-value-bind (latest cancelled) (funcall retarget target)
          (when cancelled (return current))
          (unless (= latest target)
            (setf target latest origin current start (funcall clock)
                  destination (%brightness-raw maximum latest)))))
      (let* ((progress (min 1d0 (max 0d0 (/ (- (funcall clock) start) *brightness-fade-seconds*))))
             ;; Smoothstep has zero velocity at both ends; rounded raw device units
             ;; give small steps even when the panel percentage remains unchanged.
             (eased (* progress progress (- 3d0 (* 2d0 progress))))
             (next (round (+ origin (* (- destination origin) eased)))))
        (unless (= next current) (funcall write-value next) (setf current next))
        (when (or (= origin destination) (= progress 1d0)) (return current)))
      (funcall wait *brightness-frame-seconds*))))

(cffi:define-foreign-library brightness-systemd (:unix "libsystemd.so.0"))
(defvar *brightness-library-lock* (sb-thread:make-mutex :name "Brightness D-Bus library"))
(defun %brightness-bus-check (status operation)
  (when (minusp status)
    (error "~A: ~A" operation (cffi:foreign-funcall "strerror" :int (- status) :string)))
  status)
(defun %call-with-brightness-writer (device function)
  "Use a private, bounded D-Bus connection for one fade, with no per-frame process."
  (sb-thread:with-mutex (*brightness-library-lock*)
    (cffi:use-foreign-library brightness-systemd))
  (cffi:with-foreign-objects ((bus-pointer :pointer) (session-pointer :pointer)
                            (reply-pointer :pointer) (path-pointer :pointer))
    (setf (cffi:mem-ref bus-pointer :pointer) (cffi:null-pointer)
          (cffi:mem-ref session-pointer :pointer) (cffi:null-pointer)
          (cffi:mem-ref reply-pointer :pointer) (cffi:null-pointer))
    (unwind-protect
         (progn
           (%brightness-bus-check
            (cffi:foreign-funcall "sd_bus_open_system" :pointer bus-pointer :int) "Connect to logind")
           (let ((bus (cffi:mem-ref bus-pointer :pointer)))
             (%brightness-bus-check
              (cffi:foreign-funcall "sd_bus_set_method_call_timeout" :pointer bus :uint64 1000000 :int)
              "Set brightness timeout")
             ;; Explicitly resolve this user's display session. /session/auto is
             ;; unavailable when the compositor was started as a system service.
             (%brightness-bus-check
              (cffi:foreign-funcall "sd_uid_get_display"
                                    :uint (cffi:foreign-funcall "getuid" :uint)
                                    :pointer session-pointer :int) "Find the display session")
             (%brightness-bus-check
              (cffi:foreign-funcall "sd_bus_call_method"
                :pointer bus :string "org.freedesktop.login1" :string "/org/freedesktop/login1"
                :string "org.freedesktop.login1.Manager" :string "GetSession"
                :pointer (cffi:null-pointer) :pointer reply-pointer :string "s"
                :pointer (cffi:mem-ref session-pointer :pointer) :int)
              "Resolve the display session")
             (%brightness-bus-check
              (cffi:foreign-funcall "sd_bus_message_read"
                :pointer (cffi:mem-ref reply-pointer :pointer) :string "o" :pointer path-pointer :int)
              "Read the display session")
             (let ((path (cffi:foreign-string-to-lisp (cffi:mem-ref path-pointer :pointer))))
               (funcall function
                        (lambda (raw)
                          (%brightness-bus-check
                           (cffi:foreign-funcall "sd_bus_call_method"
                             :pointer bus :string "org.freedesktop.login1" :string path
                             :string "org.freedesktop.login1.Session" :string "SetBrightness"
                             :pointer (cffi:null-pointer) :pointer (cffi:null-pointer) :string "ssu"
                             :string "backlight" :string device :uint raw :int)
                           "Set display brightness"))))))
      (cffi:foreign-funcall "sd_bus_message_unref" :pointer (cffi:mem-ref reply-pointer :pointer) :pointer)
      (cffi:foreign-funcall "free" :pointer (cffi:mem-ref session-pointer :pointer) :void)
      (cffi:foreign-funcall "sd_bus_unref" :pointer (cffi:mem-ref bus-pointer :pointer) :pointer))))
