#!/usr/bin/env python
"""Generate the end-to-end MLOps tutorial notebook (MLOps_Tutorial.ipynb).

Credentials are NOT baked into the notebook. The notebook reads them from
environment variables at run time (the JupyterLab service loads them from
~/mlops/.env), so the committed .ipynb contains no secrets.

Usage:  python gen_notebook.py [output_path]
"""
import os
import sys
import nbformat as nbf
from nbformat.v4 import new_notebook, new_markdown_cell, new_code_cell

cells = []
def md(t): cells.append(new_markdown_cell(t))
def code(t): cells.append(new_code_cell(t))

md("""# 🚀 End-to-End MLOps on Kubernetes — DVC · Kubeflow Pipelines · MLflow

A complete, reproducible MLOps workflow on a resource-optimized **kind** cluster
(1 control-plane + 3 workers).

| Component | Role | Endpoint (from this host) |
|-----------|------|---------------------------|
| **Contour** | Ingress (Envoy) | `http://<host>` (Host-routed) |
| **MinIO** | S3 object store (DVC remote + MLflow artifacts) | `http://s3.local` · console `http://minio.local` |
| **MLflow** | Experiment tracking + model registry | `http://mlflow.local` |
| **Kubeflow Pipelines** | Pipeline orchestration (KFP 2.16) | `http://kubeflow.local` |
| **Kubeflow Training Operator** | TFJob/PyTorchJob CRDs | in-cluster |

**Data flow:** DVC versions the dataset → pushes it to MinIO. A model is trained and
tracked in MLflow (artifacts land in MinIO). A **Kubeflow Pipeline** then runs the same
train→evaluate flow *inside the cluster*, logging back to the shared MLflow server.

> Credentials come from environment variables (loaded from `~/mlops/.env`), so no
> secrets are stored in this notebook.
""")

md("## 1 · Environment & connectivity check")
code('''import os, subprocess, sys, requests

# CLI tools live in the venv — make sure subprocess (git, dvc) can find them.
os.environ["PATH"] = os.path.dirname(sys.executable) + os.pathsep + os.environ.get("PATH", "")

# Credentials from the environment (JupyterLab loads them from ~/mlops/.env)
MINIO_USER = os.environ.get("MINIO_ROOT_USER", "minioadmin")
MINIO_PASS = os.environ.get("MINIO_ROOT_PASSWORD", "minioadmin")

# Client endpoints (host-side, via the Contour ingress)
os.environ["MLFLOW_TRACKING_URI"]    = "http://mlflow.local"
os.environ["MLFLOW_S3_ENDPOINT_URL"] = "http://s3.local"
os.environ["AWS_ACCESS_KEY_ID"]      = MINIO_USER
os.environ["AWS_SECRET_ACCESS_KEY"]  = MINIO_PASS
os.environ["AWS_DEFAULT_REGION"]     = "us-east-1"
KFP_HOST = "http://kubeflow.local"

def check(name, url):
    try:
        r = requests.get(url, timeout=10)
        print(f"  [{r.status_code}] {name:<26} {url}")
    except Exception as e:
        print(f"  [ERR] {name:<26} {url}  ->  {e}")

print("Kubernetes nodes:")
print(subprocess.run(["kubectl","get","nodes","-o","wide"], capture_output=True, text=True).stdout)
print("Backend health:")
check("MLflow",             "http://mlflow.local/health")
check("Kubeflow Pipelines", "http://kubeflow.local/apis/v2beta1/healthz")
check("MinIO (S3)",         "http://s3.local/minio/health/ready")
''')

md("""## 2 · DVC — data versioning with a MinIO remote

Initialise Git+DVC, generate a dataset, track it with `dvc add`, push it to the MinIO
`dvc` bucket, then prove reproducibility with `dvc pull`.""")
code('''import os, subprocess
import pandas as pd
from sklearn.datasets import make_classification

WORK = os.path.expanduser("~/mlops/work/dvc-demo")
def sh(cmd, cwd=WORK, check=True):
    r = subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True)
    print(f"$ {cmd}\\n{r.stdout}{r.stderr}".rstrip())
    if check and r.returncode != 0:
        raise RuntimeError(f"command failed rc={r.returncode}: {cmd}")
    return r

subprocess.run(f"rm -rf {WORK}", shell=True)
os.makedirs(os.path.join(WORK, "data"), exist_ok=True)

sh("git init -q && git config user.email demo@mlops.local && git config user.name 'MLOps Demo'")
sh("dvc init -q")

X, y = make_classification(n_samples=2000, n_features=10, n_informative=6, random_state=42)
df = pd.DataFrame(X, columns=[f"f{i}" for i in range(10)]); df["target"] = y
csv = os.path.join(WORK, "data", "dataset.csv")
df.to_csv(csv, index=False)
print(f"\\nDataset written: {csv}  shape={df.shape}")

sh("dvc add data/dataset.csv")
''')
code('''# configure the MinIO remote and push
sh("dvc remote add -d minio s3://dvc/store -f")
sh("dvc remote modify minio endpointurl http://s3.local")
sh(f"dvc remote modify --local minio access_key_id {MINIO_USER}")
sh(f"dvc remote modify --local minio secret_access_key {MINIO_PASS}")
sh("git add -A && git commit -q -m 'track dataset with dvc'", check=False)
sh("dvc push -v 2>&1 | tail -n 15")
''')
code('''# prove reproducibility: wipe local copy + cache, then pull from MinIO
sh("rm -rf data/dataset.csv .dvc/cache")
print("exists after delete:", os.path.exists(csv))
sh("dvc pull 2>&1 | tail -n 8")
print("exists after dvc pull:", os.path.exists(csv))
''')

md("""## 3 · MLflow — experiment tracking & model registry

Train a `RandomForestClassifier`, log params/metrics/model, and register it in the
Model Registry. Artifacts upload to the MinIO `mlflow` bucket (path-style S3).""")
code('''import mlflow, mlflow.sklearn, pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import accuracy_score, f1_score

mlflow.set_tracking_uri("http://mlflow.local")
mlflow.set_experiment("local-notebook-demo")

df = pd.read_csv(csv)
Xtr, Xte, ytr, yte = train_test_split(df.drop(columns=["target"]), df["target"],
                                      test_size=0.25, random_state=42)
with mlflow.start_run(run_name="rf-notebook") as run:
    n_estimators, max_depth = 150, 8
    clf = RandomForestClassifier(n_estimators=n_estimators, max_depth=max_depth,
                                 random_state=42).fit(Xtr, ytr)
    pred = clf.predict(Xte)
    acc, f1 = accuracy_score(yte, pred), f1_score(yte, pred)
    mlflow.log_params({"n_estimators": n_estimators, "max_depth": max_depth})
    mlflow.log_metrics({"accuracy": float(acc), "f1": float(f1)})
    mlflow.sklearn.log_model(clf, artifact_path="model",
                             registered_model_name="demo-classifier")
    print(f"run_id   = {run.info.run_id}")
    print(f"accuracy = {acc:.4f}   f1 = {f1:.4f}")
    print(f"artifact_uri = {mlflow.get_artifact_uri()}")
''')
code('''runs = mlflow.search_runs(experiment_names=["local-notebook-demo"])
print(runs[["run_id","metrics.accuracy","metrics.f1","params.n_estimators"]].to_string(index=False))
from mlflow import MlflowClient
print("\\nRegistered model versions:")
for mv in MlflowClient().search_model_versions("name='demo-classifier'"):
    print(f"  v{mv.version}  run={mv.run_id}")
print("\\nMLflow UI:  http://mlflow.local")
''')

md("""## 4 · Kubeflow Pipelines — orchestrate training in-cluster

A 2-step KFP pipeline (**generate → train**) whose steps run as pods using the
pre-baked `mlops-trainer:v1` image. The training step logs to the **same MLflow
server** over in-cluster DNS.""")
code('''from kfp import dsl
from kfp.dsl import Output, Input, Dataset

TRAINER_IMAGE = "mlops-trainer:v1"   # pre-loaded into the cluster (IfNotPresent)

@dsl.component(base_image=TRAINER_IMAGE)
def generate_data(data: Output[Dataset], n_samples: int = 2000):
    import pandas as pd
    from sklearn.datasets import make_classification
    X, y = make_classification(n_samples=n_samples, n_features=10, n_informative=6, random_state=7)
    df = pd.DataFrame(X, columns=[f"f{i}" for i in range(10)]); df["target"] = y
    df.to_csv(data.path, index=False)

@dsl.component(base_image=TRAINER_IMAGE)
def train_and_log(data: Input[Dataset], mlflow_uri: str, n_estimators: int = 200) -> str:
    import os
    os.makedirs(os.path.expanduser("~/.aws"), exist_ok=True)
    with open(os.path.expanduser("~/.aws/config"), "w") as f:
        f.write("[default]\\nregion = us-east-1\\ns3 =\\n    addressing_style = path\\n")
    import pandas as pd, mlflow, mlflow.sklearn
    from sklearn.ensemble import RandomForestClassifier
    from sklearn.model_selection import train_test_split
    from sklearn.metrics import accuracy_score, f1_score
    df = pd.read_csv(data.path)
    Xtr, Xte, ytr, yte = train_test_split(df.drop(columns=["target"]), df["target"],
                                          test_size=0.25, random_state=7)
    clf = RandomForestClassifier(n_estimators=n_estimators, random_state=7).fit(Xtr, ytr)
    pred = clf.predict(Xte)
    acc, f1 = float(accuracy_score(yte, pred)), float(f1_score(yte, pred))
    mlflow.set_tracking_uri(mlflow_uri)
    mlflow.set_experiment("kfp-pipeline-demo")
    with mlflow.start_run(run_name="kfp-train") as run:
        mlflow.log_param("n_estimators", n_estimators)
        mlflow.log_metrics({"accuracy": acc, "f1": f1})
        mlflow.sklearn.log_model(clf, artifact_path="model",
                                 registered_model_name="kfp-demo-classifier")
        rid = run.info.run_id
    print(f"pipeline run trained: acc={acc:.4f} f1={f1:.4f} mlflow_run={rid}")
    return rid

@dsl.pipeline(name="mlops-e2e-demo", description="generate data -> train RF -> log to MLflow")
def mlops_pipeline(n_samples: int = 2000, n_estimators: int = 200):
    g = generate_data(n_samples=n_samples)
    t = train_and_log(data=g.outputs["data"],
                      mlflow_uri="http://mlflow.mlflow.svc.cluster.local:5000",
                      n_estimators=n_estimators)
    t.set_env_variable("MLFLOW_S3_ENDPOINT_URL", "http://minio.minio.svc.cluster.local:9000")
    t.set_env_variable("AWS_ACCESS_KEY_ID", MINIO_USER)
    t.set_env_variable("AWS_SECRET_ACCESS_KEY", MINIO_PASS)
    t.set_env_variable("AWS_DEFAULT_REGION", "us-east-1")
    t.set_caching_options(False)

print("Pipeline + components defined.")
''')
code('''import kfp
client = kfp.Client(host=KFP_HOST)
run = client.create_run_from_pipeline_func(
    mlops_pipeline,
    arguments={"n_samples": 2000, "n_estimators": 200},
    experiment_name="mlops-e2e-demo",
    enable_caching=False,
)
print("Submitted pipeline run:", run.run_id)
print(f"Watch it live:  {KFP_HOST}/#/runs/details/{run.run_id}")
''')
code('''res = client.wait_for_run_completion(run.run_id, timeout=900)
state = getattr(res, "state", None) or getattr(getattr(res, "run", None), "state", None)
print("Final pipeline state:", state)
assert str(state).upper() in ("SUCCEEDED", "SUCCESS"), f"pipeline did not succeed: {state}"
print("✅ Pipeline SUCCEEDED — training ran in-cluster and logged to MLflow.")
''')

md("""## 5 · Recap

* **DVC** versioned the dataset and pushed it to MinIO; `dvc pull` reproduced it.
* **MLflow** tracked a local run and registered `demo-classifier`.
* **Kubeflow Pipelines** ran the same flow in-cluster, logging `kfp-demo-classifier`
  to the shared MLflow server — one tracker, one artifact store, two execution modes.

| UI | URL |
|----|-----|
| Kubeflow Pipelines | http://kubeflow.local |
| MLflow | http://mlflow.local |
| MinIO console | http://minio.local |
| JupyterLab | http://<host>:8888 |
""")

nb = new_notebook(cells=cells)
nb.metadata.kernelspec = {"display_name": "Python 3 (mlops)", "language": "python", "name": "python3"}
nb.metadata.language_info = {"name": "python", "version": "3.12"}
out = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/mlops/MLOps_Tutorial.ipynb")
with open(out, "w") as f:
    nbf.write(nb, f)
print("wrote", out, "cells:", len(cells))
