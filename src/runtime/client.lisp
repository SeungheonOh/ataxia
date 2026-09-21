;;;; Typed wl_client lifetime. No compositor identity or placement policy.
(in-package #:ataxia.runtime)

(cffi:defcfun ("ataxia_client_wlroots_version" %client-wlroots-version) :string)
(cffi:defcfun ("ataxia_surface_client" %surface-client) :pointer (surface :pointer))
(cffi:defcfun ("ataxia_drag_client" %drag-client) :pointer (drag :pointer))
(cffi:defcfun ("ataxia_client_listener_create" %client-listener-create) :pointer
  (client :pointer) (cookie :uintptr) (callback :pointer))
(cffi:defcfun ("ataxia_client_listener_destroy" %client-listener-destroy) :void (cell :pointer))
(defvar *client-library* nil)
(defun %load-client-library ()
  (unless *client-library*
    (setf *client-library*
          (cffi:load-foreign-library
           (asdf:system-relative-pathname "ataxia-runtime" "build/libataxia-wlr-client.so")))
    (unless (string= (%client-wlroots-version) ataxia.runtime.raw::+expected-wlroots-version+)
      (error "Client helper was built against a different wlroots version."))))

(defun %adopt-client (runtime pointer)
  (let* ((key (%pointer-key pointer)) (table (%runtime-client-table runtime)))
    (or (gethash key table)
        (let ((client (%wrap-pointer 'wl-client pointer runtime)))
          (push (%attach-listener
                 runtime :client-destroy
                 (lambda (data)
                   (declare (ignore data))
                   (unwind-protect
                        (client-destroying (%runtime-sink runtime) client)
                     (remhash key table)
                     (%retire-object-listeners client :immediate-p t)
                     (%invalidate-native-object client)))
                 (lambda (cookie callback) (%client-listener-create pointer cookie callback))
                 #'%client-listener-destroy)
                (%native-listeners client))
          (setf (gethash key table) client)))))

(defun surface-client (surface)
  "The owning Wayland connection, represented by a lifetime-checked wrapper."
  (%assert-runtime-live (%native-runtime surface) :surface-client)
  (%load-client-library)
  (%adopt-client (%native-runtime surface) (%surface-client (%object-pointer surface))))

(defun drag-client (drag)
  (%assert-runtime-live (%native-runtime drag) :drag-client)
  (%load-client-library)
  (%adopt-client (%native-runtime drag) (%drag-client (%object-pointer drag))))
