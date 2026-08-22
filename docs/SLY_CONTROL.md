# SLY Control

The infinite World starts SLYNK on `localhost:4005`. SLY receives full access
to the live Lisp image and the current Kernel through:

```lisp
(ataxia.sly-control:current-kernel)
```

SLY worker threads must not mutate World or wlroots state directly. Execute
such work on the compositor owner thread:

```lisp
(ataxia.sly-control:with-kernel-thread (kernel)
  (let* ((world (ataxia.kernel:kernel-world kernel))
         (application (first (ataxia.kernel:kernel-applications kernel)))
         (window
           (ataxia.infinite-world:find-canvas-window world application)))
    (ataxia.infinite-world:set-window-position world window 40d0 40d0)))
```

Connect SLY to port `4005`, or forward the VM-local endpoint first:

```sh
ssh -L 4005:localhost:4005 vm
```

Use `--sly-port N` to select another local port or `--no-sly` to disable the
server. The `slynk` ASDF system must be available in the Lisp source registry.
