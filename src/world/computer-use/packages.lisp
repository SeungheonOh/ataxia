;;;; Portable computer-use service and its small public entry points.
(defpackage #:ataxia.computer-use
  (:use #:cl #:ataxia.world)
  (:import-from #:ataxia.world.web.ui
                #:document-widget #:set-widget-text #:set-widget-style)
  (:export #:enable #:disable
           #:activate-session
           #:change-session-view
           #:close-session
           #:pause-session
           #:emergency-stop
           #:session-state-changed
           #:request-on-owner
           #:bounded-string
           #:bounded-number
           #:random-token
           #:connect-session
           #:finish-request
           #:computer-session
           #:computer-session-world
           #:computer-session-token
           #:computer-session-sequence
           #:computer-session-state
           #:computer-session-message
           #:computer-session-view
           #:computer-view-window))
