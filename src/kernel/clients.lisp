;;;; Stable Wayland connection identity belongs to the Kernel registry.
(in-package #:ataxia.kernel)

(defun %ensure-wayland-client (kernel runtime-client)
  (or (%find-runtime-object kernel runtime-client)
      (%register-object
       kernel (make-instance 'wayland-client :kernel kernel :id (%allocate-object-id kernel))
       :runtime-object runtime-client)))

(defun application-client-identity (application)
  "Opaque Kernel identity shared by applications from one Wayland connection."
  (or (%application-client-identity application)
      (when (eq :live (object-state application))
        (setf (%application-client-identity application)
              (%ensure-wayland-client
               (object-kernel application)
               (ataxia.runtime:surface-client
                (surface-runtime-object (application-root-surface application))))))))

(defmethod ataxia.runtime:client-destroying ((kernel kernel) client)
  (let ((identity (%find-runtime-object kernel client)))
    (when identity (%retire-object kernel identity :runtime-object client))))
