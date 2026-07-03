# Pre-baked image for Kubeflow Pipeline steps.
# Baking the ML libs avoids runtime pip inside kind pods (which have no IPv6
# egress and cannot reach IPv6-only PyPI). /etc/gai.conf forces IPv4 anyway.
# Built and `kind load`-ed into the cluster; referenced as mlops-trainer:v1
# (non-latest tag => imagePullPolicy defaults to IfNotPresent => no registry pull).
FROM python:3.12-slim
RUN echo 'precedence ::ffff:0:0/96 100' > /etc/gai.conf
RUN pip install --no-cache-dir \
      scikit-learn==1.9.0 pandas numpy \
      "mlflow==2.19.0" boto3
