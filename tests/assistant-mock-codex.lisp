;;;; A deterministic local app-server fixture; no model or network is involved.
(require :asdf)
(load (merge-pathnames "../src/world/computer-use/json.lisp" *load-truename*))
(defun obj (&rest entries)
  (let ((h (make-hash-table :test #'equal))) (loop for (k v) on entries by #'cddr do (setf (gethash k h) v)) h))
(defun send-message (message)
  (write-line (ataxia.computer-use.wire:encode message)) (finish-output))
(defun result (id value) (send-message (obj "id" id "result" value)))
(defun event (method params) (send-message (obj "method" method "params" params)))
(defun fixture-model (name effort &optional fast)
  (obj "model" name "displayName" name "defaultReasoningEffort" effort
       "supportedReasoningEfforts" (vector (obj "reasoningEffort" "low") (obj "reasoningEffort" "medium") (obj "reasoningEffort" "high"))
       "serviceTiers" (if fast (vector (obj "id" "priority" "name" "Fast" "description" "Faster replies")) #())))
(loop for line = (read-line *standard-input* nil nil) while line do
  (let* ((message (ataxia.computer-use.wire:decode line :max-depth 32 :max-string 8388608))
         (id (gethash "id" message)) (method (gethash "method" message)))
    (cond
      ((equal method "initialize") (result id (obj "userAgent" "ataxia-test")))
      ((equal method "account/read") (result id (obj "account" (obj "type" "chatgpt") "requiresOpenaiAuth" t)))
      ((equal method "model/list")
       (if (gethash "cursor" (gethash "params" message))
           (result id (obj "data" (vector (fixture-model "fixture-fast" "low" t)) "nextCursor" nil))
           (result id (obj "data" (vector (fixture-model "fixture-default" "medium" t)) "nextCursor" "page2"))))
      ((equal method "thread/start")
       (assert (equal "danger-full-access" (gethash "sandbox" (gethash "params" message))))
       (assert (equal "never" (gethash "approvalPolicy" (gethash "params" message))))
       (assert (eq :false (gethash "ephemeral" (gethash "params" message))))
       (assert (= 3
                  (length (gethash "dynamicTools" (gethash "params" message)))))
       (result id (obj "thread" (obj "id" "fixture-thread") "model" "fixture-default" "reasoningEffort" "medium")))
      ((equal method "thread/resume")
       (assert (equal "fixture-thread" (gethash "threadId" (gethash "params" message))))
       (assert (equal "danger-full-access" (gethash "sandbox" (gethash "params" message))))
       (assert (equal "never" (gethash "approvalPolicy" (gethash "params" message))))
       (assert (gethash "excludeTurns" (gethash "params" message)))
       (result id (obj "thread" (obj "id" "fixture-thread") "model" "fixture-default" "reasoningEffort" "medium")))
      ((equal method "turn/start")
       (let* ((params (gethash "params" message))
              (text (gethash "text" (aref (gethash "input" params) 0))))
         (when (equal text "MODEL:fast")
           (assert (equal "fixture-fast" (gethash "model" params)))
           (assert (equal "low" (gethash "effort" params))))
         (when (equal text "MODEL:default")
           (assert (equal "fixture-default" (gethash "model" params)))
           (assert (equal "medium" (gethash "effort" params))))
         (when (equal text "SETTINGS:high-fast")
           (assert (equal "fixture-default" (gethash "model" params)))
           (assert (equal "high" (gethash "effort" params)))
           (assert (equal "priority" (gethash "serviceTierForTurn" params))))
         (when (equal text "SETTINGS:reset")
           (assert (equal "medium" (gethash "effort" params)))
           (assert (equal "default" (gethash "serviceTierForTurn" params)))))
       (result id (obj "turn" (obj "id" "fixture-turn" "status" "inProgress")))
       (event "turn/started" (obj "threadId" "fixture-thread" "turn" (obj "id" "fixture-turn")))
       (event "turn/plan/updated" (obj "threadId" "fixture-thread" "turnId" "fixture-turn"
          "plan" (vector (obj "step" "Inspect the desktop" "status" "inProgress"))))
       (if (uiop:getenv "ATAXIA_APPROVAL_FIXTURE")
           (send-message (obj "id" 8001 "method" "item/tool/requestUserInput" "params"
             (obj "threadId" "fixture-thread" "turnId" "fixture-turn" "questions"
               (vector (obj "id" "inspect" "header" "Inspect" "question" "Inspect this desktop?"
                            "options" (vector (obj "label" "Inspect" "description" "Read the fixture desktop")))))))
           (send-message (obj "id" 9001 "method" "item/tool/call" "params"
             (obj "threadId" "fixture-thread" "turnId" "fixture-turn" "callId" "fixture-call"
                  "tool" "ataxia_lisp" "arguments" (obj "mode" "inspect" "code" "(type-of world)"))))))
      ((eql id 8001)
       (assert (equalp #("Inspect") (gethash "answers" (gethash "inspect" (gethash "answers" (gethash "result" message))))))
       (send-message (obj "id" 8002 "method" "item/commandExecution/requestApproval" "params"
          (obj "threadId" "fixture-thread" "turnId" "fixture-turn" "command" "fixture-only: no command runs"))))
      ((eql id 8002)
       (assert (equal "accept" (gethash "decision" (gethash "result" message))))
       (send-message (obj "id" 8003 "method" "item/fileChange/requestApproval" "params"
          (obj "threadId" "fixture-thread" "turnId" "fixture-turn"))))
      ((eql id 8003)
       (assert (equal "accept" (gethash "decision" (gethash "result" message))))
       (send-message (obj "id" 8004 "method" "item/permissions/requestApproval" "params"
          (obj "threadId" "fixture-thread" "turnId" "fixture-turn"
               "permissions" (obj "network" (obj "enabled" t))))))
      ((eql id 8004)
       (let ((reply (gethash "result" message)))
         (assert (equal "session" (gethash "scope" reply)))
         (assert (eq t (gethash "enabled" (gethash "network" (gethash "permissions" reply))))))
       (send-message (obj "id" 9001 "method" "item/tool/call" "params"
         (obj "threadId" "fixture-thread" "turnId" "fixture-turn" "callId" "fixture-call"
              "tool" "ataxia_lisp" "arguments" (obj "mode" "inspect" "code" "(type-of world)")))))
      ((eql id 9001)
       (assert (eq t (gethash "success" (gethash "result" message))))
       ;; A retried completed call must return the cached result without executing again.
       (send-message (obj "id" 9002 "method" "item/tool/call" "params"
         (obj "threadId" "fixture-thread" "turnId" "fixture-turn" "callId" "fixture-call"
              "tool" "ataxia_lisp" "arguments" (obj "mode" "inspect" "code" "(type-of world)")))))
      ((eql id 9002)
       (assert (eq t (gethash "success" (gethash "result" message))))
       (event "item/agentMessage/delta" (obj "threadId" "fixture-thread" "turnId" "fixture-turn" "itemId" "reply" "delta" "Checked your desktop. "))
       (event "item/agentMessage/delta" (obj "threadId" "fixture-thread" "turnId" "fixture-turn" "itemId" "reply" "delta" "<b>Safe text</b>"))
       (event "turn/completed" (obj "threadId" "fixture-thread" "turn" (obj "id" "fixture-turn" "status" "completed"))))
      ((equal method "thread/realtime/start")
       (let ((params (gethash "params" message)))
         (assert (equal "v3" (gethash "version" params)))
         (assert (equal "webrtc" (gethash "type" (gethash "transport" params))))
         (assert (equal "fixture-offer" (gethash "sdp" (gethash "transport" params))))
         (assert (eq :false (gethash "clientManagedHandoffs" params))))
       (if (uiop:getenv "ATAXIA_VOICE_FIXTURE")
           (progn
             (result id (obj))
             (event "thread/realtime/started" (obj "threadId" "fixture-thread" "version" "v3"))
             (event "thread/realtime/sdp" (obj "threadId" "fixture-thread" "sdp" "fixture-answer"))
             ;; The sideband carries captions/handoffs, never PCM on WebRTC.
             (event "thread/realtime/transcript/done" (obj "threadId" "fixture-thread" "role" "user" "text" "Voice fixture task"))
             (event "thread/realtime/item/started" (obj "threadId" "fixture-thread" "item"
               (obj "id" "voice-item" "realtimeSessionId" "voice-session" "type" "transcriptSegment" "role" "user" "text" "")))
             (event "thread/realtime/item/transcript/delta" (obj "threadId" "fixture-thread" "itemId" "voice-item" "delta" "Voice fixture"))
             (event "thread/realtime/item/completed" (obj "threadId" "fixture-thread" "item"
               (obj "id" "voice-item" "realtimeSessionId" "voice-session" "type" "transcriptSegment" "role" "user" "text" "Voice fixture task")))
             (event "turn/started" (obj "threadId" "fixture-thread" "turn" (obj "id" "voice-turn")))
             (event "turn/completed" (obj "threadId" "fixture-thread" "turn" (obj "id" "voice-turn" "status" "completed"))))
           (send-message (obj "id" id "error" (obj "code" -32000 "message" "Voice fixture unavailable")))))
      ((equal method "thread/realtime/appendAudio") (error "WebRTC must not forward PCM through the app-server."))
      ((equal method "turn/interrupt") (result id (obj)))
      ((and method id) (result id (obj))))))
