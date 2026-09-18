;;;; Compatibility for callers of the former Infinite World shell entry points.
(in-package #:ataxia.infinite-world)
(eval-when (:compile-toplevel :load-toplevel :execute)
  (import '(ataxia.world.shell:enable-rmlui-status-bar ataxia.world.shell:disable-rmlui-status-bar))
  (export '(enable-rmlui-status-bar disable-rmlui-status-bar)))
