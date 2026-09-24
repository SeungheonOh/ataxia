;;;; Execute a known sequence on a worker; every input still enters World separately.
(in-package #:ataxia.computer-use)

(defparameter +batch-action-fields+
  '(("focus" :window) ("view" :mode :window) ("move" :x :y :duration) ("button" :button :state)
    ("scroll" :x :y) ("key" :key :state :modifiers) ("type" :text) ("paste" :text :format)
    ("launch" :application) ("wait-window" :window :title :app-id :timeout :focus)
    ("wait-stable" :window :settle :timeout)))

(defun %computer-start-batch (world session request)
  (let ((actions (getf request :actions)) (capture (getf request :capture t))
        (settle (bounded-number (getf request :settle .15d0) 0d0 2d0 "settle")))
    (unless (and (vectorp actions) (not (stringp actions)) (<= 1 (length actions) 16))
      (%computer-reject "invalid-batch" "Supply between one and sixteen action objects."))
    (unless (member capture '(t :false))
      (%computer-reject "invalid-batch" "capture must be a boolean."))
    ;; Reject malformed plans before the first input. Target/state checks remain
    ;; at execution time because windows and human ownership can change.
    (loop for action across actions do
          (%computer-validate-request action)
          (let ((fields (assoc (getf action :op) +batch-action-fields+ :test #'equal)))
            (unless fields (%computer-reject "invalid-batch" "Unsupported batch action."))
            (loop for key in action by #'cddr do
                  (unless (or (eq key :op) (member key (cdr fields)))
                    (%computer-reject "invalid-batch" "Unexpected field in a batch action."))))
          (when (equal (getf action :op) "wait-window")
            (%computer-validate-window-wait action))
          (when (equal (getf action :op) "wait-stable")
            (%computer-validate-stable-wait action)))
    (let ((batch (make-computer-batch
                  :session session :actions actions :capture-p (eq capture t) :settle settle
                  :generation (ataxia.kernel:kernel-world-generation (ataxia.kernel:world-kernel world)))))
      (setf (computer-session-batch session) batch)
      batch)))

(defun %computer-batch-check (batch world)
  (let ((session (computer-batch-session batch)))
    (unless (and (eq world (computer-session-world session))
                 (eq batch (computer-session-batch session))
                 (eq :active (computer-session-state session)))
      (%computer-reject "batch-interrupted" "The session was paused, disconnected, or replaced."))
    session))

(defun %computer-batch-call (batch function)
  (ataxia.sly-control:agent-inspect
   (lambda (kernel world)
     (declare (ignore kernel))
     (let ((*computer-running-batch* batch))
       (funcall function world (%computer-batch-check batch world))))
   :expected-generation (computer-batch-generation batch) :timeout 5d0))

(defun %computer-batch-time-left (deadline)
  (let ((remaining (- deadline (monotonic-time))))
    (unless (plusp remaining) (%computer-reject "batch-timeout" "The batch exceeded thirty seconds."))
    remaining))

(defun %computer-batch-wait-input (batch deadline)
  (loop
        for completion = (%computer-batch-call
                             batch (lambda (world session)
                                     (declare (ignore world))
                                     (getf (computer-session-action session) :completion)))
        while completion do
        (unless (sb-thread:wait-on-semaphore completion :timeout (%computer-batch-time-left deadline))
          (%computer-reject "batch-timeout" "Input did not complete before the batch deadline."))))

(defun %computer-action-input-target (session action)
  (let ((op (getf action :op)) (state (%computer-seat-state session)))
    (cond
      ((and (member op '("key" "type" "paste") :test #'equal) (not (equal (getf action :state) "up")))
       (values :keyboard (computer-input-state-focused state)))
      ((and (equal op "move") (%computer-window-view-p session))
       (values :pointer (computer-view-window (computer-session-view session))))
      ((and (member op '("button" "scroll") :test #'equal) (not (equal (getf action :state) "up")))
       (values :pointer (%computer-point-target session))))))

(defun %computer-batch-wait-ready (batch action deadline)
  ;; wl_seat globals and get_keyboard/get_pointer requests are asynchronous.
  ;; Wait on the worker before sending the first event; never borrow another seat.
  (let ((until (min deadline (+ (monotonic-time) 1d0))))
    (loop
     (when (%computer-batch-call
               batch (lambda (world session)
                       (declare (ignore world))
                       (multiple-value-bind (kind target) (%computer-action-input-target session action)
                         (cond
                           ((or (null kind) (null target)) t)
                           ((member kind (%computer-input-capabilities session target)) t)
                           ((>= (monotonic-time) until) (%computer-require-input-ready session target kind))))))
       (return))
     (sleep (min .025d0 (max .001d0 (- until (monotonic-time))))))))

(defun %computer-validate-window-wait (action)
  (unless (or (getf action :window) (getf action :title) (getf action :app-id))
    (%computer-reject "invalid-wait" "wait-window needs window, title, or app-id."))
  (when (getf action :window)
    (unless (typep (getf action :window) '(integer 1 *))
      (%computer-reject "invalid-wait" "window must be an application ID.")))
  (dolist (key '(:title :app-id))
    (when (getf action key) (bounded-string (getf action key) 256 (symbol-name key))))
  (bounded-number (getf action :timeout 10d0) .05d0 20d0 "timeout")
  (unless (member (getf action :focus :false) '(t :false))
    (%computer-reject "invalid-wait" "focus must be a boolean.")))

(defun %computer-batch-wait-window (batch action deadline)
  (let ((until (min deadline (+ (monotonic-time) (getf action :timeout 10d0)))))
    (loop
     (when
         (%computer-batch-call
             batch
           (lambda (world session)
             (let ((matches
                    (remove-if-not
                     (lambda (window)
                       (let ((app (window-application window)))
                         (and (%computer-window-allowed-p session window)
                              (or (null (getf action :window))
                                  (eql (getf action :window) (ataxia.kernel:object-id app)))
                              (or (null (getf action :app-id))
                                  (equal (getf action :app-id) (ataxia.kernel:application-app-id app)))
                              (or (null (getf action :title))
                                  (search (getf action :title) (or (ataxia.kernel:application-title app) "")
                                          :test #'char-equal)))))
                     (world-windows world))))
               (when (and matches (eq t (getf action :focus)))
                 (when (rest matches) (%computer-reject "ambiguous-window" "More than one window matches; narrow the condition."))
                 (%computer-focus session (first matches))
                 (%computer-log session "Focused matching application"))
               (not (null matches)))))
       (return))
     (when (>= (monotonic-time) until) (%computer-reject "wait-timeout" "No visible window matched the condition."))
     ;; This worker waits, never the compositor or the model's next turn.
     (sleep (min .05d0 (max .001d0 (- until (monotonic-time))))))))

(defun %computer-validate-stable-wait (action)
  (when (getf action :window)
    (unless (typep (getf action :window) '(integer 1 *))
      (%computer-reject "invalid-wait" "window must be an application ID.")))
  (let ((settle (bounded-number (getf action :settle .15d0) .016d0 2d0 "settle"))
        (timeout (bounded-number (getf action :timeout 2d0) .05d0 20d0 "timeout")))
    (when (< timeout settle)
      (%computer-reject "invalid-wait" "timeout must be at least as long as settle."))))

(defun %computer-observation-signature (world session window-id prime-p)
  (let* ((windows (remove-if-not (lambda (window) (%computer-window-allowed-p session window))
                                 (world-windows world)))
         (target (if window-id
                     (find window-id windows :key (lambda (window)
                                                    (ataxia.kernel:object-id (window-application window))))
                     (when (%computer-window-view-p session) (%computer-require-window session)))))
    (when (and window-id (null target))
      (%computer-reject "target-blocked" "Choose an application on the approved output."))
    (list
     ;; A separate dialog can appear while its parent stops repainting.
     (mapcar (lambda (window) (ataxia.kernel:object-id (window-application window))) windows)
     (loop for window in (if target (list target) windows)
           for app = (window-application window)
           collect (prog1
                       (list (ataxia.kernel:object-id app) (ataxia.kernel:application-title app)
                             (nth-value 1 (ataxia.kernel:drawable-surfaces app))
                             (%computer-root-bounds window))
                     (when prime-p (%computer-complete-window-frames window)))))))

(defun %computer-batch-wait-stable (batch action deadline &key soft)
  (let* ((started (monotonic-time)) (settle (getf action :settle .15d0))
         (until (min deadline (+ started (getf action :timeout 2d0))))
         (previous nil) (changed-at started) (prime-p t))
    (loop
     (let ((signature (%computer-batch-call
                          batch (lambda (world session)
                                  (%computer-observation-signature world session (getf action :window) prime-p)))))
       (setf prime-p (not (equalp signature previous)))
       (when prime-p (setf previous signature changed-at (monotonic-time))))
     (when (>= (- (monotonic-time) changed-at) settle)
       (return (values t (- (monotonic-time) started))))
     (when (>= (monotonic-time) until)
       (if soft (return (values nil (- (monotonic-time) started)))
           (%computer-reject "wait-timeout" "The application continued updating before the deadline.")))
     ;; This is a bounded worker wait. It never sleeps on the owner thread or
     ;; requests idle output frames; frame callbacks also work offscreen.
     (sleep (min .025d0 (max .001d0 (- until (monotonic-time))))))))

(defun %computer-finish-batch (batch &key (observe t))
  (let ((deadline (+ (monotonic-time) 30d0)) (failure nil) (image nil) (reply nil))
    (unwind-protect
         (handler-case
             (progn
               (loop for action across (computer-batch-actions batch) do
                     (%computer-batch-time-left deadline)
                     (cond
                       ((equal (getf action :op) "wait-window")
                        (%computer-batch-wait-window batch action deadline))
                       ((equal (getf action :op) "wait-stable")
                        (%computer-batch-wait-stable batch action deadline))
                       (t (progn
                            (%computer-batch-wait-ready batch action deadline)
                            (%computer-batch-call
                                batch (lambda (world session)
                                        (request-on-owner
                                         world (append action (list :token (computer-session-token session)
                                                                    :sequence (1+ (computer-session-sequence session)))))))
                            (%computer-batch-wait-input batch deadline))))
                     (incf (computer-batch-completed batch)))
               (when (computer-batch-capture-p batch)
                 (multiple-value-bind (settled waited)
                     (if (plusp (computer-batch-settle batch))
                         (%computer-batch-wait-stable batch (list :settle (computer-batch-settle batch)) deadline :soft t)
                         (values nil 0d0))
                   (let ((ticket (%computer-batch-call
                                     batch (lambda (world session)
                                             (request-on-owner world (list :op "capture" :token (computer-session-token session)
                                                                            :sequence (1+ (computer-session-sequence session))))))))
                     (setf image (append (getf (%computer-finish-capture ticket) :image)
                                         (list :settled (if settled t :false) :wait-seconds waited)))))))
           (computer-use-rejected (cause)
             (setf failure (list :error (%computer-error-code cause) :message (%computer-error-message cause))))
           (error (cause)
             (setf failure (list :error "batch-failed" :message (princ-to-string cause)))))
      (handler-case
          (setf reply
                (ataxia.sly-control:agent-inspect
                 (lambda (kernel world)
                   (declare (ignore kernel))
                   (let ((session (computer-batch-session batch)))
                     (when (eq batch (computer-session-batch session))
                       (setf (computer-session-batch session) nil)
                       (when (and failure (eq :active (computer-session-state session)))
                         (%computer-release session)
                         (%computer-log session "Batch stopped"))
                       (%computer-schedule (%computer-controller world)))
                     (unless (or failure (eq :active (computer-session-state session)))
                       (setf failure (list :error "batch-interrupted" :message "The session was paused or disconnected.")))
                     (append
                      (list :ok (if failure :false t) :session (%computer-session-data session)
                            :completed (computer-batch-completed batch))
                      (if failure
                          (append failure (list :failed-action (when (< (computer-batch-completed batch)
                                                                        (length (computer-batch-actions batch)))
                                                                 (1+ (computer-batch-completed batch)))))
                          (append (when observe (list :windows (%computer-windows session)))
                                  (when image (list :image image)))))))
                 :expected-generation (computer-batch-generation batch) :timeout 5d0))
        (error (cause)
          (setf reply (list :ok :false :error "batch-interrupted" :message (princ-to-string cause)
                            :completed (computer-batch-completed batch))))))
    reply))
