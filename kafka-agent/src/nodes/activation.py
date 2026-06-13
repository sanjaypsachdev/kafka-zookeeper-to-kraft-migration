"""
Phase 4 — Enable Full KRaft Mode

This node runs after human approval. It sets strimzi.io/kraft=enabled on the Kafka
resource, which causes Strimzi to restart the cluster in KRaft-only mode.
"""

from langchain_core.messages import HumanMessage
from langgraph.prebuilt import create_react_agent

from src.config import get_llm, Settings
from src.state import MigrationState
from src.tools import (
    annotate_kafka,
    get_migration_state,
    get_pod_readiness,
)

TOOLS = [
    annotate_kafka,
    get_migration_state,
    get_pod_readiness,
]

SYSTEM_PROMPT = """You are an OpenShift Kafka migration expert. Your task is to complete the
ACTIVATION phase of a ZooKeeper-to-KRaft migration.

Steps:

1. ENABLE KRAFT MODE
   Call annotate_kafka(namespace, kafka_instance, "strimzi.io/kraft", "enabled").
   This tells the Strimzi operator to switch the cluster to KRaft-only metadata management.

2. WAIT FOR RESTART
   The operator will restart broker and controller pods. Poll pod readiness:
     get_pod_readiness with label 'strimzi.io/cluster=<kafka_instance>'
   Wait until all pods return to Running+Ready. This can take several minutes.

3. CHECK MIGRATION STATE
   Call get_migration_state(namespace, kafka_instance) and confirm the state is
   transitioning away from KRaftPostMigration. It will pass through intermediate states
   before reaching KRaft in the verification phase.

4. REPORT
   Confirm that the strimzi.io/kraft=enabled annotation was applied successfully and
   that pods are restarting or have restarted.
"""


def activation_node(state: MigrationState) -> dict:
    settings = Settings()
    llm = get_llm(settings)
    agent = create_react_agent(llm, TOOLS, prompt=SYSTEM_PROMPT)

    task = (
        f"Enable full KRaft mode for Kafka instance '{state['kafka_instance']}' "
        f"in namespace '{state['namespace']}'."
    )

    result = agent.invoke({"messages": [HumanMessage(content=task)]})
    new_messages = result["messages"]

    return {
        "messages": new_messages,
        "current_phase": "activation",
        "phase_results": {**state.get("phase_results", {}), "activation": "success"},
    }
