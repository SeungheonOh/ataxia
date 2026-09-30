;;;; Portable computer-use service and its small public entry points.
(defpackage #:ataxia.computer-use
  (:use #:cl #:ataxia.world)
  (:import-from #:ataxia.world.web.ui
                #:document-widget #:set-widget-text #:set-widget-style #:short-ui-text)
  (:export #:enable #:disable #:request-json
           #:activate-session
           #:change-session-view
           #:close-session
           #:pause-session
           #:emergency-stop
           #:session-state-changed
           #:decode-request
           #:request-on-owner
           #:bounded-string
           #:bounded-number
           #:random-token
           #:+batch-action-fields+
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
