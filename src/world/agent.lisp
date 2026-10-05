;;;; Lisp operations for application contents. World policy uses ataxia.world.
;;;; Reuse native seat/capture machinery; no JSON transport or desktop snapshots.
(defpackage #:ataxia.agent
  (:use #:cl #:ataxia.world)
  (:local-nicknames (#:cu #:ataxia.computer-use))
  (:export #:call-with-world #:input-session
           #:capture-window #:click #:move-pointer #:button #:scroll
           #:press-key #:type-text #:paste #:disconnect))
(in-package #:ataxia.agent)

(defvar *image-sink* nil)

(defgeneric call-with-world (agent function)
  (:documentation "Call FUNCTION with the current World on its owner thread. Hosts enforce their task lifetime here."))
(defgeneric input-session (agent world)
  (:documentation "Obtain the agent's native input resources on the owner. Never resume paused resources implicitly."))

(defun %named-session (world name &optional create)
  (cu:bounded-string name 34 "agent name")
  (let* ((registry (or (world-service world :lisp-agents)
                       (when create (attach-world-service world :lisp-agents (make-hash-table :test #'equal)))))
         (known (and registry (gethash name registry))))
    (when (or (eq known :closed)
              (and known (eq :closed (cu:computer-session-state known))))
      ;; The native backend drops closed records when another session connects.
      ;; Keep only a tombstone so an old task name cannot silently reopen input.
      (setf (gethash name registry) :closed)
      (when create (error "This agent is disconnected. Do not reopen it implicitly."))
      (return-from %named-session nil))
    (or known
        (when create
          (maphash (lambda (key session)
                     (when (and (not (eq session :closed)) (eq :closed (cu:computer-session-state session)))
                       (setf (gethash key registry) :closed))) registry)
          (cu:enable world)
          (setf (gethash name registry)
                (cu:connect-session world (concatenate 'string "Lisp: " name) "Direct Lisp application interaction"
                                    (or (first (world-outputs world)) (error "No output is available."))))))))

(defmethod call-with-world ((agent string) function)
  (ataxia.sly-control:agent-inspect
   (lambda (kernel world)
     (declare (ignore kernel))
     (funcall function world)) :timeout 5d0))

(defmethod input-session ((agent string) world)
  (let ((session (%named-session world agent t)))
    (unless (eq :active (cu:computer-session-state session))
      (error "This agent is paused or disconnected. Wait for the user to Resume."))
    session))

(defun %perform (agent window actions &key capture (settle .05d0))
  "Run a short native sequence; block only the calling worker, never the owner."
  (let* ((caller sb-thread:*current-thread*)
         (batch
           (call-with-world agent
             (lambda (world)
               (when (eq caller sb-thread:*current-thread*)
                 (error "Application input/capture waits for clients. Use Lisp worker mode."))
               (let ((session (input-session agent world)))
                 (when (or (cu::computer-session-batch session)
                           (cu::computer-session-action session)
                           (cu::computer-session-capture session))
                   (error "This agent has an operation in progress. Wait for it to finish."))
                 (cu::%computer-start-batch
                  world session
                  (list :actions (concatenate 'vector
                                    (vector (list :op "view" :mode "window" :window window)) actions)
                        :capture (if capture t :false) :settle (if capture settle 0d0)))))))
         (result (cu::%computer-finish-batch batch :observe nil)))
    (unless (eq t (getf result :ok))
      (error "Application operation stopped after ~D actions: ~A (~A). Inspect before retrying."
             (getf result :completed 0) (getf result :message) (getf result :error)))
    (if capture
        (let ((image (getf result :image)))
          (when *image-sink* (funcall *image-sink* image))
          image)
        t)))

(defun capture-window (agent window &key (settle .05d0))
  "Capture this application's surfaces/popups, even offscreen. Return PNG metadata.
The embedded host also emits the image. Coordinates in subsequent input refer
to this image; recapture after resize. Waits on the worker, never the owner."
  (%perform agent window #() :capture t :settle settle))

(defun click (agent window x y &key (button :left))
  "Click image-local X/Y without moving human focus or a monitor camera."
  (%perform agent window (vector (list :op "move" :x x :y y :duration .016d0)
                                (list :op "button" :button (string-downcase button) :state "click"))))

(defun move-pointer (agent window x y &key (duration .016d0))
  (%perform agent window (vector (list :op "move" :x x :y y :duration duration))))

(defun button (agent window button state)
  "BUTTON is :LEFT/:RIGHT/:MIDDLE; STATE is :DOWN/:UP/:CLICK. Release held input promptly."
  (%perform agent window (vector (list :op "button" :button (string-downcase button)
                                      :state (string-downcase state)))))

(defun scroll (agent window &key (x 0) (y 0))
  (%perform agent window (vector (list :op "scroll" :x x :y y))))

(defun press-key (agent window key &key modifiers (state :tap))
  "Use XKB base key names: n with (Control_L) for Ctrl+N; Return for Enter."
  (%perform agent window (vector (list :op "key" :key key :modifiers modifiers
                                      :state (string-downcase state)))))

(defun type-text (agent window text)
  "Type up to 256 characters using the agent keyboard. Use PASTE for longer text."
  (%perform agent window (vector (list :op "type" :text text))))

(defun paste (agent window text &key (format :text))
  "Paste up to 16,000 characters using the agent's clipboard; preserve the human clipboard."
  (%perform agent window (vector (list :op "paste" :text text :format (string-downcase format)))))

(defgeneric disconnect (agent)
  (:documentation "Release native resources without allocating any. Closed named agents are not implicitly reopened."))

(defmethod disconnect ((agent string))
  (call-with-world agent
    (lambda (world)
      (let ((session (%named-session world agent)))
        (when session (cu:close-session session "Lisp agent disconnected")))))
  t)
