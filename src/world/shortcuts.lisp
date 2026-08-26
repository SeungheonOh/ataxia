;;;; Reusable keyboard shortcut dispatch for Worlds.
;;;;
;;;; Bindings are declarative and World methods own command behavior. The
;;;; controller keeps only per-seat press state needed to match repeats and
;;;; prevent a consumed press from leaking its release to the focused object.

(in-package #:ataxia.world)

(defparameter +shortcut-modifiers+
  '(:shift :control :alt :logo))

(defstruct (shortcut-binding
             (:constructor %make-shortcut-binding
                 (&key id key-kind key modifiers exact-modifiers-p
                       press-command release-command repeat-p predicate
                       consume-p)))
  id
  (key-kind :keysym :type keyword)
  key
  (modifiers nil :type list)
  (exact-modifiers-p t :type boolean)
  press-command
  release-command
  (repeat-p nil :type boolean)
  predicate
  (consume-p t :type boolean))

(defclass shortcut-map ()
  ((bindings :initarg :bindings :initform nil :accessor shortcut-map-bindings)))

(defclass shortcut-controller ()
  ((maps :initarg :maps :initform nil :accessor shortcut-controller-maps)
   (seat-states :initform (make-hash-table :test #'eq)
                :reader %shortcut-seat-states)))

(defstruct (%active-shortcut
             (:constructor %make-active-shortcut (binding consume-p)))
  binding
  (consume-p nil :type boolean))

(defstruct (%shortcut-seat-state (:constructor %make-shortcut-seat-state))
  (pressed (make-hash-table :test #'equal))
  (active (make-hash-table :test #'equal)))

(defgeneric world-shortcut-controller (world)
  (:documentation "Return the reusable shortcut controller owned by WORLD."))

(defgeneric invoke-shortcut-command (world command seat binding input)
  (:documentation "Invoke a symbolic shortcut command in WORLD."))

(defmethod invoke-shortcut-command (world command seat binding input)
  (declare (ignore world command seat binding input))
  nil)

(defun %normalize-shortcut-modifiers (modifiers &key reject-unknown-p)
  (when reject-unknown-p
    (dolist (modifier modifiers)
      (unless (member modifier +shortcut-modifiers+)
        (error "Unknown shortcut modifier ~S." modifier))))
  (loop for modifier in +shortcut-modifiers+
        when (member modifier modifiers)
          collect modifier))

(defun %normalize-shortcut-key (key)
  (unless (and (consp key) (null (cddr key)))
    (error "Shortcut key must be (:PHYSICAL KEYCODE) or (:KEYSYM NAME)."))
  (destructuring-bind (kind value) key
    (ecase kind
      (:physical
       (check-type value (unsigned-byte 32))
       (values kind value))
      (:keysym
       (values kind
               (etypecase value
                 (string value)
                 (symbol (symbol-name value))))))))

(defun make-shortcut-binding
    (&key id key modifiers (exact-modifiers-p t) press-command
       release-command repeat-p predicate (consume-p t))
  (unless id
    (error "Shortcut bindings require an ID."))
  (multiple-value-bind (key-kind normalized-key)
      (%normalize-shortcut-key key)
    (%make-shortcut-binding
     :id id
     :key-kind key-kind
     :key normalized-key
     :modifiers (%normalize-shortcut-modifiers modifiers :reject-unknown-p t)
     :exact-modifiers-p exact-modifiers-p
     :press-command press-command
     :release-command release-command
     :repeat-p repeat-p
     :predicate predicate
     :consume-p consume-p)))

(defun make-shortcut-map (&rest bindings)
  (dolist (binding bindings)
    (check-type binding shortcut-binding))
  (make-instance 'shortcut-map :bindings (copy-list bindings)))

(defun bind-shortcut (map &rest arguments &key id &allow-other-keys)
  (check-type map shortcut-map)
  (let ((binding (apply #'make-shortcut-binding arguments)))
    (setf (shortcut-map-bindings map)
          (cons binding
                (remove id (shortcut-map-bindings map)
                        :key #'shortcut-binding-id :test #'equal)))
    binding))

(defun unbind-shortcut (map id)
  (check-type map shortcut-map)
  (let* ((bindings (shortcut-map-bindings map))
         (remaining
           (remove id bindings :key #'shortcut-binding-id :test #'equal)))
    (setf (shortcut-map-bindings map) remaining)
    (/= (length bindings) (length remaining))))

(defun make-shortcut-controller (&key maps)
  (dolist (map maps)
    (check-type map shortcut-map))
  (make-instance 'shortcut-controller :maps (copy-list maps)))

(defun %shortcut-seat-state (controller seat)
  (or (gethash seat (%shortcut-seat-states controller))
      (setf (gethash seat (%shortcut-seat-states controller))
            (%make-shortcut-seat-state))))

(defun forget-shortcut-seat (controller seat)
  (check-type controller shortcut-controller)
  (remhash seat (%shortcut-seat-states controller)))

(defun %shortcut-key-token (input)
  (list (ataxia.kernel:key-input-device input)
        (ataxia.kernel:key-input-keycode input)))

(defun %shortcut-modifiers-match-p (binding active)
  (let ((required (shortcut-binding-modifiers binding)))
    (if (shortcut-binding-exact-modifiers-p binding)
        (equal required active)
        (every (lambda (modifier) (member modifier active)) required))))

(defun %shortcut-key-match-p (binding input)
  (ecase (shortcut-binding-key-kind binding)
    (:physical
     (= (shortcut-binding-key binding)
        (ataxia.kernel:key-input-keycode input)))
    (:keysym
     (find (shortcut-binding-key binding)
           (ataxia.kernel:key-input-keysyms input)
           :test #'string-equal))))

(defun %shortcut-predicate-p (binding world seat input)
  (let ((predicate (shortcut-binding-predicate binding)))
    (if predicate
        (funcall predicate world seat binding input)
        t)))

(defun %find-shortcut-binding (controller world seat input)
  (let ((active-modifiers
          (%normalize-shortcut-modifiers
           (ataxia.kernel:key-input-modifiers input))))
    (loop for map in (shortcut-controller-maps controller)
          do (check-type map shortcut-map)
          thereis
          (find-if
           (lambda (binding)
             (and (%shortcut-key-match-p binding input)
                  (%shortcut-modifiers-match-p binding active-modifiers)
                  (%shortcut-predicate-p binding world seat input)))
           (shortcut-map-bindings map)))))

(defun %invoke-shortcut (world command seat binding input)
  (cond
    ((null command) t)
    ((functionp command)
     (funcall command world seat binding input))
    (t
     (invoke-shortcut-command world command seat binding input))))

(defun %handle-shortcut-press (controller world seat input state token)
  (let ((active (gethash token (%shortcut-seat-state-active state)))
        (repeated-p (gethash token (%shortcut-seat-state-pressed state))))
    (if repeated-p
        (if active
            (progn
              (when (shortcut-binding-repeat-p
                     (%active-shortcut-binding active))
                (%invoke-shortcut
                 world
                 (shortcut-binding-press-command
                  (%active-shortcut-binding active))
                 seat (%active-shortcut-binding active) input))
              (if (%active-shortcut-consume-p active) :consumed :forward))
            :forward)
        (progn
          (setf (gethash token (%shortcut-seat-state-pressed state)) t)
          (let ((binding (%find-shortcut-binding controller world seat input)))
            (if (and binding
                     (%invoke-shortcut
                      world (shortcut-binding-press-command binding)
                      seat binding input))
                (progn
                  (setf (gethash token (%shortcut-seat-state-active state))
                        (%make-active-shortcut
                         binding (shortcut-binding-consume-p binding)))
                  (if (shortcut-binding-consume-p binding)
                      :consumed
                      :forward))
                :forward))))))

(defun %handle-shortcut-release (world seat input state token)
  (remhash token (%shortcut-seat-state-pressed state))
  (let ((active (gethash token (%shortcut-seat-state-active state))))
    (if active
        (progn
          (remhash token (%shortcut-seat-state-active state))
          (%invoke-shortcut
           world
           (shortcut-binding-release-command
            (%active-shortcut-binding active))
           seat (%active-shortcut-binding active) input)
          (if (%active-shortcut-consume-p active) :consumed :forward))
        :forward)))

(defun handle-shortcut-input (controller world seat input)
  "Dispatch INPUT and return either :CONSUMED or :FORWARD."
  (check-type controller shortcut-controller)
  (typecase input
    (ataxia.kernel:modifiers-input :forward)
    (ataxia.kernel:key-input
     (let* ((state (%shortcut-seat-state controller seat))
            (token (%shortcut-key-token input)))
       (case (ataxia.kernel:key-input-state input)
         (:pressed
          (%handle-shortcut-press controller world seat input state token))
         (:released
          (%handle-shortcut-release world seat input state token))
         (otherwise :forward))))
    (t :forward)))
