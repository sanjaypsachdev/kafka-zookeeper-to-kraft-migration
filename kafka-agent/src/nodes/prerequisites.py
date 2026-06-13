"""
Phase 1 — Prerequisites & Node Pool Migration

The agent in this node:
  1. Verifies oc login and namespace/kafka existence
  2. Checks whether the cluster is already on KRaft (exit early) or mid-migration (resume)
  3. Detects whether the Kafka instance is already using KafkaNodePools
  4. If not, migrates it: creates a broker KafkaNodePool matching the existing spec,
     enables node-pools annotation, removes redundant spec.kafka.replicas/storage
  5. Detects and resolves the "kafka" pool name conflict (pool owned by another instance)
"""

from langchain_core.messages import HumanMessage
from langgraph.prebuilt import create_react_agent

from src.config import get_llm, Settings
from src.state import MigrationState
from src.tools import (
    check_oc_login,
    check_namespace,
    detect_kafkanodepool_api_version,
    get_kafka_resource,
    get_kafka_kraft_annotation,
    get_kafka_node_pools_annotation,
    get_kafka_replicas,
    get_kafka_storage,
    get_zookeeper_config,
    get_kafkanodepool_list,
    get_kafkanodepool,
    get_kafkanodepool_cluster_owner,
    get_pod_readiness,
    create_kafkanodepool,
    annotate_kafka,
    patch_kafka_json,
    enable_cruisecontrol,
    create_kafkarebalance,
    get_kafkarebalance_status,
    approve_kafkarebalance,
    delete_kafkanodepool,
)

TOOLS = [
    check_oc_login,
    check_namespace,
    detect_kafkanodepool_api_version,
    get_kafka_resource,
    get_kafka_kraft_annotation,
    get_kafka_node_pools_annotation,
    get_kafka_replicas,
    get_kafka_storage,
    get_zookeeper_config,
    get_kafkanodepool_list,
    get_kafkanodepool,
    get_kafkanodepool_cluster_owner,
    get_pod_readiness,
    create_kafkanodepool,
    annotate_kafka,
    patch_kafka_json,
    enable_cruisecontrol,
    create_kafkarebalance,
    get_kafkarebalance_status,
    approve_kafkarebalance,
    delete_kafkanodepool,
]

SYSTEM_PROMPT = """You are an OpenShift Kafka migration expert. Your task is to complete the
PREREQUISITES phase of a ZooKeeper-to-KRaft migration.

Work through these steps in order:

1. VERIFY ENVIRONMENT
   - Call check_oc_login to confirm the CLI is available and authenticated.
   - Call check_namespace(namespace) to confirm the target namespace exists.
   - Call get_kafka_resource(namespace, kafka_instance) to confirm the Kafka instance exists.
   - Call get_kafka_kraft_annotation(namespace, kafka_instance) and check the value:
       * "enabled"   → migration already complete; report success and STOP (no further action needed)
       * "migration"  → migration already in progress; report this as a warning and continue
       * "none" or "" → not yet started; continue

2. DETECT API VERSION
   - Call detect_kafkanodepool_api_version(namespace) and note the result for use in YAML manifests.

3. CHECK NODE POOL STATUS
   - Call get_kafka_node_pools_annotation(namespace, kafka_instance).
   - Call get_kafkanodepool_list(namespace, kafka_instance).
   - If the annotation is "enabled" AND at least one broker node pool exists → node pools already
     configured; skip to step 6.
   - Otherwise, node pool migration is required.

4. HANDLE NODE POOL NAME CONFLICT
   Before creating a broker pool named "kafka", check if that name is already taken:
   - Call get_kafkanodepool_cluster_owner(namespace, "kafka").
   - If the result is non-empty AND different from kafka_instance, the name is taken by another
     cluster. You must free it by migrating the existing pool:
       a. Call enable_cruisecontrol(namespace, <owner_instance>) to enable Cruise Control on the
          other cluster. Wait for Cruise Control pods to be ready using get_pod_readiness with
          label 'strimzi.io/cluster=<owner>,strimzi.io/kind=Kafka'.
       b. Get the existing pool's node IDs via get_kafkanodepool(namespace, "kafka") and parse
          the status.nodeIds field.
       c. Get the existing pool's storage config and replica count.
       d. Create a new pool for the other cluster named "kafka-<owner>" using create_kafkanodepool.
          Wait for all its pods to be Running and ready.
       e. Create a KafkaRebalance resource in mode=remove-brokers targeting the original node IDs.
          Wait for status condition ProposalReady=True using get_kafkarebalance_status, then call
          approve_kafkarebalance. Wait for condition Ready=True.
       f. Delete the old pool: delete_kafkanodepool(namespace, "kafka").
     Now the name "kafka" is available.

5. MIGRATE KAFKA TO NODE POOLS
   - Get the current replica count: get_kafka_replicas(namespace, kafka_instance)
   - Get the current storage config: get_kafka_storage(namespace, kafka_instance)
   - Determine storage YAML. Handle these cases:
       * type=jbod: build volumes array from the existing volumes field.
       * type=persistent-claim: use the same type, size, and class.
       * type=ephemeral: use ephemeral (no size needed).
   - Build and apply a KafkaNodePool manifest with role=broker using create_kafkanodepool.
     Use the apiVersion detected in step 2. Wait for pods to be ready using get_pod_readiness
     with label 'strimzi.io/cluster=<kafka_instance>,strimzi.io/pool-name=kafka'.
   - Enable node pools: annotate_kafka(namespace, kafka_instance, "strimzi.io/node-pools", "enabled")
   - Remove the now-redundant fields from the Kafka resource:
       patch_kafka_json with op=remove on /spec/kafka/replicas
       patch_kafka_json with op=remove on /spec/kafka/storage
     Use try-and-ignore if those fields don't exist (the patch may return a 422 which is fine).

6. FINAL VERIFICATION
   - Call get_kafkanodepool_list(namespace, kafka_instance) to confirm at least one broker pool exists.
   - Report all findings, including:
       * The detected API version (for use in later phases)
       * Whether node pools were already present or were just created
       * Any warnings encountered
       * Whether a pool name conflict existed and how it was resolved

Be precise and methodical. Always check the output of each tool call before proceeding.
If any step fails, report the error clearly and stop rather than continuing in an unknown state.
"""


def prerequisites_node(state: MigrationState) -> dict:
    settings = Settings()
    llm = get_llm(settings)
    agent = create_react_agent(llm, TOOLS, prompt=SYSTEM_PROMPT)

    task = (
        f"Run the prerequisites phase for Kafka instance '{state['kafka_instance']}' "
        f"in namespace '{state['namespace']}'.\n"
        f"skip_prereq_check={state['skip_prereq_check']}"
    )

    result = agent.invoke({"messages": [HumanMessage(content=task)]})
    new_messages = result["messages"]

    # Extract the final assistant message for phase summary
    final_text = ""
    for msg in reversed(new_messages):
        if hasattr(msg, "content") and msg.content:
            final_text = msg.content if isinstance(msg.content, str) else str(msg.content)
            break

    # Detect early-exit condition (already on KRaft)
    already_done = "already complete" in final_text.lower() or "already enabled" in final_text.lower()

    return {
        "messages": new_messages,
        "current_phase": "prerequisites",
        "phase_results": {**state.get("phase_results", {}), "prerequisites": "success"},
        "kraft_annotation": "enabled" if already_done else state.get("kraft_annotation", "none"),
    }
