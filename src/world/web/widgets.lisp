(in-package #:ataxia.world.web)
(defclass web-widget (ataxia.world:agent-widget) ())
(defun %widget-visible-p (widget world)
  (and (ataxia.world:overlay-visible-p widget) (plusp (ataxia.world:overlay-opacity widget))
       (member (ataxia.world:overlay-output widget) (ataxia.world:world-outputs world))
       (multiple-value-bind (width height) (ataxia.world:output-logical-size (ataxia.world:overlay-output widget))
         (and (< (ataxia.world:overlay-x widget) width) (< (ataxia.world:overlay-y widget) height)
              (plusp (+ (ataxia.world:overlay-x widget) (ataxia.world:overlay-width widget)))
              (plusp (+ (ataxia.world:overlay-y widget) (ataxia.world:overlay-height widget)))))))
(defun %sync-visibility (engine)
  (unless (or (%engine-stopped engine) (not (typep (%engine-world engine) 'ataxia.world:ui-host)))
    (let ((world (%engine-world engine)))
      (dolist (widget (ataxia.world:world-overlays world))
        (when (typep (ataxia.world:overlay-component widget) 'web-component)
          (set-web-visible (ataxia.world:overlay-component widget) (%widget-visible-p widget world)))))))
(defmethod ataxia.world:overlay-visibility-changed :after ((widget ataxia.world:ui-overlay) visible)
  (when (typep (ataxia.world:overlay-component widget) 'web-component)
    (set-web-visible (ataxia.world:overlay-component widget) visible)))
(defmethod ataxia.world:service-output-removing ((engine web-engine) world output)
  (dolist (widget (when (typep world 'ataxia.world:ui-host) (ataxia.world:world-overlays world)))
    (when (and (typep (ataxia.world:overlay-component widget) 'web-component) (eq output (ataxia.world:overlay-output widget)))
      (set-web-visible (ataxia.world:overlay-component widget) nil))))
(defun make-web-widget (world &key source source-path url asset-root
                                  (x 24d0) (y 24d0) (width 640d0) (height 360d0)
                                  output (layer 1100) (visible-p t) (opacity 1d0) callbacks)
  "Use source HTML, a local SOURCE-PATH, a built ASSET-ROOT, or an HTTP(S) dev-server URL.
The result uses the shared agent-widget lifecycle and drawable/interactable contracts."
  (let* ((input-source source) (input-path source-path)
         (widget
          (ataxia.world:create-agent-widget
           'web-widget world (or source "")
           :component-factory (lambda (&key source source-path component-name width height scale)
                                (declare (ignore source source-path component-name))
                                (make-web-component :world world :source input-source :source-path input-path
                                                    :url url :asset-root asset-root :width width :height height :scale scale))
           :source-path source-path :x x :y y :width width :height height :output output
           :layer layer :visible-p visible-p :opacity opacity :callbacks callbacks)))
    (%sync-visibility (%engine (ataxia.world:overlay-component widget))) widget))
