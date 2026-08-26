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
       - collect pod/deployment/event state and ask Claude for a PASS/FAIL
         health verdict on the rollout
```

## Repository Layout

```text
argocd/dronefleet-app.yaml   Argo CD Application manifest for dronefleet
helm/dronefleet/             Helm chart Argo CD deploys (values.yaml image.tag is CI-managed)
k8s/base/                    Raw manifests (namespace, deployment, service) validated/applied by infra-cicd.yml
docs/images/                 Argo CD screenshots referenced from this README
scripts/bootstrap-ubuntu.sh  Installs MicroK8s + tooling on a fresh Ubuntu box
.github/workflows/
  drone-app-cicd.yml         Builds/pushes the dronefleet image, updates Helm values (triggered by dronefleet's repository_dispatch)
  infra-cicd.yml             Validates + applies k8s manifests, runs the Claude-based cluster health check
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

## Related repos

- [`dronefleet`](../dronefleet) — the Go API this pipeline builds and deploys
- [`dronefleet-mcp`](../dronefleet-mcp) — MCP server exposing the deployed `dronefleet` API as tools for AI agents
