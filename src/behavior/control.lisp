;;;; Behavior-owned control commands.
;;;;
;;;; Core authenticates and transports requests. Concrete policies decode and
;;;; execute commands whose coordinates, cameras, or animation bindings they own.

(in-package #:ataxia.compositor)

(defun make-behavior-control-action
    (principal capability command payload)
  (make-instance
   'behavior-control-action :principal principal :capability capability
   :command command :payload payload))

(defun decode-behavior-animation-binding (specification)
  (typecase specification
    (keyword
     (ecase specification
       (:opacity (values 'opacity 'opacity))
       (:scale (values 'scale 'scale))
       (:offset-x (values 'offset-x 'offset-x))
       (:offset-y (values 'offset-y 'offset-y))))
    (cons
     (ecase (first specification)
       (:uniform
        (let ((name (second specification)))
          (values (make-instance 'shader-uniform-binding :name name)
                  (list :shader-uniform name))))
       (:effect
        (let ((name (second specification)))
          (values (make-instance 'effect-parameter-binding :name name)
                  (list :effect-parameter name))))))
    (t
     (error 'control-request-rejected
            :action :decode :reason :invalid-animation-binding))))

(defun decode-behavior-animation-definition (specification)
  (let ((duration (required-command-value specification :duration))
        (tracks (required-command-value specification :tracks)))
    (unless (and (realp duration) (not (minusp duration)) (listp tracks))
      (error 'control-request-rejected
             :action :decode :reason :invalid-animation-definition))
    (make-instance
     'animation-definition
     :name (getf specification :name)
     :duration (coerce duration 'double-float)
     :tracks
     (mapcar
      (lambda (track)
        (let ((from (required-command-value track :from))
              (to (required-command-value track :to))
              (easing (getf track :easing :ease-out-cubic)))
          (unless (and (realp from) (realp to))
            (error 'control-request-rejected
                   :action :decode :reason :invalid-animation-values))
          (multiple-value-bind (binding conflict-key)
              (decode-behavior-animation-binding
               (required-command-value track :property))
            (make-instance
             'animation-track :binding binding :conflict-key conflict-key
             :from (coerce from 'double-float)
             :to (coerce to 'double-float)
             :interpolator
             (ecase easing
               (:linear #'linear-interpolation)
               (:ease-out-cubic #'ease-out-cubic))))))
      tracks))))

(defun behavior-transition-class (name)
  (ecase name
    (:visibility 'visibility-transition)
    (:placement 'placement-transition)
    (:interaction 'interaction-transition)
    (:content 'content-transition)))

(defun decode-planar-control-placement (specification)
  (make-instance
   'planar-placement
   :x (coerce (required-command-value specification :x) 'double-float)
   :y (coerce (required-command-value specification :y) 'double-float)
   :width (coerce (required-command-value specification :width) 'double-float)
   :height (coerce (required-command-value specification :height) 'double-float)
   :z (coerce (getf specification :z 0d0) 'double-float)))

(defun decode-spherical-control-placement (specification)
  (make-instance
   'spherical-placement
   :longitude
   (coerce (required-command-value specification :longitude) 'double-float)
   :latitude
   (coerce (required-command-value specification :latitude) 'double-float)
   :angular-width
   (coerce (required-command-value specification :angular-width) 'double-float)
   :angular-height
   (coerce (required-command-value specification :angular-height) 'double-float)
   :depth (coerce (getf specification :depth 0d0) 'double-float)))

(defun decode-policy-control-action
    (control principal specification placement-decoder)
  (let ((kind (first specification))
        (properties (rest specification)))
    (flet ((output ()
             (control-output-by-name
              control (required-command-value properties :output)))
           (view ()
             (control-view-by-id
              control (required-command-value properties :view))))
      (case kind
        (:pan
         (make-behavior-control-action
          principal :viewport :pan
          (list :output (output)
                :delta-x (required-command-value properties :delta-x)
                :delta-y (required-command-value properties :delta-y))))
        (:zoom
         (make-behavior-control-action
          principal :viewport :zoom
          (list :output (output)
                :factor (required-command-value properties :factor)
                :anchor-x (required-command-value properties :anchor-x)
                :anchor-y (required-command-value properties :anchor-y))))
        (:place
         (make-behavior-control-action
          principal :move :place
          (list :view (view)
                :placement
                (funcall
                 placement-decoder
                 (required-command-value properties :placement)))))
        (:set-animation
         (make-behavior-control-action
          principal :animation :set-animation
          (list
           :view (view)
           :descriptor-class
           (behavior-transition-class
            (required-command-value properties :transition))
           :definition
           (decode-behavior-animation-definition
            (required-command-value properties :definition)))))
        (otherwise
         (error 'control-request-rejected
                :action :decode :reason (list :unsupported-behavior-command
                                              kind)))))))

(defmethod behavior-decode-control-action
    ((policy planar-behavior-policy) control principal specification)
  (declare (ignore policy))
  (decode-policy-control-action
   control principal specification #'decode-planar-control-placement))

(defmethod behavior-decode-control-action
    ((policy spherical-behavior-policy) control principal specification)
  (declare (ignore policy))
  (decode-policy-control-action
   control principal specification #'decode-spherical-control-placement))

(defun validate-behavior-control-output (control action output)
  (let ((compositor (component-compositor control)))
    (unless (eq output
                (find-compositor-output
                 (compositor-outputs compositor) (output-native output)))
      (error 'control-request-rejected
             :action action :reason :foreign-output)))
  output)

(defun execute-policy-control-action
    (policy control action pan-function zoom-function)
  (let* ((command (behavior-control-action-command action))
         (payload (behavior-control-action-payload action))
         (compositor (component-compositor control)))
    (ecase command
      (:pan
       (let ((output
               (validate-behavior-control-output
                control action (getf payload :output))))
         (funcall pan-function policy output
                  (getf payload :delta-x) (getf payload :delta-y))
         (schedule-presentation (compositor-presentation compositor) output)
         (output-behavior-state output)))
      (:zoom
       (let ((output
               (validate-behavior-control-output
                control action (getf payload :output))))
         (funcall zoom-function policy output
                  (getf payload :factor)
                  (getf payload :anchor-x) (getf payload :anchor-y))
         (schedule-presentation (compositor-presentation compositor) output)
         (output-behavior-state output)))
      (:place
       (let* ((view (getf payload :view))
              (placement (getf payload :placement))
              (old-state
                (copy-behavior-view-state
                 policy (view-behavior-state view)))
              (descriptor
                (make-instance
                 'placement-transition :subject view
                 :old-value old-state :new-value placement)))
         (behavior-update-placement
          policy view placement
          (make-instance
           'operation-context :subject view :operation descriptor
           :old-state old-state :new-state placement :cause :agent
           :provenance
           (make-instance
            'provenance :kind :control
            :identity
            (control-principal-identity
             (control-action-principal action)))
           :phase :apply))
         (schedule-presentation-subject
          (compositor-presentation compositor) view)
         placement))
      (:set-animation
       (behavior-set-view-animation-definition
        policy (getf payload :view) (getf payload :descriptor-class)
        (getf payload :definition))))))

(defmethod behavior-execute-control-action
    ((policy planar-behavior-policy) control action)
  (execute-policy-control-action
   policy control action
   (lambda (policy output delta-x delta-y)
     (declare (ignore policy))
     (pan-planar-viewport
      (output-behavior-state output) delta-x delta-y))
   (lambda (policy output factor anchor-x anchor-y)
     (declare (ignore policy))
     (zoom-planar-viewport
      (output-behavior-state output) factor anchor-x anchor-y))))

(defmethod behavior-execute-control-action
    ((policy spherical-behavior-policy) control action)
  (execute-policy-control-action
   policy control action #'pan-spherical-camera #'zoom-spherical-camera))
