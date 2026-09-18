;;;; Input forwarding for World-owned RmlUi components.
;;;;
;;;; Object-local coordinates and copied Kernel input values are converted
;;;; synchronously to RmlUi window events. No Wayland focus is mutated here.

(in-package #:ataxia.world.rmlui)

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
    ((component rmlui-component) world seat local-x local-y input)
  (declare (ignore world seat input))
  (ataxia.world.rmlui.raw::check-result
   (ataxia.world.rmlui.raw::%pointer-motion
    (%live-native component) (%single local-x) (%single local-y))
   :pointer-motion)
  (poll-rmlui-callbacks component)
  (%delivered component))

(defmethod ataxia.kernel:interactable-pointer-button
    ((component rmlui-component) world seat local-x local-y input)
  (declare (ignore world seat))
  (ataxia.world.rmlui.raw::check-result
   (ataxia.world.rmlui.raw::%pointer-button
    (%live-native component) (%single local-x) (%single local-y)
    (%button-number (ataxia.kernel:cursor-button-input-code input))
    (eq (ataxia.kernel:cursor-button-input-state input) :pressed))
   :pointer-button)
  (poll-rmlui-callbacks component)
  (%delivered component))

(defmethod ataxia.kernel:interactable-pointer-axis
    ((component rmlui-component) world seat local-x local-y input)
  (declare (ignore world seat))
  (let* ((delta
           (* (if (eq (ataxia.kernel:cursor-axis-input-relative-direction input)
                      :inverted)
                  -1d0 1d0)
              (ataxia.kernel:cursor-axis-input-delta input)))
         (horizontal-p
           (eq (ataxia.kernel:cursor-axis-input-orientation input) :horizontal)))
    (ataxia.world.rmlui.raw::check-result
     (ataxia.world.rmlui.raw::%pointer-scroll
      (%live-native component) (%single local-x) (%single local-y)
      (%single (if horizontal-p delta 0d0))
      (%single (if horizontal-p 0d0 delta)))
     :pointer-scroll))
  (poll-rmlui-callbacks component)
  (%delivered component))

(defmethod ataxia.kernel:interactable-pointer-leave
    ((component rmlui-component) world seat)
  (declare (ignore world seat))
  (ataxia.world.rmlui.raw::check-result
   (ataxia.world.rmlui.raw::%pointer-exit (%live-native component))
   :pointer-exit)
  (poll-rmlui-callbacks component)
  (%delivered component))

(defun %modifier-mask (names)
  (logior (if (member :control names) 1 0) (if (member :shift names) 2 0)
          (if (member :alt names) 4 0) (if (member :logo names) 8 0)
          (if (member :caps-lock names) 16 0) (if (member :num-lock names) 32 0)))

(defun %key-symbol-number (symbol)
  ;; Kernel copies XKB names into key-input; native RmlUi consumes numeric keysyms.
  (etypecase symbol
    ((unsigned-byte 32) symbol)
    (string (cffi:foreign-funcall "xkb_keysym_from_name" :string symbol :int 0 :uint32))))

(defun %forward-rmlui-key (component symbol pressed modifiers)
  (ataxia.world.rmlui.raw::check-result
   (ataxia.world.rmlui.raw::%key-symbol (%live-native component) (%key-symbol-number symbol)
                                      pressed (%modifier-mask modifiers)) :key))

(defun %clipboard-paste-key-p (symbol modifiers)
  (or (and (member :control modifiers) (member symbol '("v" "V") :test #'equal))
      (and (member :shift modifiers) (equal symbol "Insert"))))

(defmethod ataxia.kernel:interactable-key-event
    ((component rmlui-component) world seat input)
  (when (typep input 'ataxia.kernel:modifiers-input)
    (ataxia.world.rmlui.raw::check-result
     (ataxia.world.rmlui.raw::%modifier-mask
      (%live-native component) (%modifier-mask (ataxia.kernel:modifiers-input-names input)))
     :modifiers))
  (when (typep input 'ataxia.kernel:key-input)
    (let ((pressed (eq (ataxia.kernel:key-input-state input) :pressed))
          (modifiers (ataxia.kernel:key-input-modifiers input)))
      (loop for symbol across (ataxia.kernel:key-input-keysyms input) do
        (let ((paste-symbol symbol)
              (revision (ataxia.world.rmlui.raw::%clipboard-revision))
              (focus (gethash :clipboard-focus (%component-pressed-keys component)))
              (target (ataxia.world:world-seat-focus world seat)))
          (unless
              (and pressed (%clipboard-paste-key-p symbol modifiers)
                   (ataxia.world:request-clipboard-text world seat
                     (lambda (text)
                       (when (and text (not (%component-destroyed-p component))
                                  (eq focus (gethash :clipboard-focus (%component-pressed-keys component)))
                                  (eq target (ataxia.world:world-seat-focus world seat)))
                         (ataxia.world.rmlui.raw::%clipboard-set text)
                         (%forward-rmlui-key component paste-symbol t modifiers)
                         (poll-rmlui-callbacks component) (%notify-change component)))))
            (%forward-rmlui-key component symbol pressed modifiers))
          (when (/= revision (ataxia.world.rmlui.raw::%clipboard-revision))
            (ataxia.world:set-clipboard-text world seat (ataxia.world.rmlui.raw::%clipboard-text)))))))
  (poll-rmlui-callbacks component)
  (%delivered component))

(defmethod ataxia.kernel:interactable-focus
    ((component rmlui-component) world seat focus-kind)
  (declare (ignore world seat))
  (unless (eq focus-kind :keyboard)
    (clrhash (%component-pressed-keys component)))
  (setf (gethash :clipboard-focus (%component-pressed-keys component)) (list focus-kind))
  (ataxia.world.rmlui.raw::check-result
   (ataxia.world.rmlui.raw::%focus
    (%live-native component) (eq focus-kind :keyboard))
   :focus)
  (poll-rmlui-callbacks component)
  (%delivered component))

(defmethod ataxia.kernel:request-object-configuration
    ((component rmlui-component) world configuration)
  (declare (ignore world configuration))
  component)

(defmethod ataxia.kernel:request-object-state
    ((component rmlui-component) world state value)
  (declare (ignore world state value))
  component)
