;;;; Opt-in styling support for compositor-owned RmlUi documents.
(in-package #:ataxia.world.rmlui)

(defvar *shell-fonts-loaded-p* nil)

(defun ensure-shell-fonts ()
  "Load the workstation faces once, on the UI owner thread."
  (unless *shell-fonts-loaded-p*
    (dolist (name '("DejaVuSansMono.ttf" "DejaVuSansMono-Bold.ttf"
                    "DejaVuSansMono-Oblique.ttf" "DejaVuSansMono-BoldOblique.ttf"))
      (load-rmlui-font (merge-pathnames name #P"/usr/share/fonts/truetype/dejavu/")))
    (setf *shell-fonts-loaded-p* t)))

(defun make-shell-rmlui-component (&rest options)
  "Create themed shell UI through the ordinary drawable/interactable adapter.
The document explicitly links theme.rcss; arbitrary application RML is untouched."
  (ensure-shell-fonts)
  (apply #'make-rmlui-component options))
