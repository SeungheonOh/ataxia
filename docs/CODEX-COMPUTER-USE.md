# Ataxia agent interface

Agents use Lisp for both World control and application interaction. The embedded
assistant exposes `ataxia_lisp`, plus two RML preview creation/update tools.
It advertises no CUA observation, input, window, viewport or arrangement tools.
The external agent uses SLY directly:

```sh
./scripts/ataxia-eval --world '(ataxia.world:world-desktop-state world)'
./scripts/ataxia-eval --agent editing '(ataxia.agent:capture-window agent 42)'
```

Replace 42 with an observed window ID. The first call runs briefly on the owner;
the second waits for capture on the SLY worker and prints a private PNG path.
Use the image-viewing tool to inspect it. Embedded captures emit images directly.
See the [agent skill](../skills/ataxia-computer-use/SKILL.md) and
[Lisp API examples](../skills/ataxia-computer-use/references/lisp.md).

`--world` binds WORLD/KERNEL and adds no repaint beyond the called World API's
own damage. `--apply` also requests a full refresh. Both execute for at most
250 ms; compile/read happens off-thread. Unflagged evaluation stays on the SLY
worker for application operations, files and event waits. All forms bind AGENT
from `--agent`; use one stable name per independent task.

The reusable `ataxia-agent` system depends on the portable native input/capture
service, not the assistant or Metaworld. Its application functions enter the
owner queue and wait on the calling worker. They reuse native seats, popup-aware
coordinate mapping, image invalidation, held-input cleanup and human takeover.
Input results are compact and do not collect the desktop inventory. Captures
are explicit. No kernel, runtime or native changes implement this interface.

Lisp provides full access. Mode choices are scheduling/refresh choices, not
permission tiers. Pause/Stop remain human controls. Named native resources are
allocated lazily, have no per-frame polling, and are released with
`(ataxia.agent:disconnect agent)` or the embedded task's normal lifecycle.

The agent interface has no browser DOM or accessibility-tree API; applications,
including browsers, are operated through their own window images and native
input. The older JavaScript SDK remains a compatibility library, documented in
[CUA API](CUA-API.md); it is not registered as an agent tool or used by the skill.

`make test-assistant` exercises direct SLY and embedded Lisp, plain Infinite World
and Metaworld, real native input/capture, multiple emitted images, Pause, teardown
and idle behavior. `make test-computer-use` covers the shared native backend.
