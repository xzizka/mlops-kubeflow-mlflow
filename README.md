# MLOps Training Environment — Kubeflow · MLflow · DVC on kind

A **one-command, reproducible** MLOps lab that stands up a complete, resource-optimized
Kubernetes environment on a single Fedora host and ships an end-to-end tutorial notebook.

Everything is scripted: run `./install.sh` on a fresh **Fedora 43+** machine and you get a
4-node [kind](https://kind.sigs.k8s.io) cluster running Kubeflow Pipelines, MLflow, an S3
object store, and a JupyterLab with a working DVC → Kubeflow → MLflow tutorial.

---

## What you get

| Component | Role |
|-----------|------|
| **kind** cluster | 1 control-plane + 3 workers (Kubernetes v1.34) |
| **Contour** (Envoy) | Ingress controller on host ports 80/443, routed by `Host` header |
| **MinIO** | S3-compatible object store — DVC remote, MLflow artifacts, KFP artifacts |
| **MLflow** | Experiment tracking + model registry (artifacts in MinIO) |
| **Kubeflow Pipelines** 2.16 | Pipeline orchestration engine + UI |
| **Kubeflow Training Operator** 1.8 | TFJob / PyTorchJob CRDs |
| **JupyterLab** | Web IDE on the host with the pre-loaded tutorial notebook |

```
                       ┌─────────────────────── Fedora host ───────────────────────┐
   browser ──:8888──▶ │ JupyterLab (venv)                                          │
   browser ──:80────▶ │ Contour/Envoy ──▶ ml-pipeline-ui / mlflow / minio (ingress)│
                       │                                                            │
                       │   kind cluster (docker)                                    │
                       │   ├─ control-plane   ├─ worker1  ├─ worker2  ├─ worker3    │
                       │   Contour · MinIO · MLflow · KFP · Training Operator       │
                       └────────────────────────────────────────────────────────────┘
```

The tutorial notebook demonstrates the full loop: **DVC** versions a dataset and pushes it
to MinIO, **MLflow** tracks a local training run and registers the model, and a **Kubeflow
Pipeline** re-runs the training *inside the cluster*, logging to the same MLflow server.

---

## Prerequisites

- **Fedora 43+** (tested on Fedora 44) — physical or VM, x86_64.
- A user with **sudo** (passwordless recommended for a hands-off run).
- **~25 GB** free disk. Cloud images often ship a small root LV; the installer can extend
  it automatically from free volume-group space (`EXTEND_ROOT_LV=true`).
- **≥ 8 GB RAM** (16 GB comfortable). Internet access for image/package pulls.

The installer provisions everything else (Docker, kind, kubectl, helm, kustomize, Python 3.12).

---

## Quick start

```bash
git clone https://github.com/xzizka/mlops-kubeflow-mlflow.git
cd mlops-kubeflow-mlflow

cp .env.example .env
${EDITOR:-vi} .env          # set MINIO_*_PASSWORD and JUPYTER_TOKEN

./install.sh
```

> **First run only:** step `00-prereqs` adds you to the `docker` group. If the script
> stops asking you to re-login, run `newgrp docker` (or log out/in) and re-run `./install.sh`.
> All steps are idempotent, so re-running is safe.

When it finishes, `99-verify` prints the access URLs and the Jupyter token.

Run individual steps by number:

```bash
./install.sh 06 08      # re-run only Kubeflow and Jupyter steps
```

---

## Accessing the environment

**JupyterLab** (works with no client setup):

```
http://<HOST_IP>:8888/lab?token=<JUPYTER_TOKEN>
```

The tutorial `MLOps_Tutorial.ipynb` is pre-loaded — run all cells top to bottom.

**Web UIs** are Host-routed by Contour. Add this to *your* machine's hosts file
(`/etc/hosts`, or `C:\Windows\System32\drivers\etc\hosts`):

```
<HOST_IP>  kubeflow.local mlflow.local minio.local s3.local
```

then open:

| UI | URL |
|----|-----|
| Kubeflow Pipelines | http://kubeflow.local |
| MLflow | http://mlflow.local |
| MinIO console | http://minio.local |

---

## Repository layout

```
install.sh              Orchestrator — runs the steps in order
uninstall.sh            Stop Jupyter + delete the cluster
.env.example            Config template (copy to .env; .env is git-ignored)
lib/common.sh           Shared shell helpers (env loading, logging, kubectl)
scripts/
  00-prereqs.sh         Docker, kind, kubectl, helm, kustomize, python3.12
  01-host-tuning.sh     firewalld, sysctls (inotify/rp_filter), disk extend
  02-kind-cluster.sh    Create the 1+3 node cluster (host ports 80/443)
  03-contour.sh         Contour/Envoy ingress
  04-minio.sh           MinIO + buckets (mlflow, dvc, mlpipeline) + KFP user
  05-mlflow.sh          MLflow tracking server
  06-kubeflow.sh        Kubeflow Pipelines + Training Operator + MinIO repoint
  07-trainer-image.sh   Build & load the pipeline step image
  08-jupyter.sh         JupyterLab venv + service + tutorial notebook
  99-verify.sh          Health checks + print access info
manifests/              kind config + Kubernetes manifests (envsubst templated)
trainer/Dockerfile      Pre-baked image for pipeline steps
notebook/gen_notebook.py Generates MLOps_Tutorial.ipynb (no secrets baked in)
```

---

## Configuration & secrets

All credentials live in **`.env`** (git-ignored). Nothing sensitive is committed — manifests
are rendered with `envsubst` at apply time, and the notebook reads credentials from the
environment at run time.

| Variable | Purpose |
|----------|---------|
| `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` | MinIO admin (notebook client, DVC, MLflow artifacts) |
| `MINIO_KFP_USER` / `MINIO_KFP_PASSWORD` | Dedicated account Kubeflow Pipelines uses internally |
| `JUPYTER_TOKEN` | JupyterLab access token |
| `KFP_VERSION`, `TRAINING_OPERATOR_REF`, `KIND_NODE_IMAGE` | Pinned versions |
| `DISABLE_FIREWALLD`, `EXTEND_ROOT_LV`, `MIN_ROOT_FREE_GB` | Host tuning toggles |

---

## Design notes (Fedora + kind gotchas handled for you)

These are real failure modes the installer works around:

- **firewalld breaks cross-node pod networking.** `firewall-cmd --reload` flushes the
  iptables/nftables FORWARD rules Docker installs for the kind bridge. The installer disables
  firewalld and restarts Docker to rebuild clean rules.
- **inotify limits.** The default `fs.inotify.max_user_instances=128` is too low for a
  multi-pod cluster and causes `too many open files` crashloops. Raised via sysctl.
- **`rp_filter`** is set to `0` so forwarded pod traffic isn't dropped.
- **Small root disk.** The root LV is extended into free VG space when needed.
- **No IPv6 egress in pods.** kind pods can't reach IPv6-only PyPI, so any in-pod `pip`
  hangs. `/etc/gai.conf` forces IPv4, and pipeline steps use a pre-baked image.
- **KFP's bundled seaweedfs** object store binds S3 to localhost and is unreachable, so the
  artifact store is repointed to the shared MinIO (secret, launcher config, workflow-controller).

---

## Teardown

```bash
./uninstall.sh          # stop Jupyter + delete the kind cluster
rm -rf ~/mlops          # (optional) remove the venv, notebook and work dir
```

---

## License

MIT — use freely for training and experimentation.
