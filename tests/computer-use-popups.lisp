(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-computer-use/metaworld")
(in-package #:ataxia.infinite-world)

(let* ((world (make-metaworld :state-file nil))
       (kernel (ataxia.kernel:create-kernel world :backend :headless
                                           :headless-width 1000 :headless-height 760))
       (runtime (ataxia.kernel:kernel-runtime kernel))
       (client nil) (session nil) (ticket nil) (phase 0)
       (log #P"/tmp/ataxia-popup-client.log"))
  (labels ((send (op &rest fields)
             (ataxia.computer-use:request-on-owner world
                                (append (list :op op :token (ataxia.computer-use::computer-session-token session)
                                              :sequence (1+ (ataxia.computer-use::computer-session-sequence session))) fields)))
           (pixel (x y color)
             (let ((offset (* 4 (+ x (* 600 y)))))
               (loop for expected in color for i from offset do
                     (assert (<= (abs (- expected (aref (ataxia.computer-use::computer-capture-pixels ticket) i))) 1)
                             () "Phase ~D pixel ~D,~D: expected ~S, got ~S" phase x y color
                             (subseq (ataxia.computer-use::computer-capture-pixels ticket) offset (+ offset 4))))))
           (take-image (&rest samples)
             (assert (null (ataxia.computer-use::computer-capture-error ticket)))
             (assert (= 600 (ataxia.computer-use::computer-capture-width ticket)))
             (assert (= 360 (ataxia.computer-use::computer-capture-height ticket)))
             (dolist (sample samples) (apply #'pixel sample))
             (ataxia.computer-use::%computer-set-basis session (ataxia.computer-use::computer-capture-bounds ticket) (ataxia.computer-use::computer-capture-root-bounds ticket))
             (setf ticket nil (ataxia.computer-use::computer-session-capture session) nil)))
    (unwind-protect
         (progn
           (ataxia.kernel:start-kernel kernel)
           (ataxia.computer-use:enable world)
           (ataxia.computer-use:request-on-owner world '(:op "connect" :name "Popup test"
                                      :purpose "Verify committed popup placement and input"))
           (setf session (first (ataxia.computer-use::computer-controller-sessions (ataxia.computer-use::%computer-controller world))))
           (ataxia.computer-use:activate-session session)
           (setf client
                 (uiop:launch-program
                  (list "env" (format nil "WAYLAND_DISPLAY=~A" (ataxia.runtime:runtime-socket-name runtime))
                        (namestring (asdf:system-relative-pathname "ataxia-computer-use" "build/computer-use-client"))
                        (namestring log))
                  :output "/tmp/ataxia-popup-client-stdout.log" :error-output :output))
           (let ((timer
                   (ataxia.runtime:add-event-loop-timer
                    runtime
                    (lambda (timer)
                      (case phase
                        (0
                         (assert (= 1 (length (%world-stacking world))))
                         (send "focus" :window (ataxia.kernel:object-id
                                               (canvas-window-application (first (%world-stacking world)))))
                         (send "key" :key "F8"))
                        (1 (setf ticket (send "capture")))
                        (2
                         (take-image '(100 100 (191 96 239 255)) '(200 200 (34 65 91 255)))
                         (send "move" :x 100 :y 100 :duration .016d0))
                        (3 (send "button") (send "key" :key "F9"))
                        (4 (setf ticket (send "capture")))
                        (5
                         (take-image '(300 190 (191 96 239 255)) '(100 100 (55 123 153 255)))
                         (send "move" :x 300 :y 190 :duration .016d0))
                        (6 (send "button") (send "key" :key "F10"))
                        (7 (setf ticket (send "capture")))
                        (8
                         (take-image '(350 200 (64 191 255 255)) '(300 190 (191 96 239 255)))
                         (send "move" :x 350 :y 200 :duration .016d0))
                        (9 (send "button") (send "key" :key "F11"))
                        (10 (setf ticket (send "capture")))
                        (11
                         (take-image '(300 190 (34 65 91 255)) '(350 200 (34 65 91 255)))
                         (let ((events (uiop:read-file-string log)))
                           (dolist (expected '("popup-repositioned 7" "pointer-surface agent-1 popup"
                                               "motion agent-1 40.0 40.0"
                                               "pointer-surface agent-1 nested-popup"
                                               "button-surface agent-1 popup 1"
                                               "button-surface agent-1 nested-popup 1"
                                               "button-surface agent-1 nested-popup 0"))
                             (assert (search expected events) () "Missing ~S in ~A" expected events))
                           ;; A timed move may enter the popup before its final
                           ;; step. Either event can report the exact endpoint.
                           (dolist (position '("75.0 70.0" "30.0 30.0"))
                             (assert (some (lambda (event)
                                             (search (format nil "~A agent-1 ~A" event position) events))
                                           '("pointer-enter" "motion"))
                                     () "Missing final popup position ~A in ~A" position events)))
                         (send "key" :key "F8")
                         (send "move" :x 200 :y 200 :duration .016d0))
                        (12
                         ;; A drag belongs to its pressed surface, even while
                         ;; crossing a popup within the same application.
                         (send "button" :state "down")
                         (send "move" :x 100 :y 100 :duration .016d0))
                        (13 (send "button" :state "up"))
                        (14
                         (let ((events (uiop:read-file-string log)))
                           (assert (search "button-surface agent-1 root 1" events))
                           (assert (search "button-surface agent-1 root 0" events)
                                   () "Root drag lost its release across popup: ~A" events))
                         ;; After release, ordinary hover can enter the popup.
                         (send "move" :x 100 :y 100 :duration .016d0))
                        (15
                         (send "button" :state "down")
                         (send "move" :x 200 :y 200 :duration .016d0))
                        (16 (send "button" :state "up"))
                        (17
                         (let ((events (uiop:read-file-string log)))
                           (assert (search "motion agent-1 175.0 170.0" events)
                                   () "Popup drag lost its coordinate basis: ~A" events)
                           (assert (equal "button-surface agent-1 popup 0"
                                          (find-if (lambda (line) (uiop:string-prefix-p "button-surface " line))
                                                   (uiop:split-string events :separator '(#\Newline)) :from-end t))
                                   () "Popup drag lost its release: ~A" events))
                         (send "move" :x 200 :y 200 :duration .016d0))
                        (18
                         (send "button" :state "down")
                         (send "button" :button "right" :state "down")
                         (send "move" :x 100 :y 100 :duration .016d0))
                        (19
                         (send "button" :state "up")
                         (send "move" :x 200 :y 200 :duration .016d0))
                        (20 (send "move" :x 100 :y 100 :duration .016d0))
                        (21 (send "button" :button "right" :state "up"))
                        (22
                         (let ((lines (uiop:read-file-lines log)))
                           (assert (equal "button-surface agent-1 root 0"
                                          (find-if (lambda (line) (uiop:string-prefix-p "button-surface " line)) lines :from-end t))
                                   () "Releasing one of two buttons ended the drag early: ~S" lines))
                         (send "move" :x 100 :y 100 :duration .016d0))
                        (23
                         (send "button" :state "down")
                         (send "key" :key "F11"))
                        (24
                         ;; A destroyed popup cannot redirect a held release.
                         (send "button" :state "up")
                         (assert (null (ataxia.kernel::%seat-implicit-pointer-grab (ataxia.computer-use::computer-session-seat session))))
                         (assert (zerop (hash-table-count (ataxia.computer-use::computer-input-state-buttons (ataxia.computer-use::%computer-seat-state session)))))
                         (assert (zerop (ataxia.runtime:seat-pointer-button-press-count
                                        (ataxia.kernel:seat-runtime-object (ataxia.computer-use::computer-session-seat session)) 272))))
                        (25
                         (assert (eq :active (ataxia.computer-use::computer-session-state session)))
                         (send "move" :x 200 :y 200 :duration .016d0))
                        (26 (send "button"))
                        (27
                         (ataxia.kernel:request-kernel-stop kernel :checks-complete)))
                      (incf phase)
                      (ataxia.runtime:update-event-loop-timer timer 300)
                      0))))
             (ataxia.runtime:update-event-loop-timer timer 700))
           (ataxia.kernel:run-kernel kernel :run-for 12d0)
           (assert (= 28 phase))
           (assert (eq :running (ataxia.kernel:kernel-world-status kernel)))
           (format t "PASS: initial, repositioned and nested popups render where clicks land; popup removal restores the underlying image; drags retain their surface and release.~%"))
      (ignore-errors (ataxia.computer-use:disable world))
      (dolist (state (%seat-states world)) (%focus-target world state nil))
      (when client (ignore-errors (uiop:terminate-process client)))
      (ataxia.kernel:destroy-kernel kernel :computer-use-popups-test-complete))))
