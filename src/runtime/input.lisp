;;;; XKB keyboard configuration primitives.
;;;;
;;;; This module creates typed xkbcommon contexts and keymaps in Common Lisp,
;;;; installs them on concrete wlroots keyboards, and configures repeat timing.
;;;; Layout selection and shortcut policy remain outside Runtime.

(in-package #:ataxia.runtime.raw)

(defcstruct xkb-rule-names
  (rules :pointer)
  (model :pointer)
  (layout :pointer)
  (variant :pointer)
  (options :pointer))

(defcfun ("xkb_context_new" %xkb-context-new) :pointer
  (flags :uint32))
(defcfun ("xkb_context_unref" %xkb-context-unref) :void
  (context :pointer))
(defcfun ("xkb_keymap_new_from_names" %xkb-keymap-new-from-names) :pointer
  (context :pointer)
  (names (:pointer (:struct xkb-rule-names)))
  (flags :uint32))
(defcfun ("xkb_keymap_unref" %xkb-keymap-unref) :void
  (keymap :pointer))
(defcfun ("wlr_keyboard_set_keymap" %wlr-keyboard-set-keymap) :boolean
  (keyboard :pointer)
  (keymap :pointer))
(defcfun ("wlr_keyboard_set_repeat_info" %wlr-keyboard-set-repeat-info) :void
  (keyboard :pointer)
  (rate-hertz :int32)
  (delay-milliseconds :int32))

(in-package #:ataxia.runtime)

(defclass wlr-xkb-context (native-object) ()
  (:documentation
   "Wraps the native wlr xkb context object. Runtime owns its listener registration and must invalidate the wrapper before the corresponding native object is destroyed."))

(defclass wlr-xkb-keymap (native-object)
  ((context :initarg :context :reader %xkb-keymap-context))
  (:documentation
   "Wraps the native wlr xkb keymap object. Runtime owns its listener registration and must invalidate the wrapper before the corresponding native object is destroyed."))

(defun create-xkb-context (runtime)
  (%assert-runtime-live runtime :create-xkb-context)
  (let ((context
          (%wrap-pointer
           'wlr-xkb-context
           (%require-pointer
            (ataxia.runtime.raw::%xkb-context-new 0)
            :xkb-context-new)
           runtime)))
    (setf (gethash context (%runtime-xkb-context-table runtime)) t)
    context))

(defun create-xkb-keymap
    (context &key rules model layout variant options)
  (check-type context wlr-xkb-context)
  (let ((runtime (%native-runtime context)))
    (%assert-runtime-live runtime :create-xkb-keymap)
    (let ((allocated-strings nil))
      (labels ((allocate (value)
                 (if value
                     (let ((pointer (cffi:foreign-string-alloc value)))
                       (push pointer allocated-strings)
                       pointer)
                     (ataxia.runtime.raw:null-pointer))))
        (unwind-protect
             (cffi:with-foreign-object
                 (names '(:struct ataxia.runtime.raw::xkb-rule-names))
               (setf
                (cffi:foreign-slot-value
                 names '(:struct ataxia.runtime.raw::xkb-rule-names)
                 'ataxia.runtime.raw::rules)
                (allocate rules)
                (cffi:foreign-slot-value
                 names '(:struct ataxia.runtime.raw::xkb-rule-names)
                 'ataxia.runtime.raw::model)
                (allocate model)
                (cffi:foreign-slot-value
                 names '(:struct ataxia.runtime.raw::xkb-rule-names)
                 'ataxia.runtime.raw::layout)
                (allocate layout)
                (cffi:foreign-slot-value
                 names '(:struct ataxia.runtime.raw::xkb-rule-names)
                 'ataxia.runtime.raw::variant)
                (allocate variant)
                (cffi:foreign-slot-value
                 names '(:struct ataxia.runtime.raw::xkb-rule-names)
                 'ataxia.runtime.raw::options)
                (allocate options))
               (let ((keymap
                       (%wrap-pointer
                        'wlr-xkb-keymap
                        (%require-pointer
                         (ataxia.runtime.raw::%xkb-keymap-new-from-names
                          (%object-pointer context) names 0)
                         :xkb-keymap-new-from-names)
                        runtime
                        :context context)))
                 (setf (gethash keymap (%runtime-xkb-keymap-table runtime)) t)
                 keymap))
          (dolist (pointer allocated-strings)
            (cffi:foreign-string-free pointer)))))))

(defun set-keyboard-keymap (keyboard keymap)
  (check-type keyboard wlr-keyboard)
  (check-type keymap wlr-xkb-keymap)
  (let ((runtime (%native-runtime keyboard)))
    (%assert-runtime-live runtime :set-keyboard-keymap)
    (%assert-object-runtime runtime keymap :set-keyboard-keymap)
    (unless (ataxia.runtime.raw::%wlr-keyboard-set-keymap
             (%object-pointer keyboard) (%object-pointer keymap))
      (error 'native-call-failed :name :wlr-keyboard-set-keymap)))
  keyboard)

(defun set-keyboard-keymap-from-names
    (keyboard &key rules model layout variant options)
  (let* ((runtime (%native-runtime keyboard))
         (context (create-xkb-context runtime))
         (keymap nil))
    (unwind-protect
         (progn
           (setf keymap
                 (create-xkb-keymap
                  context
                  :rules rules :model model :layout layout
                  :variant variant :options options))
           (set-keyboard-keymap keyboard keymap))
      (when keymap (destroy-xkb-keymap keymap))
      (destroy-xkb-context context)))
  keyboard)

(defun set-keyboard-repeat-info (keyboard rate-hertz delay-milliseconds)
  (check-type keyboard wlr-keyboard)
  (check-type rate-hertz (signed-byte 32))
  (check-type delay-milliseconds (signed-byte 32))
  (%assert-runtime-live
   (%native-runtime keyboard) :set-keyboard-repeat-info)
  (ataxia.runtime.raw::%wlr-keyboard-set-repeat-info
   (%object-pointer keyboard) rate-hertz delay-milliseconds)
  keyboard)

(defun destroy-xkb-keymap (keymap)
  (check-type keymap wlr-xkb-keymap)
  (when (native-object-live-p keymap)
    (let ((runtime (%native-runtime keymap)))
      (%assert-owner-thread runtime :destroy-xkb-keymap)
      (ataxia.runtime.raw::%xkb-keymap-unref (%object-pointer keymap))
      (%invalidate-native-object keymap)
      (remhash keymap (%runtime-xkb-keymap-table runtime))))
  nil)

(defun destroy-xkb-context (context)
  (check-type context wlr-xkb-context)
  (when (native-object-live-p context)
    (let ((runtime (%native-runtime context)))
      (%assert-owner-thread runtime :destroy-xkb-context)
      (when (loop for keymap being the hash-keys
                    of (%runtime-xkb-keymap-table runtime)
                  thereis (and (native-object-live-p keymap)
                               (eq context (%xkb-keymap-context keymap))))
        (error 'native-call-failed
               :name :destroy-xkb-context
               :detail "live keymaps still reference the context"))
      (ataxia.runtime.raw::%xkb-context-unref (%object-pointer context))
      (%invalidate-native-object context)
      (remhash context (%runtime-xkb-context-table runtime))))
  nil)

(defun %destroy-runtime-xkb-objects (runtime)
  (dolist (keymap
            (loop for keymap being the hash-keys
                    of (%runtime-xkb-keymap-table runtime)
                  collect keymap))
    (destroy-xkb-keymap keymap))
  (dolist (context
            (loop for context being the hash-keys
                    of (%runtime-xkb-context-table runtime)
                  collect context))
    (destroy-xkb-context context))
  runtime)
