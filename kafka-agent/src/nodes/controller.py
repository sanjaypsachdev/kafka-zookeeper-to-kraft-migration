"""
Phase 2 — Create the KRaft Controller Node Pool

The agent in this node:
  - Inspects the existing broker node pool to determine default storage config
  - Falls back to ZooKeeper storage config when broker config is unavailable
  - Respects user-provided overrides (storage type, sizes, class, replica count)
  - Builds and applies the KafkaNodePool manifest with role=controller
  - Waits for all controller pods to reach Running+Ready state
"""

from langchain_core.messages import HumanMessage
from langgraph.prebuilt import create_react_agent

from src.config import get_llm, Settings
from src.state import MigrationState
from src.tools import (
    detect_kafkanodepool_api_version,
    get_kafkanodepool_list,
    get_kafkanodepool,
    get_zookeeper_config,
    get_pod_readiness,
    create_kafkanodepool,
)

TOOLS = [
    detect_kafkanodepool_api_version,
    get_kafkanodepool_list,
    get_kafkanodepool,
    get_zookeeper_config,
    get_pod_readiness,
    create_kafkanodepool,
]

SYSTEM_PROMPT = """You are an OpenShift Kafka migration expert. Your task is to complete the
CONTROLLER NODE POOL phase of a ZooKeeper-to-KRaft migration.

Steps:

1. DETERMINE CONFIGURATION
   The user may have provided overrides (controller_pool_name, controller_replicas,
   controller_storage_type, controller_storage_sizes, controller_storage_class).
   Use them when present. Fall back to these defaults when they are empty:
   - pool name      → "controller-{kafka_instance}"
   - replicas       → ZooKeeper replica count (from get_zookeeper_config)
   - storage type   → match the broker node pool storage type
   - storage size   → match the broker node pool storage size, or ZooKeeper storage size
   - storage class  → match the broker node pool storage class, or ZooKeeper storage class

2. INSPECT BROKER POOL
   - Call get_kafkanodepool_list(namespace, kafka_instance) to find the broker pool.
   - Call get_kafkanodepool(namespace, "<broker_pool_name>") to get its storage spec.
   - Parse spec.storage: extract type, size (if persistent-claim), class (if set),
     and volumes (if jbod).

3. INSPECT ZOOKEEPER (fallback for replicas/storage)
   - Call get_zookeeper_config(namespace, kafka_instance) for ZooKeeper replicas and storage.
   - Use ZooKeeper replica count if controller_replicas is not set.
   - Use ZooKeeper storage class if broker storage class is unavailable and
     controller_storage_class is not set.

4. BUILD STORAGE YAML
   Build the storage section of the KafkaNodePool manifest:
   - persistent-claim:
       storage:
         type: persistent-claim
         size: <size>
         class: <class>
         deleteClaim: false
   - ephemeral:
       storage:
         type: ephemeral
   - jbod (user specified comma-separated sizes, e.g. "100Gi,200Gi"):
       storage:
         type: jbod
         volumes:
           - id: 0
             type: persistent-claim
             size: <first size>
             class: <class>
             deleteClaim: false
           - id: 1
             ...
   - jbod (copied from broker pool): replicate the volumes array exactly.

5. BUILD AND APPLY MANIFEST
   Call detect_kafkanodepool_api_version(namespace) for the apiVersion.
   Build the complete KafkaNodePool YAML:

     apiVersion: <detected_api_version>
     kind: KafkaNodePool
     metadata:
       name: <controller_pool_name>
       namespace: <namespace>
       labels:
         strimzi.io/cluster: <kafka_instance>
     spec:
       replicas: <replicas>
       roles:
         - controller
       storage:
         <storage yaml>

   Call create_kafkanodepool(yaml_manifest=<the yaml string>).
   If apply fails, report the error and stop.

6. WAIT FOR PODS
   Call get_pod_readiness with label selector:
     "strimzi.io/cluster=<kafka_instance>,strimzi.io/pool-name=<controller_pool_name>"
   Repeat until all pods are ready (ready == total AND total > 0) or after 20 attempts
   (with ~30-second reasoning between checks). If pods are not ready after exhausting
   attempts, report clearly.

7. REPORT
   Summarize: controller pool name, replicas, storage config, and pod readiness status.
"""


def controller_node(state: MigrationState) -> dict:
    settings = Settings()
    llm = get_llm(settings)
    agent = create_react_agent(llm, TOOLS, prompt=SYSTEM_PROMPT)

    pool_name = state.get("controller_pool_name") or f"controller-{state['kafka_instance']}"

    task = (
        f"Create the KRaft controller node pool for Kafka instance '{state['kafka_instance']}' "
        f"in namespace '{state['namespace']}'.\n"
        f"controller_pool_name={pool_name or '(auto)'}\n"
        f"controller_replicas={state.get('controller_replicas') or '(auto from ZooKeeper)'}\n"
        f"controller_storage_type={state.get('controller_storage_type') or '(auto from broker)'}\n"
        f"controller_storage_sizes={state.get('controller_storage_sizes') or '(auto from broker)'}\n"
        f"controller_storage_class={state.get('controller_storage_class') or '(auto from broker)'}"
    )

    result = agent.invoke({"messages": [HumanMessage(content=task)]})
    new_messages = result["messages"]

    return {
        "messages": new_messages,
        "current_phase": "controller",
        "phase_results": {**state.get("phase_results", {}), "controller": "success"},
    }
