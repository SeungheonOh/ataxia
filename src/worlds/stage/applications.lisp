;;;; Installed applications for the desktop protocol: the assistant and computer
;;;; use list and launch them. Directors keep their own catalog.
;;;;
;;;; Desktop entries are read on a worker thread; the catalog answers from the
;;;; last scan and refreshes in the background, and only a request before the
;;;; first scan finished waits for it. Launching runs `gio launch` on a worker
;;;; too, so process creation never stalls a frame.

(in-package #:ataxia.stage-world)

(defparameter +catalog-lifetime+ 60d0
  "Seconds before a catalog request triggers a background rescan.")

(defvar *catalog* nil "Plists with :ID, :NAME, :DETAIL and :PATH, sorted by name.")
(defvar *catalog-scanned-at* nil)
(defvar *catalog-ready-p* nil "Whether any scan has completed.")
(defvar *catalog-scan* nil "The thread of the latest scan.")
(defvar *catalog-lock* (sb-thread:make-mutex :name "Stage application catalog"))

(defun %desktop-directories ()
  (let ((home (uiop:getenv "XDG_DATA_HOME"))
        (dirs (uiop:getenv "XDG_DATA_DIRS")))
    (remove-duplicates
     (mapcar #'uiop:ensure-directory-pathname
             (remove-if-not #'uiop:absolute-pathname-p
                            (cons (if (plusp (length home))
                                      home
                                      (namestring (merge-pathnames ".local/share/" (user-homedir-pathname))))
                                  (uiop:split-string (if (plusp (length dirs)) dirs "/usr/local/share:/usr/share")
                                                     :separator ":"))))
     :test #'equal :from-end t)))

(defun %read-desktop-entry (path)
  "The [Desktop Entry] group of PATH as an alist, or NIL when unreadable."
  (ignore-errors
   (with-open-file (stream path :external-format :utf-8)
     (loop with inside = nil
           for line = (read-line stream nil nil)
           while line
           if (and (plusp (length line)) (char= (char line 0) #\[))
             do (if inside (loop-finish) (setf inside (string= line "[Desktop Entry]")))
           else if inside
             nconc (let ((equals (position #\= line)))
                     (and equals (list (cons (string-trim " " (subseq line 0 equals))
                                             (string-trim " " (subseq line (1+ equals)))))))))))

(defun %scan-applications ()
  ;; Earlier directories take precedence: a user entry hides a system one with the same id.
  (let ((seen (make-hash-table :test #'equal))
        (entries nil))
    (dolist (directory (%desktop-directories))
      (dolist (path (ignore-errors (directory (merge-pathnames "applications/*.desktop" directory)
                                              :resolve-symlinks nil)))
        (let ((id (pathname-name path)))
          (unless (gethash id seen)
            (setf (gethash id seen) t)
            (let* ((fields (%read-desktop-entry path))
                   (field (lambda (name) (cdr (assoc name fields :test #'string=)))))
              (when (and (equal (funcall field "Type") "Application")
                         (funcall field "Name") (funcall field "Exec")
                         (not (equal (funcall field "Hidden") "true"))
                         (not (equal (funcall field "NoDisplay") "true")))
                (push (list :id id :name (funcall field "Name")
                            :detail (or (funcall field "GenericName") (funcall field "Comment") "")
                            :path (namestring path))
                      entries)))))))
    (sort entries #'string-lessp :key (lambda (entry) (getf entry :name)))))

(defun refresh-application-catalog ()
  "Rescan desktop entries on a worker thread unless the catalog is fresh."
  (sb-thread:with-mutex (*catalog-lock*)
    (unless (and *catalog-scanned-at* (< (- (%now) *catalog-scanned-at*) +catalog-lifetime+))
      (setf *catalog-scanned-at* (%now)
            *catalog-scan* (sb-thread:make-thread
                            (lambda ()
                              (let ((entries (%scan-applications)))
                                (sb-thread:with-mutex (*catalog-lock*)
                                  (setf *catalog* entries *catalog-ready-p* t))))
                            :name "Stage application scan")))))

(defun application-catalog ()
  "Installed applications as plists with :ID, :NAME and :DETAIL. Before the first
scan finished, e.g. when asked right after the World started, waits for it."
  (refresh-application-catalog)
  (unless (sb-thread:with-mutex (*catalog-lock*) *catalog-ready-p*)
    (sb-thread:join-thread *catalog-scan* :default nil))
  (mapcar (lambda (entry) (list :id (getf entry :id) :name (getf entry :name) :detail (getf entry :detail)))
          (sb-thread:with-mutex (*catalog-lock*) *catalog*)))

(defmethod ataxia.world:world-application-catalog ((world stage-world) output)
  (declare (ignore output))
  (application-catalog))

(defmethod ataxia.world:launch-world-application ((world stage-world) output id)
  (declare (ignore output))
  (let ((entry (sb-thread:with-mutex (*catalog-lock*)
                 (find id *catalog* :key (lambda (entry) (getf entry :id)) :test #'equal)))
        (display (ataxia.runtime:runtime-socket-name
                  (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world)))))
    (unless entry (error "Unknown installed application ~S." id))
    (sb-thread:make-thread
     (lambda ()
       (handler-case
           (uiop:wait-process
            (uiop:launch-program (list "env" (format nil "WAYLAND_DISPLAY=~A" display)
                                       "gio" "launch" (getf entry :path))
                                 :output nil :error-output nil))
         (error (cause) (%log "cannot launch ~A: ~A" (getf entry :name) cause))))
     :name "Stage application launch")
    (getf entry :name)))
