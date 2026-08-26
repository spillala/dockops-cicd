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
```

## Local cluster setup

From a fresh Ubuntu box to a running, GitOps-managed `dronefleet`:

```bash
./scripts/bootstrap-ubuntu.sh      # installs MicroK8s + Helm (needs sudo, one-time)
# log out/in, then: newgrp microk8s && microk8s status --wait-ready

./scripts/bootstrap-cluster.sh     # addons, namespaces, Argo CD, the dronefleet Application

GHCR_USERNAME=<you> GHCR_TOKEN=<PAT with read:packages> \
  ./scripts/create-ghcr-pull-secret.sh dronefleet
```

Argo CD then takes over: it syncs `helm/dronefleet` from this repo automatically, and `drone-app-cicd.yml` keeps `values.yaml` pointed at the latest image whenever `dronefleet` changes. Get the Argo CD admin password (first login only) with:

```bash
microk8s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## Repository Layout

```text
argocd/dronefleet-app.yaml   Argo CD Application manifest for dronefleet
helm/dronefleet/             Helm chart Argo CD deploys (values.yaml image.tag is CI-managed)
k8s/base/                    Raw manifests (namespace, deployment, service) validated/applied by infra-cicd.yml
docs/images/                 Argo CD screenshots referenced from this README
scripts/
  bootstrap-ubuntu.sh          Installs MicroK8s + Helm on a fresh Ubuntu box
  bootstrap-cluster.sh         Enables addons, installs Argo CD, applies the dronefleet Application
  create-ghcr-pull-secret.sh   (Re)creates the ghcr-pull-secret used to pull the dronefleet image
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
- `DATABASE_URL` optional via secret `dronefleet-secrets` — falls back to dronefleet's in-memory store if unset
- Runs as non-root (uid 65532), read-only root filesystem, all capabilities dropped
- Pulls the image using `imagePullSecrets: ghcr-pull-secret` (namespace `dronefleet`) — the `ghcr.io` package is private, so every cluster needs this secret populated with real credentials before a new image tag can be pulled. Create or rotate it with:

  ```bash
  GHCR_USERNAME=<your-github-username> \
  GHCR_TOKEN=<classic PAT with the read:packages scope> \
  ./scripts/create-ghcr-pull-secret.sh dronefleet
  ```

  `imagePullPolicy: IfNotPresent` means a broken or missing secret won't show up until a *new* tag needs pulling — an already-cached tag on the node keeps running regardless. Don't take a healthy-looking pod as proof this secret is valid.

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
