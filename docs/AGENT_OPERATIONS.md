# Agent Operations

This is the operational entry point for an agent attaching to a running Ataxia
compositor. Ataxia intentionally exposes the live Common Lisp image, but World
and Wayland state still have one owner thread. Follow the guarded paths below.

## Mental model

- **Runtime** bridges wlroots and Common Lisp.
- **Kernel** owns Wayland objects, seats, outputs, protocol mutation, frame
  acquisition, output commits, and World recovery.
- **World** owns placement, interaction policy, animation, damage, rendering,
  overlays, and native UI.
- **SLY control** lets an external agent inspect or modify the live image.

Never retain a World object or World-owned object across World generations.
Retain stable identifiers, re-inspect the active World, and resolve objects
again before each mutation.

## Connect

The compositor normally exposes SLYNK on `localhost:4005`. Inside the VM:

```sh
cd /home/sho/fun/ataxia-world-watchdog
./scripts/ataxia-eval '(ataxia.sly-control:current-kernel)'
```

From outside the VM, forward port `4005` first. The evaluation helper accepts a
single form, standard input, or `--file`. Its socket timeout must be longer than
any event wait performed by Lisp.

## Inspect first

Use `agent-inspect` for reads. The supplied function runs briefly on the
compositor owner thread and receives the current Kernel and World:

```lisp
(ataxia.sly-control:agent-inspect
 (lambda (kernel world)
   (list :world (type-of world)
         :generation (ataxia.kernel:kernel-world-generation kernel)
         :status (ataxia.kernel:kernel-world-status kernel)
         :applications (length (ataxia.kernel:kernel-applications kernel))
         :outputs (length (ataxia.kernel:kernel-outputs kernel))
         :seats (length (ataxia.kernel:kernel-seats kernel)))))
```

Always inspect the World type before using a World-specific package. An
infinite World, tiling World, and rescue World do not promise the same policy
objects or operations.

## Mutate safely

Use `agent-apply` for World changes:

```lisp
(ataxia.sly-control:agent-apply
 (lambda (kernel world)
   (declare (ignore kernel))
   (ataxia.infinite-world:show-notification
    world "The agent is attached" :title "AGENT" :duration 4d0)))
```

`agent-apply` captures the World generation, enters the owner thread, and runs
under the Kernel watchdog. It defaults to a full refresh. Pass
`:refresh :world-managed` only when the called World operation already records
damage and requests the necessary frames.

Do not perform model inference, network access, long computation, sleeps, or
event waiting inside `agent-inspect`, `agent-apply`, widget callbacks, or
`call-in-kernel-thread`. Do that work in the external agent process.

## Create interactive UI

The Infinite World can compile arbitrary Slint source into an ordinary overlay.
Declare every callback the agent needs in both the Slint component and the
`:callbacks` argument:

```lisp
(defparameter *prompt-source*
  "export component AgentPrompt inherits Window {
     background: #e4e4e0;
     callback accept();
     callback reject();
     Text { x: 16px; y: 12px; text: \"Apply the proposed layout?\"; }
     yes := TouchArea {
       x: 16px; y: 50px; width: 100px; height: 40px;
       clicked => { root.accept(); }
     }
     no := TouchArea {
       x: 132px; y: 50px; width: 100px; height: 40px;
       clicked => { root.reject(); }
     }
   }")

(ataxia.sly-control:agent-apply
 (lambda (kernel world)
   (declare (ignore kernel))
   (ataxia.infinite-world:agent-widget-id
    (ataxia.infinite-world:make-agent-widget
     world *prompt-source*
     :component-name "AgentPrompt"
     :x 400d0 :y 220d0 :width 248d0 :height 110d0
     :callbacks '("accept" "reject"))))
 :refresh :world-managed)
```

Keep the returned widget ID rather than depending on a printed CLOS object.
Use `find-agent-widget`, `configure-agent-widget`,
`set-agent-widget-property`, and `remove-agent-widget` inside later
`agent-apply` calls.

## Wait for interaction

After creating UI, the external agent waits on its SLY worker:

```lisp
(ataxia.sly-control:wait-for-agent-events :after 0 :timeout 30)
```

From the VM helper, give the socket a slightly longer timeout:

```sh
./scripts/ataxia-eval --timeout 35 \
  '(ataxia.sly-control:wait-for-agent-events :after 0 :timeout 30)'
```

The compositor thread does not wait. A widget callback only appends a copied
event and wakes sleeping SLY workers. A typical result is:

```lisp
(:generation 4
 :status :events
 :after 0
 :oldest 1
 :latest 1
 :overflow-p nil
 :events ((:sequence 1
           :source 7
           :name "accept"
           :value ""
           :timestamp 1842.51d0)))
```

Use `:latest` as the next `:after` value. Event sequences belong to one World
instance and restart when that World is replaced.

Handle batch status as follows:

- `:events` — process events in sequence order, then wait after `:latest`.
- `:timeout` — no interaction occurred; perform other work or wait again.
- `:closed` — the World was replaced; discard cached World state and inspect the
  new generation.
- `:overflow-p t` — older events left the bounded stream; re-inspect current UI
  state before acting on retained events.

## React to an event

Model inference and planning happen after the wait returns, outside Ataxia.
Apply the chosen result through a new guarded mutation:

```lisp
(ataxia.sly-control:agent-apply
 (lambda (kernel world)
   (declare (ignore kernel))
   (let ((widget (ataxia.infinite-world:find-agent-widget world 7)))
     (when widget
       (ataxia.infinite-world:remove-agent-widget world widget))
     (ataxia.infinite-world:show-notification
      world "Layout accepted" :title "AGENT" :duration 4d0)))
 :expected-generation 4
 :refresh :world-managed)
```

Supplying the generation returned with the event prevents a delayed decision
from mutating a replacement World.

The normal external loop is therefore:

1. inspect the active World and generation;
2. create or update an interactive widget;
3. wait for events after the last sequence;
4. perform reasoning outside the compositor;
5. apply a short generation-checked mutation;
6. wait again.

## Failure and recovery

- A generation mismatch means the World changed. Re-inspect; do not retry with
  stale objects.
- An invalid widget rejected before insertion leaves the current World running.
- A failed or timed-out guarded mutation may cause the watchdog to install the
  rescue World while preserving Runtime and Wayland connections.
- Inspect `kernel-world-status`, `kernel-world-generation`, and
  `kernel-world-last-fault` after an unexpected failure.
- Once definitions are repaired, `ataxia.kernel:restart-world` constructs and
  installs a fresh normal World. Invoke it on the owner thread only.

`call-in-kernel-thread` is an unguarded escape hatch for short emergency or
recovery operations. Normal agent work must use `agent-inspect`, `agent-apply`,
and `wait-for-agent-events`.

## Rules for fresh agents

1. Inspect before assuming the active World type or generation.
2. Never mutate live World or Kernel state directly from a SLY worker.
3. Never block the compositor owner thread.
4. Never cache World-owned objects across generations.
5. Use IDs and copied values at the external boundary.
6. Keep owner-thread operations short and deterministic.
7. Let World helpers manage exact damage when they support it.
8. Treat `call-in-kernel-thread` as recovery machinery, not the normal API.

See `SLY_CONTROL.md` for control-plane details and
`WORLD_WATCHDOG_EXPERIMENT.md` for recovery behavior.
