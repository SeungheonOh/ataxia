;;;; Optional World-owned native bridge. No definitions are installed in Runtime.
(in-package #:ataxia.computer-use)
(cffi:defcfun ("ataxia_cua_surface_pid" %cua-surface-pid) :int32 (surface :pointer))
(cffi:defcfun ("ataxia_cua_set_clipboard" %cua-set-clipboard) :boolean
  (seat :pointer) (content :pointer) (length :size) (format :string))
(defvar *cua-library* nil)
(defun ensure-cua-library ()
  (or *cua-library*
      (setf *cua-library*
            (cffi:load-foreign-library
             (or (uiop:getenv "ATAXIA_CUA_NATIVE")
                 (asdf:system-relative-pathname "ataxia-computer-use" "build/libataxia-cua.so"))))))
(defun surface-client-pid (surface)
  (check-type surface ataxia.runtime:wlr-surface)
  (ataxia.runtime::%assert-runtime-live (ataxia.runtime::%native-runtime surface) :surface-client-pid)
  (ensure-cua-library)
  (%cua-surface-pid (ataxia.runtime::%object-pointer surface)))
(defun seat-set-clipboard-content (seat content format)
  (check-type seat ataxia.runtime:wlr-seat)
  (ataxia.runtime::%assert-runtime-live (ataxia.runtime::%native-runtime seat) :seat-set-clipboard-content)
  (ensure-cua-library)
  (let ((bytes (babel:string-to-octets content :encoding :utf-8)))
    (cffi:with-pointer-to-vector-data (data bytes)
      (unless (%cua-set-clipboard (ataxia.runtime::%object-pointer seat) data (length bytes) format)
        (error "Could not own the agent seat clipboard.")))))

(cffi:defcfun ("ataxia_seat_surface_input_capabilities" %seat-surface-input-capabilities) :uint32
  (seat :pointer) (surface :pointer))
(defun seat-surface-input-capabilities (seat surface)
  "Query this client's bound input resources without changing focus."
  (check-type seat ataxia.runtime:wlr-seat)
  (check-type surface ataxia.runtime:wlr-surface)
  (let ((runtime (ataxia.runtime::%native-runtime seat)))
    (ataxia.runtime::%assert-runtime-live runtime :seat-surface-input-capabilities)
    (ataxia.runtime::%assert-object-runtime runtime surface :seat-surface-input-capabilities)
    (ensure-cua-library)
    (%seat-surface-input-capabilities (ataxia.runtime::%object-pointer seat)
                                      (ataxia.runtime::%object-pointer surface))))

(defun application-seat-input-capabilities (application seat)
  "Input resources bound by this application's client on SEAT; no focus changes."
  (check-type application ataxia.kernel:wayland-application)
  (check-type seat ataxia.kernel:logical-seat)
  (let ((mask (seat-surface-input-capabilities
               (ataxia.kernel:seat-runtime-object seat)
               (ataxia.kernel:surface-runtime-object (ataxia.kernel:application-root-surface application)))))
    (loop for (capability bit) in '((:pointer 1) (:keyboard 2) (:touch 4))
          when (logtest bit mask) collect capability)))
