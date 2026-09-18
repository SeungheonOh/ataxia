;;;; Default fixtures use Metaworld. Portable service tests load only their own systems.
(load (merge-pathnames "system-support.lisp" *load-truename*))
(asdf:load-system "ataxia-metaworld")
