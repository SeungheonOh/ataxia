;;;; Web nodes: pages rendered by Chromium inside the scene.
;;;;
;;;; Each web node owns one ataxia-web component. A replacement node with the
;;;; same source adopts it, so reloading the world keeps its pages running.
;;;; The component is an ordinary drawable and interactable: its frames are
;;;; drawn like a client's surfaces, its damage is projected through the node's
;;;; transform, and pointer and keyboard input reach it like a window's. A page
;;;; that no output shows is hidden, so Chromium stops painting it, and its
;;;; raster scale follows its on-screen scale once that settles. Pages talk to
;;;; the director with `ataxia.postMessage("stage", {name, value})` and receive
;;;; the node's `data` as an "ataxia-message" event named "props".

(in-package #:ataxia.stage-world)

(defparameter +web-message-name+ "stage"
  "Page message carrying {name, value} on to the director.")
(defparameter +web-scale-range+ '(0.5d0 . 3d0)
  "Raster scales a page may use, whatever its zoom.")

(defun %web-source-arguments (source)
  "Component arguments for SOURCE: a URL, an HTML file, or a built app directory."
  (cond ((search "://" source) (list :url source))
        ((uiop:directory-exists-p source) (list :asset-root source))
        (t (list :source-path source))))

(defun %web-size (node)
  "CSS size the page is laid out at: the node's size once any animation settles."
  (flet ((extent (key default)
           (max 1d0 (min 8192d0 (or (node-target node key) default)))))
    (values (extent :width 640d0) (extent :height 360d0))))

(defun %web-outputs (world web)
  (or (stage-web-outputs web) (%outputs world)))

(defun %create-web (world node)
  (let* ((source (node-prop node :src))
         (web nil)
         (component
           (handler-case
               (multiple-value-bind (width height) (%web-size node)
                 (apply #'ataxia.world.web:make-web-component
                        :world world :width width :height height
                        :scale (reduce #'max (%outputs world)
                                       :key (lambda (stage-output)
                                              (ataxia.kernel:output-scale
                                               (stage-output-output stage-output)))
                                       :initial-value 1d0)
                        :invalidator (lambda (component)
                                       (declare (ignore component))
                                       (when web (%request-frames world (%web-outputs world web))))
                        (%web-source-arguments source)))
             (error (cause)
               ;; Not retried until the node names another source.
               (setf (gethash node (%failed-pages world)) source)
               (%emit-event world node :error :message (princ-to-string cause))
               nil))))
    (when component
      (setf web (%make-stage-web source component)
            (stage-web-node web) node
            (stage-web-revision web) (node-prop node :revision))
      ;; The web engine calls back from its own event sources.
      (flet ((on (name function)
               (ataxia.world:ui-set-callback component name
                                             (%guarded world :stage-web
                                                       (lambda (component value)
                                                         (declare (ignore component))
                                                         (funcall function value))))))
        (on "load" (lambda (value)
                     (declare (ignore value))
                     (setf (stage-web-loaded-p web) t
                           (stage-web-data web) nil)
                     (%sync-web web)
                     (%emit-event world (stage-web-node web) :load)))
        (on "error" (lambda (message)
                      (%emit-event world (stage-web-node web) :error :message message)))
        (on +web-message-name+ (lambda (payload)
                                 (%emit-event world (stage-web-node web) :message
                                              :payload payload))))
      (push web (%webs world))
      web)))

(defun %sync-web (web)
  "Bring WEB's page size, props and revision up to its node's declarations."
  (let ((node (stage-web-node web))
        (component (stage-web-component web)))
    (multiple-value-bind (width height) (%web-size node)
      (ataxia.world.web:resize-web-component component width height))
    (let ((revision (node-prop node :revision)))
      (unless (eql revision (stage-web-revision web))
        (setf (stage-web-revision web) revision
              (stage-web-loaded-p web) nil)
        (ataxia.world.web:evaluate-web-javascript component "location.reload()")))
    (let ((data (node-prop node :data)))
      (when (and data (stage-web-loaded-p web) (not (equal data (stage-web-data web))))
        (setf (stage-web-data web) data)
        (ataxia.world.web:post-web-message component "props" data)))))

(defun %destroy-web (world web)
  (let ((component (stage-web-component web))
        (node (stage-web-node web)))
    (setf (%webs world) (remove web (%webs world)))
    (%invalidate-display world)
    (when (eq web (stage-node-cache node))
      (setf (stage-node-cache node) nil))
    (%forget-pointer-client world component)
    (dolist (seat-state (%seat-states world))
      (when (eq web (stage-seat-focused-panel seat-state))
        (focus-panel world seat-state nil)))
    (dolist (stage-output (%outputs world))
      (remhash web (stage-output-window-transforms stage-output)))
    (%call-with-gl world (lambda () (ataxia.kernel:drawable-detach-graphics component)))
    (ataxia.world:ui-destroy component)))

(defun refresh-web-nodes (world nodes)
  "Give every web node in NODES its page after a commit. Pages of nodes that left
the scene go to new nodes with the same source; the rest are destroyed."
  (let ((orphans (remove-if-not (lambda (web) (eq :dead (stage-node-state (stage-web-node web))))
                                (%webs world))))
    (dolist (node nodes)
      (let ((web (stage-node-cache node))
            (source (node-prop node :src)))
        (when (and web (not (equal source (stage-web-source web))))
          (%destroy-web world web)
          (setf web nil))
        (when (and source (null web) (not (equal source (gethash node (%failed-pages world)))))
          (let ((orphan (find source orphans :key #'stage-web-source :test #'equal)))
            (setf web (if orphan
                          (progn (setf orphans (remove orphan orphans)
                                       (stage-web-node orphan) node)
                                 orphan)
                          (%create-web world node))
                  (stage-node-cache node) web)))
        (when web
          (%sync-web web)
          (%sync-web-auto-focus world web node))))
    (mapc (lambda (web) (%destroy-web world web)) orphans)))

(defun %sync-web-auto-focus (world web node)
  "An autoFocus page takes the keyboard each time it appears and gives it back
when hidden, so a page kept mounted can be shown and hidden like a launcher."
  (let ((seat-state (%default-seat-state world))
        (shown-p (and (node-prop node :visible) (plusp (node-target node :opacity)))))
    (cond ((not shown-p)
           (setf (stage-web-auto-focused-p web) nil)
           (when (and seat-state (eq web (stage-seat-focused-panel seat-state)))
             (focus-panel world seat-state nil)))
          ((and (node-prop node :auto-focus) (not (stage-web-auto-focused-p web)))
           (setf (stage-web-auto-focused-p web) t)
           (when seat-state (focus-panel world seat-state web))))))

(defun sweep-webs (world)
  "Destroy pages whose nodes finished leaving the scene."
  (dolist (web (%webs world))
    (when (eq (stage-node-state (stage-web-node web)) :dead)
      (%destroy-web world web))))

(defun destroy-webs (world)
  (mapc (lambda (web) (%destroy-web world web)) (%webs world)))

(defun detach-web-graphics (world)
  (dolist (web (%webs world))
    (ataxia.kernel:drawable-detach-graphics (stage-web-component web))))

(defun prepare-webs (world stage-output)
  "Upload new page frames for STAGE-OUTPUT and damage what changed wherever they show."
  (dolist (web (%webs world))
    (when (member stage-output (stage-web-outputs web))
      (let ((damage (ataxia.kernel:drawable-prepare-frame (stage-web-component web))))
        (when damage
          ;; A new frame comes with new surface records for the items to draw.
          (%invalidate-display world)
          (%damage-content world web
                           ;; Whole CSS pixels covering each fractional rectangle.
                           (mapcar (lambda (rectangle)
                                     (let ((x (floor (ataxia.world:rectangle-x rectangle)))
                                           (y (floor (ataxia.world:rectangle-y rectangle))))
                                       (ataxia.kernel:make-frame-damage-rectangle
                                        x y
                                        (- (ceiling (ataxia.world:rectangle-right rectangle)) x)
                                        (- (ceiling (ataxia.world:rectangle-bottom rectangle)) y))))
                                   damage)))))))

(defun sync-web-presence (world stage-output presented)
  "Record which pages STAGE-OUTPUT's frame showed; hide pages no output shows and
move settled pages to the raster scale they are seen at."
  (dolist (web (%webs world))
    (let ((component (stage-web-component web)))
      (setf (stage-web-outputs web)
            (if (gethash web presented)
                (adjoin stage-output (stage-web-outputs web))
                (remove stage-output (stage-web-outputs web))))
      (ataxia.world.web:set-web-visible component (stage-web-outputs web))
      ;; A page on several outputs rasters for the sharpest of them.
      (let ((wanted (loop for (output scale) on (stage-web-wanted-scales web) by #'cddr
                          when (member output (stage-web-outputs web)) maximize scale))
            (current (ataxia.world.web:web-component-scale component)))
        (when (and (plusp wanted) (> (abs (- wanted current)) (* 0.15d0 current)))
          (ataxia.world.web:resize-web-component
           component (ataxia.world.web:web-component-width component)
           (ataxia.world.web:web-component-height component)
           :scale wanted))))))

(defun focus-panel (world seat-state panel)
  "Give PANEL, a page or an overlay, the keyboard; NIL returns it to the focused window."
  (unless (eq panel (stage-seat-focused-panel seat-state))
    (setf (stage-seat-focused-panel seat-state) panel)
    (%sync-keyboard world seat-state)))

(defmethod emit-content ((kind (eql :web)) context node transform opacity screen-inverse
                         parent-inverse)
  (let ((web (stage-node-cache node))
        (world (display-context-world context)))
    (multiple-value-bind (width height) (%node-size world node)
      (when (and web (plusp width) (plusp height))
        (let* ((component (stage-web-component web))
               (radius (%emit-decorations context node transform width height opacity))
               (content (make-affine (/ width (ataxia.world.web:web-component-width component)) 0 0
                                     (/ height (ataxia.world.web:web-component-height component))
                                     0 0))
               (box (affine-rectangle-bounds transform 0 0 width height))
               (screen (if (display-context-clip context)
                           (ataxia.world:rectangle-intersection (display-context-clip context)
                                                                (display-context-bounds context))
                           (display-context-bounds context))))
          ;; Presence follows the box, not the frames, so a page shows up as soon
          ;; as its first frame arrives.
          (when (and screen (ataxia.world:rectangle-intersection box screen))
            (setf (gethash web (display-context-presented context)) t)
            (push (affine-multiply transform content)
                  (gethash web (stage-output-window-transforms
                                (display-context-stage-output context))))
            (when (display-context-raster-scales context)
              (multiple-value-bind (scale changing-p)
                  (%scale-change context node (affine-scale-factor transform))
                (unless changing-p
                  (setf (getf (stage-web-wanted-scales web) (display-context-stage-output context))
                        (max (car +web-scale-range+)
                             (min (cdr +web-scale-range+)
                                  (* scale (/ width (ataxia.world.web:web-component-width
                                                     component))))))))))
          (loop for surface across (ataxia.kernel:drawable-surfaces component)
                for index from 0
                do (%emit-window-surface context node transform content surface index
                                         width height radius opacity 0d0))
          (when (node-prop node :interactive)
            (%add-hit context node screen-inverse parent-inverse width height
                      :client component :content (affine-invert content)
                      :content-bounds (ataxia.world:make-rectangle
                                       0 0 (ataxia.world.web:web-component-width component)
                                       (ataxia.world.web:web-component-height component)))))))))
