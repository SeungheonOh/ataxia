;;;; CFFI boundary to the World-owned RmlUi interpreter host.
;;;;
;;;; C++ retains RmlUi scene objects and renders into a World-owned GLES
;;;; framebuffer only while the compositor has granted an active frame scope.

(in-package #:ataxia.world.rmlui.raw)

(defconstant +expected-abi+ 2)

(defun library-path ()
  (or (uiop:getenv "ATAXIA_RMLUI_NATIVE")
      (namestring
       (asdf:system-relative-pathname
        "ataxia-rmlui" "build/libataxia-rmlui-native.so"))))

(defvar *library-loaded-p* nil)
(defvar *native-library-handle* nil)
(defvar *native-library-handles* nil)
(defvar *native-functions* (make-hash-table :test #'equal))

(defun load-library ()
  (unless *library-loaded-p*
    ;; CFFI's SBCL backend resolves DEFCFUN globally, even with :LIBRARY.
    ;; Resolve through an explicit handle so a live UI upgrade cannot mix
    ;; component pointers and functions from different native builds.
    (let ((handle (foreign-funcall "dlopen" :string (library-path) :int 2 :pointer)))
      (when (null-pointer-p handle)
        (error "Cannot load RmlUi: ~A" (foreign-funcall "dlerror" :string)))
      (setf *native-library-handle* handle
            *native-functions* (make-hash-table :test #'equal)
            *library-loaded-p* t)
      ;; Retain old handles: RmlUi owns thread-local platform destructors whose
      ;; code must remain mapped until the compositor thread terminates.
      (push handle *native-library-handles*)))
  t)

(defun %native-function-pointer (name)
  (load-library)
  (or (gethash name *native-functions*)
      (let ((pointer (foreign-funcall "dlsym" :pointer *native-library-handle*
                                     :string name :pointer)))
        (when (null-pointer-p pointer) (error "Missing RmlUi native symbol: ~A" name))
        (setf (gethash name *native-functions*) pointer))))

(defmacro %define-native-call ((foreign-name lisp-name) return-type &rest arguments)
  `(defun ,lisp-name ,(mapcar #'first arguments)
     (foreign-funcall-pointer (%native-function-pointer ,foreign-name) ()
       ,@(loop for (name type) in arguments append (list type name)) ,return-type)))

(%define-native-call ("ataxia_rmlui_abi_version" %abi-version) :uint32)
(%define-native-call ("ataxia_rmlui_last_error" %last-error) :string)
(%define-native-call ("ataxia_rmlui_initialize" %initialize) :boolean)
(%define-native-call ("ataxia_rmlui_component_create" %component-create) :pointer
  (source :string) (source-path :string) (component-name :string)
  (width :uint32) (height :uint32) (scale :float))
(%define-native-call ("ataxia_rmlui_component_destroy" %component-destroy) :void
  (component :pointer))
(%define-native-call ("ataxia_rmlui_component_resize" %component-resize) :boolean
  (component :pointer) (width :uint32) (height :uint32) (scale :float))
(%define-native-call ("ataxia_rmlui_component_attach_graphics"
          %component-attach-graphics) :boolean
  (component :pointer) (framebuffer :uint32))
(%define-native-call ("ataxia_rmlui_component_detach_graphics"
          %component-detach-graphics) :boolean
  (component :pointer))
(%define-native-call ("ataxia_rmlui_component_render" %component-render) :boolean
  (component :pointer))
(%define-native-call ("ataxia_rmlui_component_width" %component-width) :uint32
  (component :pointer))
(%define-native-call ("ataxia_rmlui_component_height" %component-height) :uint32
  (component :pointer))
(%define-native-call ("ataxia_rmlui_component_revision" %component-revision) :uint64
  (component :pointer))
(%define-native-call ("ataxia_rmlui_component_has_active_animations"
          %component-active-p) :boolean
  (component :pointer))
(%define-native-call ("ataxia_rmlui_component_pointer_motion" %pointer-motion) :boolean
  (component :pointer) (x :float) (y :float))
(%define-native-call ("ataxia_rmlui_component_pointer_button" %pointer-button) :boolean
  (component :pointer) (x :float) (y :float) (button :uint32)
  (pressed :boolean))
(%define-native-call ("ataxia_rmlui_component_pointer_scroll" %pointer-scroll) :boolean
  (component :pointer) (x :float) (y :float) (delta-x :float) (delta-y :float))
(%define-native-call ("ataxia_rmlui_component_pointer_exit" %pointer-exit) :boolean
  (component :pointer))
(%define-native-call ("ataxia_rmlui_component_focus" %focus) :boolean
  (component :pointer) (focused :boolean))
(%define-native-call ("ataxia_rmlui_component_set_string" %set-string) :boolean
  (component :pointer) (name :string) (value :string))
(%define-native-call ("ataxia_rmlui_component_set_number" %set-number) :boolean
  (component :pointer) (name :string) (value :double))
(%define-native-call ("ataxia_rmlui_component_set_boolean" %set-boolean) :boolean
  (component :pointer) (name :string) (value :boolean))
(%define-native-call ("ataxia_rmlui_component_register_callback" %register-callback) :boolean
  (component :pointer) (name :string))
(%define-native-call ("ataxia_rmlui_component_unregister_callback" %unregister-callback) :boolean
  (component :pointer) (name :string))
(%define-native-call ("ataxia_rmlui_component_callback_count" %callback-count) :size
  (component :pointer))
(%define-native-call ("ataxia_rmlui_component_callback_name" %callback-name) :string
  (component :pointer) (index :size))
(%define-native-call ("ataxia_rmlui_component_callback_value" %callback-value) :string
  (component :pointer) (index :size))
(%define-native-call ("ataxia_rmlui_component_clear_callbacks" %clear-callbacks) :void
  (component :pointer))

(defun native-error (operation)
  (error "RmlUi ~A failed: ~A" operation (or (%last-error) "unknown error")))

(defun check-result (result operation)
  (unless result (native-error operation))
  result)

(defun initialize ()
  (load-library)
  (unless (= (%abi-version) +expected-abi+)
    (error "RmlUi native ABI mismatch: expected ~D, received ~D."
           +expected-abi+ (%abi-version)))
  (check-result (%initialize) :initialize))

(%define-native-call ("ataxia_rmlui_component_next_update" %next-update) :double (component :pointer))
(%define-native-call ("ataxia_rmlui_component_key_symbol" %key-symbol) :boolean
  (component :pointer) (symbol :uint32) (pressed :boolean) (modifiers :int))
(%define-native-call ("ataxia_rmlui_component_set_class" %set-class) :boolean
  (component :pointer) (id :string) (name :string) (enabled :boolean))
(%define-native-call ("ataxia_rmlui_component_set_style" %set-style) :boolean
  (component :pointer) (id :string) (name :string) (value :string))
(%define-native-call ("ataxia_rmlui_component_set_attribute" %set-attribute) :boolean
  (component :pointer) (id :string) (name :string) (value :string) (present :boolean))
(%define-native-call ("ataxia_rmlui_load_font" %load-font) :boolean (path :string))
(%define-native-call ("ataxia_rmlui_component_reload" %reload) :boolean
  (component :pointer) (source :string) (path :string))
(%define-native-call ("ataxia_rmlui_gl_save" %gl-save) :pointer)
(%define-native-call ("ataxia_rmlui_gl_restore" %gl-restore) :void (state :pointer))

(%define-native-call ("ataxia_rmlui_model_string" %model-string) :boolean
  (component :pointer) (name :string) (value :string))
(%define-native-call ("ataxia_rmlui_model_number" %model-number) :boolean
  (component :pointer) (name :string) (value :double))
(%define-native-call ("ataxia_rmlui_model_boolean" %model-boolean) :boolean
  (component :pointer) (name :string) (value :boolean))
(%define-native-call ("ataxia_rmlui_model_value" %model-value) :string
  (component :pointer) (name :string))
(%define-native-call ("ataxia_rmlui_component_modifier_mask" %modifier-mask) :boolean
  (component :pointer) (mask :int))
(%define-native-call ("ataxia_rmlui_clipboard_text" %clipboard-text) :string)
(%define-native-call ("ataxia_rmlui_clipboard_revision" %clipboard-revision) :uint64)
(%define-native-call ("ataxia_rmlui_clipboard_set" %clipboard-set) :boolean (text :string))
