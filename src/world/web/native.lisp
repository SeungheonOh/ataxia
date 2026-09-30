(in-package #:ataxia.world.web.raw)
(defun library-path ()
  (or (uiop:getenv "ATAXIA_WEB_NATIVE")
      (namestring (asdf:system-relative-pathname "ataxia-web" "build/libataxia-web-native.so"))))
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
        (error "Cannot load Web UI: ~A" (foreign-funcall "dlerror" :string)))
      (setf *native-library-handle* handle
            *native-functions* (make-hash-table :test #'equal)
            *library-loaded-p* t)
      ;; Retain old handles: Web UI owns thread-local platform destructors whose
      ;; code must remain mapped until the compositor thread terminates.
      (push handle *native-library-handles*)))
  t)

(defun %native-function-pointer (name)
  (load-library)
  (or (gethash name *native-functions*)
      (let ((pointer (foreign-funcall "dlsym" :pointer *native-library-handle*
                                     :string name :pointer)))
        (when (null-pointer-p pointer) (error "Missing Web UI native symbol: ~A" name))
        (setf (gethash name *native-functions*) pointer))))

(defmacro %define-native-call ((foreign-name lisp-name) return-type &rest arguments)
  `(defun ,lisp-name ,(mapcar #'first arguments)
     (foreign-funcall-pointer (%native-function-pointer ,foreign-name) ()
       ,@(loop for (name type) in arguments append (list type name)) ,return-type)))

(%define-native-call ("ataxia_web_abi" %abi) :int)
(%define-native-call ("ataxia_web_error" %error) :string)
(%define-native-call ("ataxia_web_engine_create_for_display" %engine-create) :pointer (helper :string) (display :string))
(%define-native-call ("ataxia_web_engine_destroy" %engine-destroy) :void (engine :pointer))
(%define-native-call ("ataxia_web_engine_fd" %engine-fd) :int (engine :pointer))
(%define-native-call ("ataxia_web_engine_socket" %engine-socket) :int (engine :pointer))
(%define-native-call ("ataxia_web_engine_pid" %engine-pid) :int (engine :pointer))
(%define-native-call ("ataxia_web_engine_drain" %engine-drain) :void (engine :pointer))
(%define-native-call ("ataxia_web_engine_receive" %engine-receive) :int (engine :pointer))
(%define-native-call ("ataxia_web_create" %create) :pointer
  (engine :pointer) (width :int) (height :int) (scale :double) (url :string))
(%define-native-call ("ataxia_web_destroy" %destroy) :void (component :pointer) (notify :int))
(%define-native-call ("ataxia_web_command" %command) :int
  (component :pointer) (op :int) (a :int) (b :int) (c :int) (d :int) (scale :double) (text :string))
(%define-native-call ("ataxia_web_dirty" %dirty) :int (component :pointer))
(%define-native-call ("ataxia_web_paints" %paints) :uint64 (component :pointer))
(%define-native-call ("ataxia_web_uploads" %uploads) :uint64 (component :pointer))
(%define-native-call ("ataxia_web_uploaded_bytes" %uploaded-bytes) :uint64 (component :pointer))
(%define-native-call ("ataxia_web_event" %event) :int (component :pointer) (name :pointer) (value :pointer))
(%define-native-call ("ataxia_web_upload" %upload) :int (component :pointer) (rect :pointer))
(%define-native-call ("ataxia_web_texture" %texture) :uint (component :pointer))
(%define-native-call ("ataxia_web_width" %width) :int (component :pointer))
(%define-native-call ("ataxia_web_height" %height) :int (component :pointer))
(%define-native-call ("ataxia_web_detach" %detach) :void (component :pointer))

(%define-native-call ("ataxia_web_dropped" %dropped) :uint (component :pointer))
(%define-native-call ("ataxia_web_transport" %transport) :int (component :pointer))
(%define-native-call ("ataxia_web_gpu_copies" %gpu-copies) :uint64 (component :pointer))
(%define-native-call ("ataxia_web_gpu_imports" %gpu-imports) :uint64 (component :pointer))
(%define-native-call ("ataxia_web_skipped" %skipped) :uint64 (component :pointer))
(%define-native-call ("ataxia_web_popup_texture" %popup-texture) :uint (component :pointer))
(%define-native-call ("ataxia_web_popup_x" %popup-x) :int (component :pointer))
(%define-native-call ("ataxia_web_popup_y" %popup-y) :int (component :pointer))
(%define-native-call ("ataxia_web_popup_width" %popup-width) :int (component :pointer))
(%define-native-call ("ataxia_web_popup_height" %popup-height) :int (component :pointer))
