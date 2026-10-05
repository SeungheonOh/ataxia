(asdf:defsystem "ataxia-screencast"
  :description "Desktop portal and PipeWire screen sharing with a World-owned HTML chooser"
  :depends-on ("ataxia-screencast/native" "ataxia-infinite-world/capture" "ataxia-web/ui")
  :serial t
  :components ((:file "src/worlds/infinite/screencast")))

(asdf:defsystem "ataxia-screencast/native"
  :description "The portal and PipeWire bridge alone, for Worlds with their own chooser"
  :depends-on ("cffi")
  :components ((:file "src/world/screencast/native")))
