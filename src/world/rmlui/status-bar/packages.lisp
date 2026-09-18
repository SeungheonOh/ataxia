;;;; Portable RmlUi shell chrome. Navigation and launch policy live in the World.
(defpackage #:ataxia.world.shell
  (:use #:cl #:ataxia.world)
  (:import-from #:ataxia.world.rmlui
                #:rmlui-widget #:widget-cache #:cache-widget-value
                #:set-widget-text #:set-widget-style #:short-ui-text)
  (:export #:enable-rmlui-status-bar #:disable-rmlui-status-bar
           #:rmlui-status-bar #:status-bars #:initialize-status-bar-controls))
