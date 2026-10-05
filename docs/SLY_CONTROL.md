# SLY Control

Fresh agents should begin with `AGENT_OPERATIONS.md` for the complete
inspect/create/wait/react workflow.

The infinite World starts SLYNK on `localhost:4005`. SLY receives full access
to the live Lisp image and the current Kernel through:

```lisp
(ataxia.sly-control:current-kernel)
```

Inside the VM, `scripts/ataxia-eval` evaluates Lisp without an editor or SLY
client setup:

```sh
cd /home/sho/fun/ataxia-kernel-rebuild
./scripts/ataxia-eval '(+ 20 22)'
./scripts/ataxia-eval \
  '(type-of (ataxia.kernel:kernel-world (ataxia.sly-control:current-kernel)))'
```

It also accepts multiple forms on standard input or from a file:

```sh
printf '(format t "hello~%%")\n(values 7 8)\n' | ./scripts/ataxia-eval
./scripts/ataxia-eval --file /tmp/change-world.lisp
```

Captured output and every returned value are printed directly. Lisp conditions
are written to standard error and produce a nonzero exit status. Use `--host`,
`--port`, `--package`, and `--timeout` when the defaults are unsuitable.

SLY worker threads must not mutate World or wlroots state directly. Use
`agent-inspect` for bounded reads and `agent-apply` for guarded mutations:

```lisp
(ataxia.sly-control:agent-inspect
 (lambda (kernel world)
   (list (type-of world)
         (ataxia.kernel:kernel-world-generation kernel)
         (length (ataxia.kernel:kernel-applications kernel)))))

(ataxia.sly-control:agent-apply
 (lambda (kernel world)
   (let* ((application (first (ataxia.kernel:kernel-applications kernel)))
          (window
            (ataxia.infinite-world:find-canvas-window world application)))
     (ataxia.infinite-world:set-window-position world window 40d0 40d0))))
```

Both operations capture the current World generation before entering the
owner-thread queue and reject stale work after World replacement. Inspection
errors are returned without recovery. Mutation errors and timeouts revoke the
possibly inconsistent World and install the rescue World. `agent-apply`
defaults to a full World refresh; pass `:refresh :world-managed` when the called
World helper already records exact damage.

`call-in-kernel-thread` and `with-kernel-thread` remain available for raw live
experimentation, but started operations through them are not watchdog guarded.

The Infinite World accepts arbitrary HTML widgets and notifications through
the same guarded mutation path:

```lisp
(ataxia.sly-control:agent-apply
 (lambda (kernel world)
   (declare (ignore kernel))
   (ataxia.infinite-world:show-notification
    world "Layout cleanup completed" :title "AGENT" :duration 5d0)))
```

`ataxia.world.web:make-web-widget` accepts HTML source or a local path,
geometry, callback names, and an optional output. `bind-agent-widget-event` records callback values in a bounded
per-widget history readable through `agent-widget-events`. It also publishes to
a bounded World event stream. An agent can wait without blocking the compositor:

```lisp
(ataxia.sly-control:wait-for-agent-events :after 0 :timeout 30)
```

The result contains the World generation, global sequence range, overflow flag,
and events represented as plain property lists. Pass the last received sequence
as `:after` for the next wait. `:closed` means the World was replaced and the
agent must start again with the new generation. Callback handlers remain short
and synchronous. Widgets are ordinary World overlays, so the Kernel and Runtime
remain unaware of their origin.

Connect SLY to port `4005`, or forward the VM-local endpoint first:

```sh
ssh -L 4005:localhost:4005 vm
```

Use `--sly-port N` to select another local port or `--no-sly` to disable the
server. The `slynk` ASDF system must be available in the Lisp source registry.
