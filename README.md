# jotunheim

> In Norse mythology, [Jötunheimr](https://en.wikipedia.org/wiki/J%C3%B6tunheimr)
> is the land of the jötnar, relatives to the gods. They represent the forces
> of chaos and nature.

> [!IMPORTANT]
> The canonical repository is hosted on a self-hosted
> [Forgejo](https://forgejo.org/) instance and push-mirrored to GitHub. The
> GitHub copy is read-only — changes pushed there (commits, PRs, edits) will
> **not** be persisted and will be overwritten by the next mirror sync.

One repo, one machine: **otter**, a gaming workstation that serves LLM inference
while nobody is playing on it. It holds **both halves** of that machine, its host
configuration and the manifests for what runs on it, so one clone is the complete
description and rebuilds it end to end.

Gaming is the primary workload and always wins. Inference is the scavenger.

## The machine

|              |                                                            |
| ------------ | ---------------------------------------------------------- |
| Hardware     | Radeon 7900 XTX (24 GB), 64 GB RAM, CachyOS                |
| Cluster      | Single-node k3s, also called `otter`                       |
| Reconciler   | In-cluster [Flux](https://fluxcd.io/), pulling this repo   |
| Availability | Powered on by hand, off in between. Intermittent by design |

Workloads:

| Component                               | Role                                                                    |
| --------------------------------------- | ----------------------------------------------------------------------- |
| `ollama`                                | Inference on the 7900 XTX via ROCm, pinned to the discrete card         |
| `ollama-proxy`                          | Caddy in front of it: bearer-token auth and TLS, the only thing exposed |
| `external-secrets`                      | Secrets from Vault, plus the `ClusterSecretStore`                       |
| `amd-device-plugin`                     | Advertises `amd.com/gpu`, placed by discovered hardware                 |
| `node-feature-discovery`                | Detects the card so the plugin can be placed by it                      |
| `mogenius-operator`                     | Platform visibility, with a single-instance valkey                      |
| `node-exporter`, `amd-metrics-exporter` | Host and GPU metrics, readable in-cluster                               |

Ollama has no authentication of its own and never faces the network directly. The
proxy is what listens, on port 11434 over HTTPS.

## How it bootstraps

First, set up the checkout:

```bash
hack/setup-venv.sh     # .venv plus the Galaxy content, into a gitignored cache
cp .env.example .env   # fill in OLLAMA_TOKEN
direnv allow           # loads .env and activates .venv on entry
```

[direnv](https://direnv.net/) is optional. Without it, activate `.venv` yourself and
export whatever `.env.example` documents.

Ansible owns day-0 and the host; Flux owns everything after that. Run from the
machine itself, against a checkout:

1. **`k3s_bootstrap.yml`** installs k3s, thinned to what is used here.
2. **`flux_bootstrap.yml`** runs `flux install` with three controllers, then
   applies a `GitRepository` and a root `Kustomization` for this repo. Explicitly
   not `flux bootstrap`, which commits back and would need a write credential.
3. **`vault_token_bootstrap.yml`** puts the Vault token into the cluster. This is
   the chicken-and-egg step: nothing in the cluster can fetch it yet.
4. **`host.yml`** applies the firewall rules and the gaming preemption hook.

Flux takes over from there. Its Kustomizations are ordered with `dependsOn`:

```
external-secrets → external-secrets-stores → infrastructure → apps
```

The root `Kustomization`'s path is scoped to the manifest subtree, so
`kustomize-controller` never walks `ansible/`.

## Repository layout

```
ansible/
├── inventories/localhost/     # single host, and the variables that describe it
├── playbooks/                 # bring-up, upgrades, host configuration
└── roles/                     # endpoint_firewall, gaming_preempt
clusters/otter/                # Flux entry point: one Kustomization per layer
infrastructure/<component>/    # cluster services
apps/<component>/              # workloads
docs/                          # how the less obvious mechanisms work
hack/                          # scripts for operating and measuring the machine
```

One directory per component, named after the component, holding everything that
belongs to it. Adding one is a directory plus a line in the parent
`kustomization.yaml`.

### Naming conventions

- **`*.fluxcd.yaml`** — a file carrying a chart or image version. This is what
  Renovate matches on, and it sees nothing else. A `HelmRelease` and the
  `HelmRepository` it sources from must both use it.
- **One YAML resource per file**, named after the resource it holds.

## Secrets

No secret material is committed. Secrets are synced at runtime by
[External Secrets Operator](https://external-secrets.io/) from HashiCorp Vault via
the `vault-backend-otter` `ClusterSecretStore`, which reaches
`https://vault.derwitt.site` with a read-only, path-scoped token.

Certificates are issued elsewhere and arrive the same way. No certificate issuer
runs here: that would mean issuing credentials on the least trusted machine in
reach, which is worth far more to an attacker than one leaf certificate.

## Operating it

```bash
ansible-playbook ansible/playbooks/k3s_upgrade.yml   # after a k3s_version bump
hack/gpu-mode.sh headless                            # drop the desktop, free its VRAM
hack/gpu-mode.sh desktop                             # and back
OLLAMA_TOKEN=... hack/unload-models.sh               # free the card, cluster stays up
```

A model stays resident for an hour after its last request, which is deliberate: the
gamemode hook is what clears the card for a game, so the timer only has to cover a
genuinely idle stretch. GPU work that is **not** a game never reaches that hook, so
`unload-models.sh` is the manual equivalent.

Upgrades are Ansible's, not the cluster's. `k3s_version` in `group_vars` stays
authoritative, so a rebuild can never install something older than what was
running. An in-cluster upgrade controller was considered and rejected: its plans
run privileged pods that replace the k3s binary on the host.

Launching a game stops k3s and frees the card; quitting starts it again and Flux
reconciles on its own. See [docs/gaming-preemption.md](docs/gaming-preemption.md),
which also covers why stopping the service alone is not enough.

To measure the GPU rather than guess:

```bash
OLLAMA_TOKEN=... hack/bench-ollama.sh qwen3-coder:30b   # throughput and VRAM
OLLAMA_TOKEN=... hack/bench-context.sh qwen3-coder:30b  # where a model stops fitting
```

Both drive inference through the endpoint and read the GPU with `rocm-smi`, which
has to run on the machine; set `SSH_HOST` to reach it from elsewhere. Watch the
"on GPU" column: below 100% means layers spilled to the CPU, which shows up as
poor throughput rather than an error.

## Dependencies / conventions

- **Renovate** keeps charts, images, Galaxy content and Python pins current.
  Config extends the shared `renovate/config` preset.
- **CI** (`.forgejo/workflows/pr.yaml`) runs `yamllint` and `ansible-lint` on every
  PR against `main` / `release/**`. Actions are pinned by commit SHA with a
  default `permissions: {}`.
- **pre-commit** enforces the same locally, plus trailing-whitespace / EOF / YAML
  checks. Install with `pre-commit install`.
- **[AGENTS.md](AGENTS.md)** is the reference for conventions: the trust boundary,
  why the layers are ordered as they are, and the alternatives already rejected.
  Worth reading before changing anything structural.

## Bootstrapping a rebuild

The loop above assumes a few things already exist. These are the manual
prerequisites for a from-scratch rebuild:

1. A CachyOS install with the GPU working, and a checkout of this repo on it.
2. A read-only, path-scoped Vault token, set as `vault_otter_token` in
   `group_vars/k3s_cluster/vault.yml` and `ansible-vault`-encrypted.
3. The secrets the workloads read, under this cluster's Vault mount:
   `ollama-proxy/token`, `ollama-proxy/tls`, `mogenius-operator/api-key` and
   `mogenius-operator/valkey/credentials`.
4. A reachable Vault, since the endpoint cannot serve without its token and
   certificate.

Once those are in place, the four playbooks above bring the machine up and Flux
reconciles the rest.
