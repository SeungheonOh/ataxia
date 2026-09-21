(asdf:defsystem "ataxia-screencast"
  :description "Desktop portal and PipeWire screen sharing with a World-owned RmlUi chooser"
  :depends-on ("ataxia-infinite-world/capture")
  :serial t
  :components ((:file "src/world/screencast/native")
               (:file "src/worlds/infinite/screencast")))
