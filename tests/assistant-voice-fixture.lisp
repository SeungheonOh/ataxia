;;;; Substitute the packaged child only; exercise the real framing and lifecycle.
(defvar *assistant-test-voice-mode* nil)
(setf (symbol-function 'ataxia.assistant::%assistant-voice-launch)
      (lambda ()
        (values
         (uiop:launch-program (append (list "python3" "-u" (namestring (asdf:system-relative-pathname "ataxia-assistant" "tests/assistant-voice-host.py")))
                                      (when *assistant-test-voice-mode* (list *assistant-test-voice-mode*)))
                              :input :stream :output :stream :error-output "/dev/null" :if-error-output-exists :append
                              :element-type '(unsigned-byte 8))
         "fixture")))
