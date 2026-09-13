# DockOps CI/CD

The GitOps / CI-CD platform for [`dronefleet`](https://github.com/spillala/dronefleet): it builds and publishes the `dronefleet` container image, keeps the Kubernetes deployment manifests, and lets Argo CD reconcile the running app on a MicroK8s cluster.

## Architecture

```text
dronefleet repo (push to main)
  -> repository_dispatch: dronefleet-app-updated
  -> drone-app-cicd.yml
       - checkout dronefleet app + this repo
       - lint / vet / test the Go app
       - build & push image to ghcr.io/spillala/dronefleet:<short-sha>
       - update helm/dronefleet/values.yaml image.tag
       - commit + push the values change to main
  -> Argo CD Application "dronefleet" (auto-sync, self-heal, prune)
       - watches helm/dronefleet on this repo
       - rolls the new image out into the `dronefleet` namespace on MicroK8s

k8s/**, helm/** changes (excluding the CI-managed values.yaml)
  -> infra-cicd.yml
       - validate manifests with kubeconform + kubectl dry-run
       - apply k8s/base/ to the cluster
       - collect pod/deployment/event state and ask an LLM for a PASS/FAIL
         health verdict on the rollout (provider is pluggable, see below)

argocd/*.yaml (any Application manifest, new or changed)
  -> Argo CD Application "dockops-apps" (app-of-apps root, see below)
       - watches this repo's argocd/ directory as a plain manifest source
       - applies/prunes whatever Application objects it finds there
       - each discovered Application then syncs its own helm/<name> chart
         the same way "dronefleet" always has — no per-app manual
         `kubectl apply` needed once the root is bootstrapped
```

### Auto-discovery (app-of-apps)

`bootstrap/root-app.yaml` is a directory-type Argo CD Application named `dockops-apps` whose source path is `argocd/`. Any `*-app.yaml` Application manifest committed to `argocd/` and pushed to `main` gets picked up and applied automatically on the next sync (`selfHeal`/`automated` polls periodically; force an immediate pass with `kubectl annotate application dockops-apps -n argocd argocd.argoproj.io/refresh=hard --overwrite`).

This root manifest deliberately lives in `bootstrap/`, **not** `argocd/` itself — a directory-type Application whose own file sits inside the directory it manages ends up re-applying (and therefore diffing against) itself on every sync. In this repo's history that caused a permanent `Synced`/`OutOfSync` flap, and once `prune: true` is set, the root app will conclude its own previously-tracked self is "no longer desired" and **delete itself**. Keep `bootstrap/root-app.yaml` out of `argocd/` to avoid repeating that.

The root itself still needs one manual bootstrap (chicken-and-egg — nothing discovers the discoverer):

```bash
microk8s kubectl apply -f bootstrap/root-app.yaml
```

After that one-time step, every other Application in `argocd/` — `dronefleet`, `dronefleet-agent`, `px4-sitl-gazebo`, and anything added later — is fully hands-off.

## Local cluster setup

From a fresh Ubuntu box to a running, GitOps-managed `dronefleet`:

```bash
./scripts/bootstrap-ubuntu.sh      # installs MicroK8s + Helm (needs sudo, one-time)
# log out/in, then: newgrp microk8s && microk8s status --wait-ready

./scripts/bootstrap-cluster.sh     # addons, namespaces, Argo CD, the dronefleet Application

GHCR_USERNAME=<you> GHCR_TOKEN=<PAT with read:packages> \
  ./scripts/create-ghcr-pull-secret.sh dronefleet

microk8s kubectl apply -f bootstrap/root-app.yaml   # one-time: enables auto-discovery for every other Application in argocd/
```

Argo CD then takes over: it syncs `helm/dronefleet` from this repo automatically, and `drone-app-cicd.yml` keeps `values.yaml` pointed at the latest image whenever `dronefleet` changes. Get the Argo CD admin password (first login only) with:

```bash
microk8s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## Repository Layout

```text
bootstrap/root-app.yaml      App-of-apps root — the one Application applied manually; discovers the rest
argocd/dronefleet-app.yaml   Argo CD Application manifest for dronefleet
argocd/dronefleet-agent-app.yaml   Argo CD Application manifest for dronefleet-agent (+ its Ollama runtime)
argocd/px4-sitl-gazebo-app.yaml    Argo CD Application manifest for the PX4 SITL + Gazebo simulator
helm/dronefleet/             Helm chart Argo CD deploys (values.yaml image.tag is CI-managed; bundles Postgres + a migration Job)
helm/dronefleet-agent/       Helm chart for dronefleet-agent + its Ollama deployment
helm/px4-sitl-gazebo/        Helm chart wrapping the prebuilt px4io/px4-sitl-gazebo image — no in-cluster build
k8s/base/                    Raw manifests (namespace, deployment, service) validated/applied by infra-cicd.yml
docs/images/                 Argo CD screenshots referenced from this README
scripts/
  bootstrap-ubuntu.sh          Installs MicroK8s + Helm on a fresh Ubuntu box
  bootstrap-cluster.sh         Enables addons, installs Argo CD, applies the dronefleet Application
  create-ghcr-pull-secret.sh   (Re)creates the ghcr-pull-secret used to pull the dronefleet image
  create-postgres-secret.sh    (Re)creates dronefleet-postgres-secret (postgres-password + database-url)
.github/workflows/
  drone-app-cicd.yml         Builds/pushes the dronefleet image, updates Helm values (triggered by dronefleet's repository_dispatch)
  infra-cicd.yml             Validates + applies k8s manifests, runs the AI-based cluster health check
```

## Argo CD Application

- Name: `dronefleet`, namespace: `argocd`, project: `default`
- Source: this repo, path `helm/dronefleet`, target revision `main`
- Destination: `dronefleet` namespace on the in-cluster MicroK8s API server
- Sync policy: automated with `prune` and `selfHeal`, `CreateNamespace=true`

## Deployed workload

- Image: `ghcr.io/spillala/dronefleet`, tag driven by CI (see `helm/dronefleet/values.yaml`)
- 2 replicas, rolling update (`maxSurge: 1`, `maxUnavailable: 0`)
- Liveness/readiness probes on `/healthz` and `/readyz`
- `DATABASE_URL` optional via secret `dronefleet-postgres-secret` (key `database-url`) — falls back to dronefleet's in-memory store if the secret doesn't exist yet. **This secret does not exist until you create it** (see below); until then the "live" dronefleet is silently running in-memory, not against Postgres — don't assume otherwise just because the pod is healthy.
- Bundled Postgres (`postgres:16-alpine`, single replica, `dronefleet-postgres-svc:5432`, one `ReadWriteOnce` PVC — `postgres.storage` in values.yaml) ships in the same `helm/dronefleet` chart, guarded by `postgres.enabled`. It starts empty; schema is applied by a `wait-for-postgres` + `migrate` **initContainer pair** on the `dronefleet` Deployment itself (not an Argo/Helm sync hook — a hook Job can't fire until the Deployment is Healthy, but the Deployment can't become Healthy until the schema exists, a real deadlock hit and fixed during Phase A rollout). Runs `dronefleet`'s own `/app/migrate up`; `migrate`'s Postgres advisory lock makes concurrent runs across replicas safe. See `dronefleet/db/migrations` and ADR `dronefleet/docs/decisions/0001-migrations-and-telemetry-fault-schema.md`.
- Postgres's own password and the app's `database-url` both come from one secret, created out-of-band (never committed):

  ```bash
  POSTGRES_PASSWORD=<pick one> ./scripts/create-postgres-secret.sh dronefleet
  ```
- Runs as non-root (uid 65532), read-only root filesystem, all capabilities dropped
- Pulls the image using `imagePullSecrets: ghcr-pull-secret` (namespace `dronefleet`) — the `ghcr.io` package is private, so every cluster needs this secret populated with real credentials before a new image tag can be pulled. Create or rotate it with:

  ```bash
  GHCR_USERNAME=<your-github-username> \
  GHCR_TOKEN=<classic PAT with the read:packages scope> \
  ./scripts/create-ghcr-pull-secret.sh dronefleet
  ```

  `imagePullPolicy: IfNotPresent` means a broken or missing secret won't show up until a *new* tag needs pulling — an already-cached tag on the node keeps running regardless. Don't take a healthy-looking pod as proof this secret is valid.

## PX4 SITL + Gazebo simulator

- Argo CD Application: `px4-sitl-gazebo`, namespace `argocd`, source path `helm/px4-sitl-gazebo`, destination namespace `px4-sitl-gazebo`
- Image: `px4io/px4-sitl-gazebo:v1.18.0-beta2` — official prebuilt PX4 SITL + Gazebo Harmonic image, pinned (not `:latest`). No build step, in-cluster or otherwise.
- Runs headless (`HEADLESS=1`), vehicle model `PX4_SIM_MODEL=gz_x500`, MAVLink exposed on UDP 14550 via `px4-sitl-gazebo-svc` (`ClusterIP` by default — switch `service.type` to `NodePort` in values.yaml for a QGroundControl/MAVSDK client outside the cluster)
- Resources: requests 250m CPU / 512Mi memory, limits 2 CPU / 1536Mi memory — sized from a headless smoke-test run (~150Mi RSS idle single-vehicle). In practice the idle sim loop sustains close to the full 2-core CPU limit (Gazebo's physics tick, not a leak) — worth watching before adding more simulated vehicles on this node.
- Supersedes an earlier from-source build (`PX4-Autopilot/Dockerfile.sitl`, now deleted): compiling ~1200 files with unbounded `ninja` parallelism drove this host into swap thrashing (load 250+, swap exhausted) and hung the machine. The prebuilt image sidesteps the problem entirely instead of tuning around it.

## AI cluster health check — configuration

`infra-cicd.yml`'s `ai-verify` job asks an LLM to read the post-deploy cluster state and return a PASS/FAIL verdict. The provider is a repo-level setting, not hardcoded, so it's cheap to run against a free/self-hosted model instead of a paid API while the project is young:

| Variable / secret | Purpose | Default |
|---|---|---|
| `vars.AI_VERIFY_PROVIDER` | `anthropic` or `openai_compatible` | `anthropic` |
| `vars.AI_VERIFY_MODEL` | model name sent to the provider | `claude-sonnet-4-20250514` (anthropic) / `llama3.1` (openai_compatible) |
| `vars.AI_VERIFY_BASE_URL` | API base URL, `openai_compatible` only | `http://localhost:11434/v1` (Ollama's default) |
| `secrets.ANTHROPIC_API_KEY` | required for `anthropic` | — |
| `secrets.OPENAI_API_KEY` | optional for `openai_compatible` (most self-hosted servers don't need one) | — |

`openai_compatible` targets anything that speaks the OpenAI chat-completions schema — Ollama, vLLM, LocalAI, LM Studio, text-generation-webui, or a hosted free-tier gateway. Point `AI_VERIFY_BASE_URL` at a reachable endpoint (a self-hosted runner or a tunnel into your cluster, since GitHub-hosted runners can't reach `localhost:11434` on your machine) and set `AI_VERIFY_MODEL` to whatever model that server is running. If neither provider's credentials are configured, the step logs why and exits cleanly — it never fails the deploy.

## Related repos

- [`dronefleet`](../dronefleet) — the Go API this pipeline builds and deploys
- [`dronefleet-mcp`](../dronefleet-mcp) — MCP server exposing the deployed `dronefleet` API as tools for AI agents
- [`dronefleet-agent`](../dronefleet-agent) — autonomous fault-diagnosis agent (Ollama + Gemma), deployed via `helm/dronefleet-agent`

## Status & next steps (2026-09-06)

**Done:**
- `dronefleet`, `dronefleet-agent`, and `px4-sitl-gazebo` all `Synced`/`Healthy` in Argo CD
- Real app-of-apps auto-discovery working (`bootstrap/root-app.yaml`) — new Applications in `argocd/` no longer need a manual `kubectl apply`
- PX4 simulator running on a prebuilt image instead of the from-source build that previously hung the host

**Open items:**
- Nothing currently connects the running simulator to `dronefleet`/`dronefleet-agent` — MAVLink telemetry from `px4-sitl-gazebo-svc:14550` isn't consumed anywhere yet. Deciding how (a bridge service? extend `dronefleet-mcp`?) is the next real design question.
- `px4-sitl-gazebo-svc` is `ClusterIP`; there's no way to point QGroundControl or a MAVSDK client at it from outside the cluster yet if that's wanted for manual testing.
- Sustained ~1.8-core CPU on a single idle simulated vehicle leaves limited room to run a second one on this node without raising `resources.limits.cpu` or watching the AI-verify job's pass/fail more closely.
- This section is a point-in-time snapshot, not a maintained changelog — update or delete it as the project moves past it rather than letting it drift.
