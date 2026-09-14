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
GHCR_USERNAME=<you> GHCR_TOKEN=<same PAT> \
  ./scripts/create-ghcr-pull-secret.sh dronefleet-agent   # the agent namespace needs its own copy

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
helm/px4-sitl-gazebo/        Helm chart wrapping the prebuilt px4io/px4-sitl-gazebo image — no in-cluster build; bundles mavlink-bridge as a sidecar
k8s/base/                    Raw manifests (namespace, deployment, service) validated/applied by infra-cicd.yml
docs/images/                 Argo CD screenshots referenced from this README
scripts/
  bootstrap-ubuntu.sh          Installs MicroK8s + Helm on a fresh Ubuntu box
  bootstrap-cluster.sh         Enables addons, installs Argo CD, applies the dronefleet Application
  create-ghcr-pull-secret.sh   (Re)creates the ghcr-pull-secret used to pull the dronefleet / dronefleet-agent images (run once per namespace)
  create-postgres-secret.sh    (Re)creates dronefleet-postgres-secret (postgres-password + database-url)
.github/workflows/
  drone-app-cicd.yml         Builds/pushes the dronefleet image, updates Helm values (triggered by dronefleet's repository_dispatch)
  dronefleet-agent-cicd.yml  Builds/pushes the dronefleet-agent image, updates Helm values (triggered by dronefleet-agent's repository_dispatch)
  mavlink-bridge-cicd.yml    Builds/pushes the mavlink-bridge image, updates helm/px4-sitl-gazebo/values.yaml (triggered by mavlink-bridge's repository_dispatch)
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

  `imagePullPolicy: IfNotPresent` means a broken or missing secret won't show up until a *new* tag needs pulling — an already-cached tag on the node keeps running regardless. Don't take a healthy-looking pod as proof this secret is valid. (This bit for real on 2026-09-14: the PAT had expired weeks earlier and nothing noticed until the first genuinely new `dronefleet-agent` tag hit `ErrImagePull`.) To check without waiting for a rollout:

  ```bash
  TOKEN=$(microk8s kubectl get secret ghcr-pull-secret -n dronefleet -o jsonpath='{.data.\.dockerconfigjson}' \
    | base64 -d | python3 -c "import json,sys,base64; print(base64.b64decode(json.load(sys.stdin)['auths']['ghcr.io']['auth']).decode().split(':',1)[1])")
  curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: token $TOKEN" https://api.github.com/user   # 200 = valid, 401 = rotate it
  ```

## dronefleet-agent + Ollama

- Argo CD Application: `dronefleet-agent`, source path `helm/dronefleet-agent`, destination namespace `dronefleet-agent`. Same `dronefleet-agent-cicd.yml` → GHCR → `values.yaml` → Argo CD flow as `dronefleet`, triggered by `dronefleet-agent`'s own `notify-cicd.yml` (which needs a `GITOPS_PAT` secret on that repo).
- Two Deployments: the agent (`ghcr.io/spillala/dronefleet-agent`, tag CI-managed) and an Ollama server (`ollama/ollama:latest`, `Recreate` strategy — a rolling update would need two copies of the model in memory at once) with a PVC for pulled models and a pre-sync Job that pulls `agent.ollamaModel`.
- Ollama resources are `requests: 200m / 1Gi`, `limits: 3 / 9Gi` on purpose: the agent sets `keep_alive: 30s` on every chat call, so the model unloads between reconcile passes and the request reflects the *idle* server. While loaded, `gemma4:e2b-it-q4_K_M` costs ~3GB anonymous RSS (the rest of the ~6.7GB Ollama reports is mmap'd, reclaimable page cache); the limit covers that burst. Before the keep_alive fix the model was resident permanently and helped push the 14GB dev host into swap far enough to time out MicroK8s's dqlite — see `dronefleet-agent`'s README, "Memory behaviour".
- Needs its own `ghcr-pull-secret` in the `dronefleet-agent` namespace (see setup above) — secrets don't cross namespaces.
- **GHCR write access is per package, not per repo.** `dronefleet-agent-cicd.yml` pushes with this repo's `GITHUB_TOKEN`. That only works if the `ghcr.io/spillala/dronefleet-agent` package is linked to `dockops-cicd`, which GHCR does automatically *only when a workflow creates the package*. If the package already exists from a manual `docker push` (it did), the push fails with `denied: permission_denied: read_package` / `write_package` until `dockops-cicd` is added with the **Write** role under the package's *Manage Actions access* settings (`github.com/users/spillala/packages/container/dronefleet-agent/settings`). There's no API for this; it's a one-time UI step per pre-existing package. `dronefleet` and `mavlink-bridge` never hit it because CI created their packages.
- Argo CD's `selfHeal` reverts any manual `kubectl set image` within seconds. To test a local build on the cluster, go through the pipeline — or accept that the manual change won't stick.

## PX4 SITL + Gazebo simulator

- Argo CD Application: `px4-sitl-gazebo`, namespace `argocd`, source path `helm/px4-sitl-gazebo`, destination namespace `px4-sitl-gazebo`
- Image: `px4io/px4-sitl-gazebo:v1.18.0-beta2` — official prebuilt PX4 SITL + Gazebo Harmonic image, pinned (not `:latest`). No build step, in-cluster or otherwise.
- Runs headless (`HEADLESS=1`), vehicle model `PX4_SIM_MODEL=gz_x500`. `px4-sitl-gazebo-svc` (`ClusterIP` by default — switch `service.type` to `NodePort` in values.yaml for a QGroundControl/MAVSDK client outside the cluster) still targets UDP 14550, but PX4 itself never listens there — see the `mavlinkBridge` bullet below.
- Resources: requests 250m CPU / 512Mi memory, limits 2 CPU / 1536Mi memory — sized from a headless smoke-test run (~150Mi RSS idle single-vehicle). In practice the idle sim loop sustains close to the full 2-core CPU limit (Gazebo's physics tick, not a leak) — worth watching before adding more simulated vehicles on this node.
- Supersedes an earlier from-source build (`PX4-Autopilot/Dockerfile.sitl`, now deleted): compiling ~1200 files with unbounded `ninja` parallelism drove this host into swap thrashing (load 250+, swap exhausted) and hung the machine. The prebuilt image sidesteps the problem entirely instead of tuning around it.
- `mavlinkBridge` (guarded by `mavlinkBridge.enabled`, default on): a second container in this same Pod, `ghcr.io/spillala/mavlink-bridge`, image tag CI-managed by `mavlink-bridge-cicd.yml`. It binds a UDP **server** on `:14550` and reports flight state + `STATUSTEXT` fault causes to `dronefleet-svc` as `mavlinkBridge.droneId` (default `drone-004`). It has to share this Pod's network namespace — PX4 sends its MAVLink stream to its own loopback (`127.0.0.1:14550`) rather than listening for a client, confirmed by packet capture against the live cluster. See [`spillala/mavlink-bridge`](https://github.com/spillala/mavlink-bridge)'s `docs/decisions/0003-udp-server-sidecar-not-client.md`.

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
- [`mavlink-bridge`](../mavlink-bridge) — reads the simulator's MAVLink stream and reports flight state + fault causes to `dronefleet`; deployed as a sidecar via `helm/px4-sitl-gazebo`

## Status & next steps (2026-09-14)

**Done:**
- `dronefleet`, `dronefleet-agent`, and `px4-sitl-gazebo` all `Synced`/`Healthy` in Argo CD; app-of-apps auto-discovery working (`bootstrap/root-app.yaml`)
- The simulator's MAVLink stream is consumed: `mavlink-bridge` runs as a sidecar in the `px4-sitl-gazebo` pod and writes flight state + `STATUSTEXT` fault events to `dronefleet` for `drone-004`. Agent 1's findings now name real causes instead of "status: fault".
- `dronefleet-agent` has been through the real pipeline end to end for the first time (it had only ever run from a manually pushed `:latest` before). Three latent gaps fixed along the way: the repo wasn't on GitHub, its GHCR package needed *Manage Actions access* for this repo, and `ghcr-pull-secret` held an expired PAT in both namespaces — all documented above.
- Host memory pressure from Ollama eased (`keep_alive`, right-sized requests) and measured over two reconcile cycles: ~5.7GB still free at peak, swap flat.

**Open items:**
- Phase B: nothing yet gates a deployment or heavy inference on flight state — the safety principle has no enforcement point. Next build per `DRONEFLEET_NEXT_PHASE_PLAN.md`.
- A diagnose pass takes ~2m45s of CPU inference, so the model is still resident ~65% of each 5-minute cycle; the dev host is fine today but there's no big margin. Faster inference or a longer `agent.watchInterval` are the levers.
- `metrics-server` is enabled but the Metrics API isn't up — `kubectl top` doesn't work on this cluster.
- `px4-sitl-gazebo-svc` is `ClusterIP`; QGroundControl or a MAVSDK client outside the cluster can't reach it yet.
- Sustained ~1.8-core CPU on a single idle simulated vehicle leaves limited room for a second one without raising `resources.limits.cpu`.
- This section is a point-in-time snapshot, not a maintained changelog — update or delete it as the project moves past it rather than letting it drift.
