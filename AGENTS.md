# jotunheim

One repo, one machine: **otter**, a gaming workstation (CachyOS, Radeon 7900 XTX
24 GB, 64 GB RAM) that serves opportunistic LLM inference while it is idle. It
runs a single-node k3s cluster, also called `otter`, reconciled by an in-cluster
Flux from this repo.

This repo holds **both halves** of the machine — `ansible/` for the host and a
Flux manifest tree for the workloads — so one clone rebuilds it end to end.

## Self-contained by construction

Gaming is the primary workload and always wins; inference is the scavenger. The
box runs games and mods, so it is treated as the least-trusted machine it talks
to anything from. Two rules follow, and both are load-bearing:

- **Everything about this machine lives here.** Do not factor host config,
  manifests or roles out into a shared repository, and do not add a dependency on
  one. Genuinely common bits get **copied** in — the cost (a fix elsewhere does
  not propagate) is accepted deliberately, because one clone has to be the
  complete description of the machine.
- **Credentials are outbound-only and read-only.** This machine holds exactly one
  credential: a read-only, path-scoped Vault token. This repo is public, so Flux
  clones it anonymously over HTTPS and there is no git credential to steal — keep
  it that way rather than reintroducing a deploy key. Never add a write
  credential, a credential for another repository, or a kubeconfig for another
  cluster, and never expose an inbound path that lets something outside drive
  this cluster. Full compromise of the box must yield one Vault path and nothing
  else.

  It follows that **nothing secret may be committed here**, in either half. Every
  secret comes from Vault at runtime; the Vault token itself is the one exception
  and lives `ansible-vault`-encrypted in `group_vars`.

  **Known exception: `mogenius-operator`.** It holds a second credential (its API
  key) and maintains outbound websockets to `mogenius.com` that let the platform
  drive this cluster. That is remote control by an external service, which the
  paragraph above otherwise rules out. It is accepted deliberately: a machine that
  is up only intermittently needs somewhere its state is visible, or nobody
  notices it has been down for a week. It is the boundary's one hole, so do not
  treat it as precedent for adding others.

## Layout

```
ansible/                            host config, day-0 (see below)
clusters/otter/                     the two Flux Kustomizations: infrastructure, apps
infrastructure/<component>/         cluster services (external-secrets, amd-device-plugin, ...)
apps/<component>/                   workloads (ollama, the bearer-token proxy)
```

**One directory per component**, named after the component, holding everything that
belongs to it. Not grouped by kind, and not split into `controllers/`+`configs/`
stages — those put one component's pieces in three places.

**Adding a component is one line**: a directory with its own `kustomization.yaml`,
plus its name in `infrastructure/kustomization.yaml` or `apps/kustomization.yaml`.
Kustomize recurses into it from there. Do **not** add a Flux `Kustomization` per
component — the ones in `clusters/otter/` already cover every directory.

The rule that shapes the layers: **a CR whose CRD is installed by a chart in this
repo cannot be in the same build as that chart.** `kustomize-controller` aborts
the whole apply at the first object the API server does not recognise, and it
aborts before reaching the `HelmRelease` that would install the CRD — so the retry
hits the same error forever. This deadlocks; it does not converge, and
`retryInterval` does not save it.

`external-secrets` is therefore its own layer, ahead of everything, because
`ExternalSecret` and `ClusterSecretStore` are its CRDs and components use them
freely. `infrastructure/kustomization.yaml` deliberately does not list it. The
chain is:

```
external-secrets → external-secrets-stores → infrastructure → apps
```

Anything a component needs is available by the time `infrastructure` runs, so a
new component is still just a directory plus one line. Only add another layer if
a component ships CRDs that a *different* component's CRs consume.

Note this puts `rbac` behind `external-secrets`. Acceptable: the break-glass path
is the root-owned kubeconfig on the box, not the OIDC bindings.

The root `Kustomization`'s `path` is scoped to the manifest subtree.
`kustomize-controller` must never walk `ansible/`.

## Conventions

### Manifest layout

**One YAML resource per file**, named after the resource it holds. No
multi-document `---` files.

Files carrying a chart or image version get the **`.fluxcd.yaml`** extension —
that is what Renovate matches on, and it sees nothing else. A `HelmRelease` and
the `HelmRepository` it sources from must _both_ use it, or the chart's registry
cannot be resolved and the release goes untracked.

### Flux

Controllers are trimmed to `source-controller`, `kustomize-controller` and
`helm-controller`. Do not add `notification-controller` or the image-automation
controllers — nothing here has a job for them.

Bootstrap is `flux install` plus an Ansible-applied `GitRepository` and root
`Kustomization` — deliberately **not** `flux bootstrap`, which commits the
install manifests back and would need a write credential.

Reconcile intervals are sized in minutes. The machine is off most of the day and
nothing on it is latency-sensitive, so drift checks (`HelmRelease`) sit at `1h`.

**Sources are the exception: `HelmRepository` polls at `10m`.** A failed chart
pull retries on its source's interval, and that retry is the only path back — the
`remediation.retries` on a release covers install failures, which happen later. At
`1h`, one transient pull error outlasts a whole uptime window and holds every
dependent layer behind it. Polling a source is cheap; being stuck is not.

### Pod Security

New namespaces are `pod-security.kubernetes.io/enforce: restricted` — **always**.
Only relax below `restricted` if testing actually proves it cannot work. The AMD
device plugin DaemonSet is the expected exception; workload pods are not.

### Secrets

Secrets come from Vault via external-secrets. The `ClusterSecretStore` targets
`https://vault.derwitt.site`, which presents a publicly-trusted cert, so it needs
no `caProvider`. The ESO Vault token Secret itself is bootstrapped by Ansible —
chicken-and-egg, nothing in the cluster can fetch it yet.

Availability here is deliberately lax — single replicas, no failover, prefer the
frugal option over the resilient one. The machine is off most of the day by
design, so resilience buys nothing. **Security is the
exception and is never relaxed**: `restricted` pod-security, non-root, dropped
capabilities, secrets from Vault.

### Endpoint auth

Ollama has no auth of its own and must never listen on the LAN directly. The
bearer-token reverse proxy in front of its Service is what gets exposed, and it
stays in-cluster so it is GitOps-managed rather than hand-rolled host config.

### Images

Reference images by **FQDN**. **Never** use Bitnami images.

## Ansible

`ansible/` owns day-0: k3s, `flux install` and the two sync objects, the deploy
key, the Vault token Secret, `nftables`, the gamemode preempt hook, WoL and idle
auto-suspend. Flux owns day-2.

- Inventory is a single host, `localhost` — the playbooks run **on otter**.
  `ansible.cfg` sets it as the default inventory.
- `hack/setup-venv.sh` creates `.venv` and installs Galaxy content into the
  gitignored `.ansible/` cache.
- Secret material in `group_vars` is `ansible-vault`-encrypted in place
  (`ansible-vault encrypt_string --stdin-name <var>`). Never commit it in the
  clear, and mark the tasks that consume it `no_log: true`.
- **Never set `become: true` at play level "just in case."** Scope it per-task.
  The same applies to `- role:` entries: call-site `become` escalates every task
  inside the role, not just the ones that need it.

### Gaming preempts by stopping k3s

The gamemode hook stops k3s wholesale. It must **not** scale workloads down —
`kustomize-controller` reverts a `replicas: 0` on its next pass, so scale-to-zero
is a fight with the reconciler rather than a mechanism. Stopping k3s also takes
containerd and the Flux controllers out while gaming.

Connection-refused is therefore the intended failure mode of the inference
endpoint, not a bug. Callers are expected to fast-fail and fall back; do not add
retries, hold-open behaviour or availability machinery here to hide it.

A short `OLLAMA_KEEP_ALIVE` covers the idle-but-not-gaming case, so weights leave
VRAM without stopping the cluster.

## Lint gate

`yamllint` and `ansible-lint`, run by pre-commit and by `.forgejo/workflows/pr.yaml`.
`ansible-lint` is scoped to `ansible/` — the Flux tree is Kubernetes manifests, not
playbooks.
