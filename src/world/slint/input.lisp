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

(defun %delivered (component)
  (%notify-change component)
  (ataxia.kernel:make-interaction-result
   :status :delivered :object component))

(defmethod ataxia.kernel:interactable-pointer-motion
    ((component slint-component) world seat local-x local-y input)
  (declare (ignore world seat input))
  (update-slint-timers)
  (ataxia.world.slint.raw::check-result
   (ataxia.world.slint.raw::%pointer-motion
    (%live-native component) (%single local-x) (%single local-y))
   :pointer-motion)
  (poll-slint-callbacks component)
  (%delivered component))

(defmethod ataxia.kernel:interactable-pointer-button
    ((component slint-component) world seat local-x local-y input)
  (declare (ignore world seat))
  (update-slint-timers)
  (ataxia.world.slint.raw::check-result
   (ataxia.world.slint.raw::%pointer-button
    (%live-native component) (%single local-x) (%single local-y)
    (%button-number (ataxia.kernel:cursor-button-input-code input))
    (eq (ataxia.kernel:cursor-button-input-state input) :pressed))
   :pointer-button)
  (poll-slint-callbacks component)
  (%delivered component))

(defmethod ataxia.kernel:interactable-pointer-axis
    ((component slint-component) world seat local-x local-y input)
  (declare (ignore world seat))
  (update-slint-timers)
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
  (poll-slint-callbacks component)
  (%delivered component))

(defmethod ataxia.kernel:interactable-pointer-leave
    ((component slint-component) world seat)
  (declare (ignore world seat))
  (update-slint-timers)
  (ataxia.world.slint.raw::check-result
   (ataxia.world.slint.raw::%pointer-exit (%live-native component))
   :pointer-exit)
  (poll-slint-callbacks component)
  (%delivered component))

(defun %forward-slint-key (component keycode pressed repeated)
  (update-slint-timers)
  (ataxia.world.slint.raw::check-result
   (ataxia.world.slint.raw::%key (%live-native component) keycode pressed (not (null repeated))) :key))

(defun %apply-slint-modifiers (component state)
  (apply #'ataxia.world.slint.raw::%modifiers (%live-native component) (or state '(0 0 0 0))))

(defmethod ataxia.kernel:interactable-key-event
    ((component slint-component) world seat input)
  (etypecase input
    (ataxia.kernel:key-input
     (let* ((keycode (ataxia.kernel:key-input-keycode input))
            (pressed-p (eq (ataxia.kernel:key-input-state input) :pressed))
            (repeated-p (and pressed-p (gethash keycode (%component-pressed-keys component))))
            (modifiers (ataxia.kernel:key-input-modifiers input))
            (symbols (ataxia.kernel:key-input-keysyms input))
            (paste (and pressed-p
                        (or (and (member :control modifiers) (find "v" symbols :test #'string-equal))
                            (and (member :shift modifiers) (find "Insert" symbols :test #'equal)))))
            (focus (gethash :clipboard-focus (%component-pressed-keys component)))
            (target (ataxia.world:world-seat-focus world seat))
            (modifier-state (copy-list (gethash :clipboard-modifiers (%component-pressed-keys component))))
            (revision (ataxia.world.slint.raw::%clipboard-revision)))
       (if pressed-p (setf (gethash keycode (%component-pressed-keys component)) t)
           (remhash keycode (%component-pressed-keys component)))
       (unless (and paste
                    (ataxia.world:request-clipboard-text world seat
                      (lambda (text)
                        (when (and text (not (%component-destroyed-p component))
                                   (eq focus (gethash :clipboard-focus (%component-pressed-keys component)))
                                   (eq target (ataxia.world:world-seat-focus world seat)))
                          (ataxia.world.slint.raw::%clipboard-set text)
                          (let* ((keys (%component-pressed-keys component))
                                 (current (gethash :clipboard-modifiers keys))
                                 (added (loop for (name code alternate) in '((:control 29 97) (:shift 42 54))
                                              when (and (member name modifiers)
                                                        (not (or (gethash code keys) (gethash alternate keys))))
                                                collect code)))
                            (unwind-protect
                                 (progn (%apply-slint-modifiers component modifier-state)
                                        (dolist (code added) (%forward-slint-key component code t nil))
                                        (%forward-slint-key component keycode t nil)
                                        (%forward-slint-key component keycode nil nil))
                              (dolist (code added) (%forward-slint-key component code nil nil))
                              (%apply-slint-modifiers component current)))
                          (poll-slint-callbacks component) (%notify-change component)))))
         (%forward-slint-key component keycode pressed-p repeated-p))
       (when (/= revision (ataxia.world.slint.raw::%clipboard-revision))
         (ataxia.world:set-clipboard-text world seat (ataxia.world.slint.raw::%clipboard-text)))))
    (ataxia.kernel:modifiers-input
     (setf (gethash :clipboard-modifiers (%component-pressed-keys component))
           (list (ataxia.kernel:modifiers-input-depressed input) (ataxia.kernel:modifiers-input-latched input)
                 (ataxia.kernel:modifiers-input-locked input) (ataxia.kernel:modifiers-input-group input)))
     (ataxia.world.slint.raw::check-result
      (ataxia.world.slint.raw::%modifiers
       (%live-native component)
       (ataxia.kernel:modifiers-input-depressed input)
       (ataxia.kernel:modifiers-input-latched input)
       (ataxia.kernel:modifiers-input-locked input)
       (ataxia.kernel:modifiers-input-group input))
      :modifiers)))
  (poll-slint-callbacks component)
  (%delivered component))

(defmethod ataxia.kernel:interactable-focus
    ((component slint-component) world seat focus-kind)
  (declare (ignore world seat))
  (update-slint-timers)
  (unless (eq focus-kind :keyboard)
    (clrhash (%component-pressed-keys component)))
  (setf (gethash :clipboard-focus (%component-pressed-keys component)) (list focus-kind))
  (ataxia.world.slint.raw::check-result
   (ataxia.world.slint.raw::%focus
    (%live-native component) (eq focus-kind :keyboard))
   :focus)
  (poll-slint-callbacks component)
  (%delivered component))

(defmethod ataxia.kernel:request-object-configuration
    ((component slint-component) world configuration)
  (declare (ignore world configuration))
  component)

(defmethod ataxia.kernel:request-object-state
    ((component slint-component) world state value)
  (declare (ignore world state value))
  component)
