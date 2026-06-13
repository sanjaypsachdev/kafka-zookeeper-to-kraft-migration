"""
All OpenShift CLI (oc) wrappers exposed as LangChain tools.

Each tool returns a plain dict:
  {"success": bool, "output": str, "error": str | None}

Tools are intentionally low-level — one tool per oc operation — so the
agent can combine them flexibly without hidden side effects.
"""

import json
import subprocess
from typing import Any

from langchain_core.tools import tool


# ---------------------------------------------------------------------------
# Internal helper
# ---------------------------------------------------------------------------

def _run(cmd: list[str], stdin: str | None = None) -> dict[str, Any]:
    """Run an oc command and return a normalised result dict."""
    try:
        result = subprocess.run(
            cmd,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode == 0:
            return {"success": True, "output": result.stdout.strip(), "error": None}
        return {
            "success": False,
            "output": result.stdout.strip(),
            "error": result.stderr.strip(),
        }
    except subprocess.TimeoutExpired:
        return {"success": False, "output": "", "error": "Command timed out after 60 seconds"}
    except FileNotFoundError:
        return {"success": False, "output": "", "error": "oc command not found. Install the OpenShift CLI."}
    except Exception as exc:
        return {"success": False, "output": "", "error": str(exc)}


# ---------------------------------------------------------------------------
# Cluster / session checks
# ---------------------------------------------------------------------------

@tool
def check_oc_login() -> dict:
    """Check that the oc CLI is available and the user is logged in to an OpenShift cluster."""
    return _run(["oc", "whoami"])


@tool
def check_namespace(namespace: str) -> dict:
    """Verify that an OpenShift namespace exists."""
    return _run(["oc", "get", "namespace", namespace])


# ---------------------------------------------------------------------------
# Kafka resource inspection
# ---------------------------------------------------------------------------

@tool
def get_kafka_resource(namespace: str, kafka_instance: str) -> dict:
    """Fetch the full Kafka custom resource as JSON."""
    return _run(["oc", "get", "kafka", kafka_instance, "-n", namespace, "-o", "json"])


@tool
def get_kafka_kraft_annotation(namespace: str, kafka_instance: str) -> dict:
    """
    Return the value of the strimzi.io/kraft annotation on a Kafka resource.
    Returns 'none' when the annotation is absent.
    """
    result = _run([
        "oc", "get", "kafka", kafka_instance, "-n", namespace,
        "-o", r"jsonpath={.metadata.annotations.strimzi\.io/kraft}",
    ])
    if result["success"] and not result["output"]:
        result["output"] = "none"
    return result


@tool
def get_kafka_node_pools_annotation(namespace: str, kafka_instance: str) -> dict:
    """
    Return the value of the strimzi.io/node-pools annotation on a Kafka resource.
    Returns 'none' when the annotation is absent.
    """
    result = _run([
        "oc", "get", "kafka", kafka_instance, "-n", namespace,
        "-o", r"jsonpath={.metadata.annotations.strimzi\.io/node-pools}",
    ])
    if result["success"] and not result["output"]:
        result["output"] = "none"
    return result


@tool
def get_kafka_replicas(namespace: str, kafka_instance: str) -> dict:
    """Return spec.kafka.replicas from a Kafka resource (empty when using node pools)."""
    return _run([
        "oc", "get", "kafka", kafka_instance, "-n", namespace,
        "-o", "jsonpath={.spec.kafka.replicas}",
    ])


@tool
def get_kafka_storage(namespace: str, kafka_instance: str) -> dict:
    """Return spec.kafka.storage as JSON from a Kafka resource."""
    return _run([
        "oc", "get", "kafka", kafka_instance, "-n", namespace,
        "-o", "jsonpath={.spec.kafka.storage}",
    ])


@tool
def get_zookeeper_config(namespace: str, kafka_instance: str) -> dict:
    """Return the ZooKeeper section (replicas + storage) from a Kafka resource as JSON."""
    result = _run([
        "oc", "get", "kafka", kafka_instance, "-n", namespace,
        "-o", "json",
    ])
    if not result["success"]:
        return result
    try:
        kafka = json.loads(result["output"])
        zk = kafka.get("spec", {}).get("zookeeper", {})
        return {"success": True, "output": json.dumps(zk), "error": None}
    except json.JSONDecodeError as e:
        return {"success": False, "output": "", "error": str(e)}


@tool
def get_migration_state(namespace: str, kafka_instance: str) -> dict:
    """
    Return the current Kafka migration / metadata state.
    Tries status.kafkaMetadataState, then status.kafkaMigrationStatus.state.
    Returns 'Unknown' when neither field is present.
    """
    for jsonpath in [
        "{.status.kafkaMetadataState}",
        "{.status.kafkaMigrationStatus.state}",
    ]:
        result = _run([
            "oc", "get", "kafka", kafka_instance, "-n", namespace,
            "-o", f"jsonpath={jsonpath}",
        ])
        if result["success"] and result["output"]:
            return result
    return {"success": True, "output": "Unknown", "error": None}


# ---------------------------------------------------------------------------
# KafkaNodePool inspection
# ---------------------------------------------------------------------------

@tool
def get_kafkanodepool_list(namespace: str, kafka_instance: str) -> dict:
    """List all KafkaNodePools associated with a Kafka instance (JSON output)."""
    return _run([
        "oc", "get", "kafkanodepool", "-n", namespace,
        "-l", f"strimzi.io/cluster={kafka_instance}",
        "-o", "json",
    ])


@tool
def get_kafkanodepool(namespace: str, pool_name: str) -> dict:
    """Get a single KafkaNodePool by name (JSON output)."""
    return _run(["oc", "get", "kafkanodepool", pool_name, "-n", namespace, "-o", "json"])


@tool
def get_kafkanodepool_cluster_owner(namespace: str, pool_name: str) -> dict:
    """
    Return which Kafka instance owns a KafkaNodePool (via the strimzi.io/cluster label).
    Returns an empty string if the pool does not exist.
    """
    result = _run([
        "oc", "get", "kafkanodepool", pool_name, "-n", namespace,
        "-o", r"jsonpath={.metadata.labels.strimzi\.io/cluster}",
    ])
    if not result["success"] and "not found" in (result["error"] or "").lower():
        return {"success": True, "output": "", "error": None}
    return result


@tool
def detect_kafkanodepool_api_version(namespace: str) -> dict:
    """
    Detect the correct KafkaNodePool apiVersion from the cluster.
    Falls back to kafka.strimzi.io/v1beta2 when detection fails.
    """
    # Try CRD stored version
    result = _run([
        "oc", "get", "crd", "kafkanodepools.kafka.strimzi.io",
        "-o", r"jsonpath={range .spec.versions[?(@.storage==true)]}{.name}{end}",
    ])
    if result["success"] and result["output"]:
        return {"success": True, "output": f"kafka.strimzi.io/{result['output']}", "error": None}

    # Fallback: all versions, take last
    result2 = _run([
        "oc", "get", "crd", "kafkanodepools.kafka.strimzi.io",
        "-o", "jsonpath={.spec.versions[*].name}",
    ])
    if result2["success"] and result2["output"]:
        versions = result2["output"].split()
        return {"success": True, "output": f"kafka.strimzi.io/{versions[-1]}", "error": None}

    return {"success": True, "output": "kafka.strimzi.io/v1beta2", "error": None}


# ---------------------------------------------------------------------------
# Pod readiness
# ---------------------------------------------------------------------------

@tool
def get_pod_readiness(namespace: str, label_selector: str) -> dict:
    """
    Return pod status for pods matching a label selector.
    Reports how many pods are ready vs total.
    Label selector example: 'strimzi.io/cluster=my-kafka,strimzi.io/pool-name=controller-my-kafka'
    """
    result = _run([
        "oc", "get", "pods", "-n", namespace,
        "-l", label_selector,
        "-o", "json",
    ])
    if not result["success"]:
        return result
    try:
        data = json.loads(result["output"])
        pods = data.get("items", [])
        total = len(pods)
        ready = sum(
            1 for p in pods
            if all(
                c.get("ready", False)
                for c in p.get("status", {}).get("containerStatuses", [])
            ) and p.get("status", {}).get("phase") == "Running"
        )
        summary = f"{ready}/{total} pods ready"
        return {"success": True, "output": summary, "error": None, "ready": ready, "total": total}
    except json.JSONDecodeError as e:
        return {"success": False, "output": "", "error": str(e)}


# ---------------------------------------------------------------------------
# Mutation: KafkaNodePool
# ---------------------------------------------------------------------------

@tool
def create_kafkanodepool(yaml_manifest: str) -> dict:
    """Apply a KafkaNodePool YAML manifest (passed as a string) using oc apply."""
    return _run(["oc", "apply", "-f", "-"], stdin=yaml_manifest)


@tool
def delete_kafkanodepool(namespace: str, pool_name: str) -> dict:
    """Delete a KafkaNodePool and wait for deletion to complete."""
    return _run(["oc", "delete", "kafkanodepool", pool_name, "-n", namespace, "--wait=true"])


# ---------------------------------------------------------------------------
# Mutation: Kafka resource
# ---------------------------------------------------------------------------

@tool
def annotate_kafka(namespace: str, kafka_instance: str, annotation_key: str, annotation_value: str) -> dict:
    """Add or update an annotation on a Kafka resource."""
    return _run([
        "oc", "annotate", "kafka", kafka_instance, "-n", namespace,
        f"{annotation_key}={annotation_value}",
        "--overwrite",
    ])


@tool
def patch_kafka_json(namespace: str, kafka_instance: str, json_patch: str) -> dict:
    """
    Apply a JSON patch to a Kafka resource.
    json_patch should be a JSON array of patch operations,
    e.g. '[{"op":"remove","path":"/spec/zookeeper"}]'
    """
    return _run([
        "oc", "patch", "kafka", kafka_instance, "-n", namespace,
        "--type=json",
        f"-p={json_patch}",
    ])


@tool
def enable_cruisecontrol(namespace: str, kafka_instance: str) -> dict:
    """Enable Cruise Control on a Kafka instance by adding spec.cruiseControl={}."""
    return _run([
        "oc", "patch", "kafka", kafka_instance, "-n", namespace,
        "--type=json",
        '-p=[{"op":"add","path":"/spec/cruiseControl","value":{}}]',
    ])


# ---------------------------------------------------------------------------
# KafkaRebalance
# ---------------------------------------------------------------------------

@tool
def create_kafkarebalance(yaml_manifest: str) -> dict:
    """Apply a KafkaRebalance YAML manifest (passed as a string) using oc apply."""
    return _run(["oc", "apply", "-f", "-"], stdin=yaml_manifest)


@tool
def get_kafkarebalance_status(namespace: str, rebalance_name: str) -> dict:
    """Return the full status of a KafkaRebalance resource as JSON."""
    return _run([
        "oc", "get", "kafkarebalance", rebalance_name, "-n", namespace, "-o", "json",
    ])


@tool
def approve_kafkarebalance(namespace: str, rebalance_name: str) -> dict:
    """Approve a KafkaRebalance by setting the strimzi.io/rebalance=approve annotation."""
    return _run([
        "oc", "annotate", "kafkarebalance", rebalance_name, "-n", namespace,
        "strimzi.io/rebalance=approve",
        "--overwrite",
    ])
