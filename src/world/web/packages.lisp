(defpackage #:ataxia.world.web
  (:use #:cl)
  (:export #:web-component #:web-widget #:make-web-component #:make-web-widget
           #:destroy-web-component #:resize-web-component #:set-web-visible
           #:evaluate-web-javascript #:navigate-web-component #:post-web-message
           #:web-component-stats #:web-component-error #:web-component-width
           #:web-component-height #:web-component-scale #:web-engine-pid))
(defpackage #:ataxia.world.web.raw (:use #:cl #:cffi))
