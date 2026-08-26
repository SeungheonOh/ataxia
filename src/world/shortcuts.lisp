;;;; Flat keyboard shortcut dispatch for Worlds.
;;;;
;;;; A controller owns one binding set, indexed by normalized key. Worlds may
;;;; replace that set synchronously while held keys retain the binding snapshot
;;;; that handled their press.

(in-package #:ataxia.world)

(defparameter +shortcut-modifiers+
  '(:shift :control :alt :logo))

(defclass shortcut-binding ()
  ((id :initarg :id :reader shortcut-binding-id)
   (key-kind :initarg :key-kind :reader shortcut-binding-key-kind)
   (key :initarg :key :reader shortcut-binding-key)
   (modifiers :initarg :modifiers :reader shortcut-binding-modifiers)
   (exact-modifiers-p :initarg :exact-modifiers-p
                      :reader shortcut-binding-exact-modifiers-p)
   (priority :initarg :priority :reader shortcut-binding-priority)
   (press-handler :initarg :press-handler
                  :reader shortcut-binding-press-handler)
   (release-handler :initarg :release-handler
                    :reader shortcut-binding-release-handler)
   (repeat-p :initarg :repeat-p :reader shortcut-binding-repeat-p)
   (predicate :initarg :predicate :reader shortcut-binding-predicate)
   (consume-p :initarg :consume-p :reader shortcut-binding-consume-p)
   (enabled-p :initarg :enabled-p :reader shortcut-binding-enabled-p)))

(defclass shortcut-controller ()
  ((bindings :initform (make-hash-table :test #'equal)
             :accessor %shortcut-controller-bindings)
   (order :initform nil :accessor %shortcut-controller-order)
   (keysym-index :initform (make-hash-table :test #'equal)
                 :accessor %shortcut-controller-keysym-index)
   (physical-index :initform (make-hash-table :test #'eql)
                   :accessor %shortcut-controller-physical-index)
   (revision :initform 0 :accessor %shortcut-controller-revision)
   (seat-states :initform (make-hash-table :test #'eq)
                :reader %shortcut-seat-states)))

(defstruct (%active-shortcut
             (:constructor %make-active-shortcut (binding consume-p)))
  binding
  (consume-p nil :type boolean))

(defstruct (%shortcut-seat-state (:constructor %make-shortcut-seat-state))
  (pressed (make-hash-table :test #'equal))
  (active (make-hash-table :test #'equal)))

(define-condition shortcut-ambiguity (error)
  ((bindings :initarg :bindings :reader shortcut-ambiguity-bindings)
   (input :initarg :input :reader shortcut-ambiguity-input))
  (:report
   (lambda (condition stream)
     (format stream "Shortcut input matches equal-priority bindings ~{~S~^, ~}."
             (mapcar #'shortcut-binding-id
                     (shortcut-ambiguity-bindings condition))))))

(defgeneric world-shortcut-controller (world)
  (:documentation "Return the shortcut controller owned by WORLD."))

(defun shortcut-controller-revision (controller)
  (check-type controller shortcut-controller)
  (%shortcut-controller-revision controller))

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
               (string-upcase
                (etypecase value
                  (string value)
                  (symbol (symbol-name value)))))))))

(defun %check-shortcut-function (function role)
  (unless (or (null function) (functionp function) (symbolp function))
    (error "Shortcut ~A must be a function designator or NIL, not ~S."
           role function))
  function)

(defun make-shortcut-binding
    (&key id key modifiers (exact-modifiers-p t) (priority 0)
       press-handler release-handler repeat-p predicate (consume-p t)
       (enabled-p t))
  "Create an immutable shortcut definition."
  (unless id
    (error "Shortcut bindings require an ID."))
  (check-type priority integer)
  (multiple-value-bind (key-kind normalized-key)
      (%normalize-shortcut-key key)
    (make-instance
     'shortcut-binding
     :id id
     :key-kind key-kind
     :key normalized-key
     :modifiers (%normalize-shortcut-modifiers modifiers :reject-unknown-p t)
     :exact-modifiers-p (not (null exact-modifiers-p))
     :priority priority
     :press-handler (%check-shortcut-function press-handler "press handler")
     :release-handler (%check-shortcut-function release-handler "release handler")
     :repeat-p (not (null repeat-p))
     :predicate (%check-shortcut-function predicate "predicate")
     :consume-p (not (null consume-p))
     :enabled-p (not (null enabled-p)))))

(defun %copy-shortcut-binding (binding &key (enabled-p nil enabled-supplied-p))
  (make-shortcut-binding
   :id (shortcut-binding-id binding)
   :key (list (shortcut-binding-key-kind binding)
              (shortcut-binding-key binding))
   :modifiers (shortcut-binding-modifiers binding)
   :exact-modifiers-p (shortcut-binding-exact-modifiers-p binding)
   :priority (shortcut-binding-priority binding)
   :press-handler (shortcut-binding-press-handler binding)
   :release-handler (shortcut-binding-release-handler binding)
   :repeat-p (shortcut-binding-repeat-p binding)
   :predicate (shortcut-binding-predicate binding)
   :consume-p (shortcut-binding-consume-p binding)
   :enabled-p (if enabled-supplied-p
                  enabled-p
                  (shortcut-binding-enabled-p binding))))

(defun %index-shortcut (binding keysym-index physical-index)
  (ecase (shortcut-binding-key-kind binding)
    (:keysym
     (push binding
           (gethash (shortcut-binding-key binding) keysym-index)))
    (:physical
     (push binding
           (gethash (shortcut-binding-key binding) physical-index)))))

(defun %build-shortcut-state (shortcuts)
  (let ((bindings (make-hash-table :test #'equal))
        (order nil)
        (keysym-index (make-hash-table :test #'equal))
        (physical-index (make-hash-table :test #'eql)))
    (dolist (binding shortcuts)
      (check-type binding shortcut-binding)
      (let ((id (shortcut-binding-id binding)))
        (when (gethash id bindings)
          (error "Duplicate shortcut ID ~S." id))
        (setf (gethash id bindings) binding)
        (push id order)
        (%index-shortcut binding keysym-index physical-index)))
    (values bindings (nreverse order) keysym-index physical-index)))

(defun %install-shortcuts (controller shortcuts &key increment-revision-p)
  (multiple-value-bind (bindings order keysym-index physical-index)
      (%build-shortcut-state shortcuts)
    (setf (%shortcut-controller-bindings controller) bindings
          (%shortcut-controller-order controller) order
          (%shortcut-controller-keysym-index controller) keysym-index
          (%shortcut-controller-physical-index controller) physical-index)
    (when increment-revision-p
      (incf (%shortcut-controller-revision controller))))
  controller)

(defun make-shortcut-controller (&key shortcuts)
  "Create one flat shortcut controller containing SHORTCUTS."
  (%install-shortcuts (make-instance 'shortcut-controller)
                      (coerce shortcuts 'list)))

(defun find-shortcut (controller id)
  (check-type controller shortcut-controller)
  (gethash id (%shortcut-controller-bindings controller)))

(defun list-shortcuts (controller)
  (check-type controller shortcut-controller)
  (loop for id in (%shortcut-controller-order controller)
        collect (gethash id (%shortcut-controller-bindings controller))))

(defun replace-shortcuts (controller shortcuts)
  "Atomically replace CONTROLLER's complete binding set."
  (check-type controller shortcut-controller)
  (%install-shortcuts controller (coerce shortcuts 'list)
                      :increment-revision-p t)
  (list-shortcuts controller))

(defun add-shortcut (controller shortcut &key (if-exists :error))
  "Add SHORTCUT, handling an existing ID according to IF-EXISTS."
  (check-type controller shortcut-controller)
  (check-type shortcut shortcut-binding)
  (let ((existing (find-shortcut controller (shortcut-binding-id shortcut))))
    (when existing
      (ecase if-exists
        (:error
         (error "Shortcut ID ~S already exists."
                (shortcut-binding-id shortcut)))
        (:ignore
         (return-from add-shortcut existing))
        (:replace
         (return-from add-shortcut
           (replace-shortcut controller shortcut)))))
    (replace-shortcuts controller (append (list-shortcuts controller)
                                          (list shortcut)))
    shortcut))

(defun remove-shortcut (controller id)
  "Remove ID and return true when it existed."
  (check-type controller shortcut-controller)
  (when (find-shortcut controller id)
    (replace-shortcuts
     controller
     (remove id (list-shortcuts controller)
             :key #'shortcut-binding-id :test #'equal))
    t))

(defun replace-shortcut (controller shortcut)
  "Replace an existing binding without changing its position."
  (check-type controller shortcut-controller)
  (check-type shortcut shortcut-binding)
  (let ((id (shortcut-binding-id shortcut)))
    (unless (find-shortcut controller id)
      (error "Shortcut ID ~S does not exist." id))
    (replace-shortcuts
     controller
     (substitute shortcut id (list-shortcuts controller)
                 :key #'shortcut-binding-id :test #'equal))
    shortcut))

(defun %set-shortcut-enabled (controller id enabled-p)
  (let ((binding (or (find-shortcut controller id)
                     (error "Shortcut ID ~S does not exist." id))))
    (if (eql (shortcut-binding-enabled-p binding) enabled-p)
        binding
        (replace-shortcut
         controller (%copy-shortcut-binding binding :enabled-p enabled-p)))))

(defun enable-shortcut (controller id)
  "Enable ID by replacing its immutable binding."
  (%set-shortcut-enabled controller id t))

(defun disable-shortcut (controller id)
  "Disable ID by replacing its immutable binding."
  (%set-shortcut-enabled controller id nil))

(defun clear-shortcuts (controller)
  "Remove every binding from CONTROLLER."
  (check-type controller shortcut-controller)
  (unless (null (%shortcut-controller-order controller))
    (replace-shortcuts controller nil))
  controller)

(defmacro update-shortcuts ((editor controller) &body body)
  "Apply BODY to a temporary controller, then commit once on success."
  (let ((target (gensym "CONTROLLER")))
    `(let* ((,target ,controller)
            (,editor (make-shortcut-controller
                      :shortcuts (list-shortcuts ,target))))
       ,@body
       (replace-shortcuts ,target (list-shortcuts ,editor)))))

(defmacro define-shortcuts (constructor &body definitions)
  "Define CONSTRUCTOR and co-located named handlers for DEFINITIONS."
  (labels ((present-p (plist key)
             (loop for tail on plist by #'cddr
                   thereis (eq (car tail) key)))
           (option (plist key default)
             (if (present-p plist key) (getf plist key) default))
           (handler-name (id role)
             (intern (format nil "~A/~A/~A" constructor id role)
                     (symbol-package constructor))))
    (let ((functions nil)
          (bindings nil)
          (seen-ids nil)
          (known-options '(:key :modifiers :exact-modifiers-p :priority
                           :repeat :consume :enabled))
          (known-clauses '(:when :press :release)))
      (dolist (definition definitions)
        (unless (and (consp definition) (consp (cdr definition)))
          (error "Malformed shortcut definition ~S." definition))
        (destructuring-bind (id options &rest clauses) definition
          (unless (symbolp id)
            (error "DEFINE-SHORTCUTS IDs must be symbols, not ~S." id))
          (when (member id seen-ids)
            (error "Duplicate shortcut ID ~S." id))
          (push id seen-ids)
          (unless (and (listp options) (evenp (length options)))
            (error "Shortcut ~S options must be a property list." id))
          (let ((seen-options nil))
            (loop for key in options by #'cddr
                  do (unless (member key known-options)
                       (error "Unknown shortcut option ~S for ~S." key id))
                     (when (member key seen-options)
                       (error "Shortcut ~S repeats option ~S." id key))
                     (push key seen-options)))
          (unless (present-p options :key)
            (error "Shortcut ~S requires :KEY." id))
          (dolist (clause clauses)
            (unless (and (consp clause) (member (car clause) known-clauses))
              (error "Unknown shortcut clause ~S for ~S." clause id)))
          (let ((handlers nil))
            (dolist (role known-clauses)
              (let ((matching-clauses
                      (remove-if-not (lambda (clause)
                                       (eq (car clause) role))
                                     clauses)))
                (when (cdr matching-clauses)
                  (error "Shortcut ~S has multiple ~S clauses." id role))
                (let ((clause (car matching-clauses)))
                  (when clause
                    (unless (and (consp (cdr clause))
                                 (listp (second clause))
                                 (= (length (second clause)) 3))
                      (error "Shortcut ~S ~S handler needs (WORLD SEAT INPUT)."
                             id role))
                    (let ((name (handler-name id role)))
                      (push `(defun ,name ,(second clause) ,@(cddr clause))
                            functions)
                      (push (cons role name) handlers))))))
            (let ((predicate (cdr (assoc :when handlers)))
                  (press (cdr (assoc :press handlers)))
                  (release (cdr (assoc :release handlers))))
              (push
               `(make-shortcut-binding
                 :id ',id
                 :key ',(option options :key nil)
                 :modifiers ',(option options :modifiers nil)
                 :exact-modifiers-p ,(option options :exact-modifiers-p t)
                 :priority ,(option options :priority 0)
                 :repeat-p ,(option options :repeat nil)
                 :consume-p ,(option options :consume t)
                 :enabled-p ,(option options :enabled t)
                 :predicate ,(and predicate `',predicate)
                 :press-handler ,(and press `',press)
                 :release-handler ,(and release `',release))
               bindings)))))
      `(progn
         ,@(nreverse functions)
         (defun ,constructor ()
           (make-shortcut-controller
            :shortcuts (list ,@(nreverse bindings))))))))

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

(defun %call-shortcut-function (function world seat input)
  (when function
    (unless (or (functionp function)
                (and (symbolp function) (fboundp function)))
      (error "Undefined shortcut function ~S." function))
    (funcall function world seat input)))

(defun %shortcut-predicate-p (binding world seat input)
  (let ((predicate (shortcut-binding-predicate binding)))
    (or (null predicate)
        (%call-shortcut-function predicate world seat input))))

(defun %shortcut-candidates (controller input)
  (let ((seen (make-hash-table :test #'eq))
        (candidates nil))
    (labels ((collect-binding (binding)
               (unless (gethash binding seen)
                 (setf (gethash binding seen) t)
                 (push binding candidates))))
      (dolist (binding
               (gethash (ataxia.kernel:key-input-keycode input)
                        (%shortcut-controller-physical-index controller)))
        (collect-binding binding))
      (loop for keysym across (ataxia.kernel:key-input-keysyms input)
            do
        (dolist (binding
                 (gethash (string-upcase keysym)
                          (%shortcut-controller-keysym-index controller)))
          (collect-binding binding))))
    candidates))

(defun %find-shortcut-binding (controller world seat input)
  (let* ((active-modifiers
           (%normalize-shortcut-modifiers
            (ataxia.kernel:key-input-modifiers input)))
         (matches
           (remove-if-not
            (lambda (binding)
              (and (shortcut-binding-enabled-p binding)
                   (%shortcut-modifiers-match-p binding active-modifiers)
                   (%shortcut-predicate-p binding world seat input)))
            (%shortcut-candidates controller input))))
    (when matches
      (let* ((priority (reduce #'max matches
                               :key #'shortcut-binding-priority))
             (winners
               (remove-if-not
                (lambda (binding)
                  (= priority (shortcut-binding-priority binding)))
                matches)))
        (when (cdr winners)
          (error 'shortcut-ambiguity :bindings winners :input input))
        (car winners)))))

(defun %handle-shortcut-press (controller world seat input state token)
  (let ((active (gethash token (%shortcut-seat-state-active state)))
        (repeated-p (gethash token (%shortcut-seat-state-pressed state))))
    (if repeated-p
        (if active
            (progn
              (when (shortcut-binding-repeat-p
                     (%active-shortcut-binding active))
                (%call-shortcut-function
                 (shortcut-binding-press-handler
                  (%active-shortcut-binding active))
                 world seat input))
              (if (%active-shortcut-consume-p active) :consumed :forward))
            :forward)
        (progn
          (setf (gethash token (%shortcut-seat-state-pressed state)) t)
          (let ((binding (%find-shortcut-binding controller world seat input)))
            (if binding
                (progn
                  (%call-shortcut-function
                   (shortcut-binding-press-handler binding) world seat input)
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
          (%call-shortcut-function
           (shortcut-binding-release-handler
            (%active-shortcut-binding active))
           world seat input)
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
