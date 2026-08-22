;;;; Input forwarding for World-owned Slint components.
;;;;
;;;; Object-local coordinates and copied Kernel input values are converted
;;;; synchronously to Slint window events. No Wayland focus is mutated here.

(in-package #:ataxia.world.slint)

(defun %single (value)
  (coerce value 'single-float))

(defun %button-number (code)
  (case code
    (272 1)
    (273 2)
    (274 3)
    (275 4)
    (276 5)
    (otherwise 0)))

(defmethod ataxia.kernel:interactable-pointer-motion
    ((component slint-component) world seat local-x local-y input)
  (declare (ignore world seat input))
  (ataxia.world.slint.raw::check-result
   (ataxia.world.slint.raw::%pointer-motion
    (%live-native component) (%single local-x) (%single local-y))
   :pointer-motion)
  (%notify-change component))

(defmethod ataxia.kernel:interactable-pointer-button
    ((component slint-component) world seat local-x local-y input)
  (declare (ignore world seat))
  (ataxia.world.slint.raw::check-result
   (ataxia.world.slint.raw::%pointer-button
    (%live-native component) (%single local-x) (%single local-y)
    (%button-number (ataxia.kernel:cursor-button-input-code input))
    (eq (ataxia.kernel:cursor-button-input-state input) :pressed))
   :pointer-button)
  (%notify-change component))

(defmethod ataxia.kernel:interactable-pointer-axis
    ((component slint-component) world seat local-x local-y input)
  (declare (ignore world seat))
  (let* ((delta
           (* (if (eq (ataxia.kernel:cursor-axis-input-relative-direction input)
                      :inverted)
                  -1d0 1d0)
              (ataxia.kernel:cursor-axis-input-delta input)))
         (horizontal-p
           (eq (ataxia.kernel:cursor-axis-input-orientation input) :horizontal)))
    (ataxia.world.slint.raw::check-result
     (ataxia.world.slint.raw::%pointer-scroll
      (%live-native component) (%single local-x) (%single local-y)
      (%single (if horizontal-p delta 0d0))
      (%single (if horizontal-p 0d0 delta)))
     :pointer-scroll))
  (%notify-change component))

(defmethod ataxia.kernel:interactable-pointer-leave
    ((component slint-component) world seat)
  (declare (ignore world seat))
  (ataxia.world.slint.raw::check-result
   (ataxia.world.slint.raw::%pointer-exit (%live-native component))
   :pointer-exit)
  (%notify-change component))

(defmethod ataxia.kernel:interactable-key-event
    ((component slint-component) world seat input)
  (declare (ignore world seat))
  (etypecase input
    (ataxia.kernel:key-input
     (let* ((keycode (ataxia.kernel:key-input-keycode input))
            (pressed-p (eq (ataxia.kernel:key-input-state input) :pressed))
            (repeated-p (and pressed-p (gethash keycode (%component-pressed-keys component)))))
       (if pressed-p
           (setf (gethash keycode (%component-pressed-keys component)) t)
           (remhash keycode (%component-pressed-keys component)))
       (ataxia.world.slint.raw::check-result
        (ataxia.world.slint.raw::%key
         (%live-native component) keycode pressed-p (not (null repeated-p)))
        :key)))
    (ataxia.kernel:modifiers-input
     (ataxia.world.slint.raw::check-result
      (ataxia.world.slint.raw::%modifiers
       (%live-native component)
       (ataxia.kernel:modifiers-input-depressed input)
       (ataxia.kernel:modifiers-input-latched input)
       (ataxia.kernel:modifiers-input-locked input)
       (ataxia.kernel:modifiers-input-group input))
      :modifiers)))
  (%notify-change component))

(defmethod ataxia.kernel:interactable-focus
    ((component slint-component) world seat focus-kind)
  (declare (ignore world seat))
  (unless (eq focus-kind :keyboard)
    (clrhash (%component-pressed-keys component)))
  (ataxia.world.slint.raw::check-result
   (ataxia.world.slint.raw::%focus
    (%live-native component) (eq focus-kind :keyboard))
   :focus)
  (%notify-change component))

(defmethod ataxia.kernel:request-object-configuration
    ((component slint-component) world configuration)
  (declare (ignore world configuration))
  component)

(defmethod ataxia.kernel:request-object-state
    ((component slint-component) world state value)
  (declare (ignore world state value))
  component)
