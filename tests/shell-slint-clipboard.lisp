(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-rmlui/status-bar")
(defpackage #:ataxia.test.slint-clipboard
  (:use #:cl #:ataxia.world)
  (:local-nicknames (#:shell #:ataxia.world.shell) (#:slint #:ataxia.world.slint)))
(in-package #:ataxia.test.slint-clipboard)
(let* ((world (ataxia.metaworld:make-metaworld :state-file nil))
       (kernel (ataxia.kernel:create-kernel world :backend :headless :headless-width 1100 :headless-height 800))
       (widget nil) (component nil) (seat nil) (service nil) (phase 0) (edited nil))
  (labels ((key (code name state &optional modifiers)
             (ataxia.kernel:interactable-key-event component world seat
               (ataxia.kernel:make-key-input :keycode code :keysyms (vector name) :state state :modifiers modifiers)))
           (control (pressed)
             (key 29 "Control_L" (if pressed :pressed :released))
             (ataxia.kernel:interactable-key-event component world seat
               (ataxia.kernel:make-modifiers-input :depressed (if pressed 4 0) :latched 0 :locked 0 :group 0
                                                  :names (when pressed '(:control)))))
           (chord (code name)
             (key code name :pressed '(:control)) (key code name :released '(:control))))
    (unwind-protect
         (progn
           (ataxia.kernel:start-kernel kernel)
           (shell:enable-rmlui-status-bar world :system-controls-p nil
             :power-backend (lambda (kind value) (declare (ignore kind value)) nil))
           (setf service (world-service world :shell)
                 (shell::shell-service-clipboard service) (make-hash-table :test #'eq)
                 seat (first (world-seats world))
                 widget (create-agent-widget 'agent-widget world
                          "export component ClipboardTest inherits Window { width: 500px; height: 80px; in-out property<string> text: \"Slint editor · λ🙂\"; callback changed(string); forward-focus: editor; editor := TextInput { width:parent.width; height:parent.height; text <=> root.text; edited => { root.changed(self.text); } } }"
                          :component-factory #'slint:make-slint-component :width 500d0 :height 80d0 :output (first (world-outputs world)))
                 component (overlay-component widget))
           (bind-agent-widget-event widget "changed" (lambda (widget event) (declare (ignore widget)) (setf edited (agent-widget-event-value event))))
           (focus-world-target world seat widget)
           (let ((timer (ataxia.runtime:add-event-loop-timer (ataxia.kernel:kernel-runtime kernel)
                          (lambda (source)
                            (case phase
                              (0
                               (control t) (chord 30 "a") (chord 46 "c")
                               (assert (equal "Slint editor · λ🙂" (shell::clipboard-seat-text (shell::%clipboard-seat service seat))))
                               ;; Force a Wayland pipe read, then release Ctrl
                               ;; before the asynchronous response reaches Slint.
                               (ataxia.runtime:seat-set-clipboard-text (ataxia.kernel:seat-runtime-object seat) "Wayland → Slint · λ🙂")
                               (setf (shell::clipboard-seat-ready (shell::%clipboard-seat service seat)) nil)
                               (shell::%clipboard-begin world service seat (shell::%clipboard-seat service seat))
                               (chord 47 "v") (control nil)
                               (setf phase 1))
                              (1 (when edited
                                   (assert (equal "Wayland → Slint · λ🙂" edited))
                                   (setf phase 2))))
                            (when (< phase 2) (ataxia.runtime:update-event-loop-timer source 100)) 0))))
             (ataxia.runtime:update-event-loop-timer timer 250))
           (ataxia.kernel:run-kernel kernel :run-for 2d0)
           (assert (= phase 2))
           (format t "PASS: Slint copy to Wayland and asynchronous paste after modifier release, with Unicode and selection replacement.~%"))
      (when widget
        (ignore-errors (focus-world-target world seat nil) (remove-agent-widget world widget)))
      (ataxia.kernel:destroy-kernel kernel :slint-clipboard-test))))
