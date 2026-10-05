;;;; Engine-independent shell policy and system controllers, owned by the World.
(defpackage #:ataxia.world.shell
  (:use #:cl #:ataxia.world)
  (:export #:enable-status-bar #:disable-status-bar #:shell-status-bar #:status-bars
           #:initialize-status-bar-controls #:set-shell-text #:set-shell-style #:shell-cache))
