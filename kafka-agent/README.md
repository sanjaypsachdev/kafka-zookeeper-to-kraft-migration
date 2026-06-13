# Kafka ZooKeeper → KRaft Migration Agent

A LangGraph AI agent that automates migrating an Apache Kafka cluster from
ZooKeeper to KRaft on OpenShift (Strimzi / Red Hat Streams for Apache Kafka).
It mirrors the `zk-to-kafka-migration.sh` script but is driven by an LLM and
exposes the cluster operations as discrete tools (`src/tools.py`).

## Running locally

```bash
cd kafka-agent
cp .env.example .env          # set LLM_PROVIDER, model, and API key
uv sync
uv run python -m src.main <namespace> <kafka-instance-name> [options]
```

Requires a logged-in `oc` (`oc login <cluster-url>`) and an LLM endpoint.

`--help` lists all options (controller pool sizing, storage, timeout,
`--skip-prereq-check`, `--auto-approve`).

---

## Running in OpenShift / OpenShift AI

The agent ships as a container image that authenticates to the cluster
**in-cluster** via its ServiceAccount (no `oc login`) and talks to **OpenShift AI
model serving** for the LLM. The image bundles the `oc` client, which
auto-discovers the ServiceAccount token and CA from
`/var/run/secrets/kubernetes.io/serviceaccount`.

### 1. Build the image

Workstation build + push to the internal registry:

```bash
cd kafka-agent
podman build -t kafka-migration-agent:latest .

# Push to the OpenShift internal registry (example)
podman tag kafka-migration-agent:latest \
  default-route-openshift-image-registry.apps.<cluster-domain>/<namespace>/kafka-migration-agent:latest
podman push \
  default-route-openshift-image-registry.apps.<cluster-domain>/<namespace>/kafka-migration-agent:latest
```

Or build **in-cluster** with `openshift/buildconfig.yaml`:

```bash
oc apply -f openshift/buildconfig.yaml      # edit the Git URI first
oc start-build kafka-migration-agent --follow
```

Pin a specific `oc` version with `--build-arg OC_VERSION=4.16.0` if needed.

### 2. Apply RBAC + LLM config

```bash
oc project <namespace>                       # the namespace with the Kafka instance

oc apply -f openshift/serviceaccount.yaml
oc apply -f openshift/role.yaml
oc apply -f openshift/rolebinding.yaml

# Optional — only needed if you do NOT pass --skip-prereq-check.
# Edit the namespace placeholder in the binding first.
oc apply -f openshift/clusterrole-namespace-read.yaml

# LLM endpoint (OpenShift AI model serving). Copy, fill in, apply.
cp openshift/secret-llm.yaml.example openshift/secret-llm.yaml
$EDITOR openshift/secret-llm.yaml
oc apply -f openshift/secret-llm.yaml
```

The `Role` grants exactly the operations in `src/tools.py`: get/patch on
`kafkas`, full lifecycle on `kafkanodepools`, create/approve on
`kafkarebalances`, and read on `pods`.

### 3. Point the agent at OpenShift AI model serving

The agent uses the OpenAI-compatible interface (`src/config.py`), so any
OpenShift AI InferenceService served via vLLM works. In `secret-llm.yaml` set:

- `LLM_PROVIDER=openai`
- `LLM_MODEL` — the served model name
- `OPENAI_BASE_URL` — the model's OpenAI endpoint ending in `/v1` (internal
  Service `…svc.cluster.local:8443/v1` or its external Route)
- `OPENAI_API_KEY` — a bearer token accepted by the endpoint

> **TLS note:** the internal Service hostname often uses the cluster's internal
> CA. If the OpenAI client rejects it, use the model's external **Route** (public
> CA), or mount the cluster CA into the pod and set `SSL_CERT_FILE` to it.

### 4. Run it

**Interactive** (recommended — the migration pauses for human approval before
enabling KRaft):

```bash
oc apply -f openshift/pod-interactive.yaml    # edit the image reference first
oc rsh pod/kafka-migration-agent
python -m src.main <namespace> <kafka-instance> [options]
```

The same image can back an **OpenShift AI workbench**: create a custom workbench
image pointing at this image, open a terminal, and run the agent there.

**Batch Job** (unattended — approval is auto-answered with `--auto-approve`):

```bash
oc apply -f openshift/job.yaml                 # edit image + args first
oc logs -f job/kafka-migration-agent
```

> Only use the Job when unattended approval of the KRaft cutover is acceptable —
> activation restarts all brokers and controllers and is effectively
> irreversible. Otherwise use the interactive pod.
