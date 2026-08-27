;;;; SLY control-plane package.

(defpackage #:ataxia.sly-control
  (:use #:cl)
  (:export
   #:sly-control
   #:start-sly-control
   #:stop-sly-control
   #:current-sly-control
   #:current-kernel
   #:call-in-kernel-thread
   #:with-kernel-thread
   #:agent-inspect
   #:agent-apply
   #:sly-control-port
   #:sly-control-state))
