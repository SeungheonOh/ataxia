;;;; Optional assistant service. All desktop policy is supplied by ataxia.world.
(defpackage #:ataxia.assistant
  (:use #:cl #:ataxia.world)
  (:local-nicknames (#:cu #:ataxia.computer-use))
  (:import-from #:ataxia.world.rmlui
                #:rmlui-widget #:widget-cache #:cache-widget-value
                #:set-widget-text #:set-widget-style #:short-ui-text)
  (:import-from #:ataxia.world.shell
                #:rmlui-status-bar #:status-bars #:initialize-status-bar-controls)
  (:export #:enable #:disable #:open-panel #:submit #:pause #:stop))
