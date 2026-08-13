# Gaming preemption

Gaming is this machine's primary workload. Inference is a scavenger that runs on
the GPU while nobody is using it, and it has to get out of the way completely the
moment a game starts. "Out of the way" means the VRAM is actually returned, not
that the workload is merely idle.

## What happens

1. A game is launched through `gamemoderun`, which asks `gamemoded` to enter
   GameMode.
2. `gamemoded` runs the `[custom] start` command from `/etc/gamemode.ini`, which
   is `sudo -n /usr/local/bin/otter-k3s-pause`.
3. That script stops the `k3s` service and then runs `k3s-killall.sh`.
4. Containers die, the Ollama process exits, and the card's VRAM is released.
5. On exit of the last game, `gamemoded` runs `[custom] end`, which starts `k3s`
   again. Flux reconciles the workloads back by itself, so nothing needs to
   remember what was running.

`gamemoded` reference-counts its clients: `start` fires when the first game
registers and `end` when the last one exits, so two games in a row do not stop
and start the cluster twice.

## Why the cluster is stopped rather than scaled down

Scaling the workload to zero looks tidier and does not work. `kustomize-controller`
reconciles a `replicas: 0` back on its next pass, so the scale-down is a fight
with the reconciler rather than a mechanism. Stopping `k3s` takes the reconciler
out along with everything it manages, which is why it holds.

## Why the containers are killed as well

Stopping the `k3s` unit stops the supervisor. It does not reap the containers it
started: their shims keep running, and a container holding the GPU keeps its VRAM
allocated. `k3s-killall.sh` is what tears those down, and it is the step that
actually frees the card. Stopping the service alone would look like it worked
while leaving most of the VRAM in use.

## Why the scripts run under sudo

`gamemoded` runs as the desktop user, and stopping a system service needs root.
The two scripts are root-owned and mode `0755`, and the sudoers rule names those
two paths specifically. Because the account allowed to run them cannot write them,
the rule cannot be turned into arbitrary root access. The rule is validated with
`visudo` when applied, so a malformed entry fails the play instead of locking the
account out of sudo.

## Configuration

`gamemoded` reads `gamemode.ini` from several places, each overriding the last:

```
/usr/share/gamemode/gamemode.ini   shipped defaults
/etc/gamemode.ini                  administrator, and where this hook lives
~/.config/gamemode.ini             user
$PWD/gamemode.ini                  game working directory
```

The files are watched with inotify, so edits take effect without restarting
anything.

Two settings matter here, both in `[custom]`:

- `start` and `end`, the hook itself.
- `script_timeout`, set to 60. The default is 10 seconds and `gamemoded` **kills**
  scripts that exceed it. Draining pods and tearing down shims runs well past 10
  seconds, and a killed pause script leaves the GPU held.

## Gotchas

**A `[custom]` section in `~/.config/gamemode.ini` silently wins.** Only the
`[gpu]` section is restricted to root-owned config locations, so a user-level
`[custom]` block overrides this hook entirely and nothing reports that it did.
Check it before debugging anything else.

**Each game needs the launch option.** In Steam that is `gamemoderun %command%`
per title. Other launchers have a GameMode toggle that can be set as a default.
A game launched without it never registers, so the cluster keeps running and the
GPU stays occupied.

**The hook does not block the game.** The scripts run alongside the launch rather
than before it, so a game can begin allocating VRAM while the cluster is still
shutting down. If that becomes a problem, the lever is a shorter
`terminationGracePeriodSeconds` on the inference workload so its container exits
promptly instead of draining.

## Verifying

```bash
pacman -Q gamemode lib32-gamemode      # installed at all
gamemoded -s                           # daemon answers, D-Bus activation works
systemctl is-active k3s                # expect inactive during a game
rocm-smi --showmeminfo vram --csv      # expect desktop-only usage during a game
```

The honest test is to launch a game with a model resident and watch VRAM fall to
the desktop baseline, then quit and confirm the cluster comes back on its own.

## Files

```
ansible/roles/gaming_preempt/           the role that installs all of this
/etc/gamemode.ini                       [custom] start/end and script_timeout
/etc/sudoers.d/otter-gaming-preempt     the two permitted commands
/usr/local/bin/otter-k3s-pause          stop k3s, then kill containers
/usr/local/bin/otter-k3s-resume         start k3s
```
