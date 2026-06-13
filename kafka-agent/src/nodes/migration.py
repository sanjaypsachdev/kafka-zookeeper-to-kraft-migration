"""
Phase 3 — Enable and Monitor KRaft Migration

The agent in this node:
  - Annotates the Kafka resource with strimzi.io/kraft=migration to start dual-write mode
  - Polls the migration state through all three intermediate states:
      KRaftMigration → KRaftDualWriting → KRaftPostMigration
  - Reports progress at each state transition
  - Surfaces a clear summary once KRaftPostMigration is reached (prerequisite for approval)
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
MIGRATION phase of a ZooKeeper-to-KRaft migration.

Steps:

1. ENABLE MIGRATION MODE
   Call annotate_kafka(namespace, kafka_instance, "strimzi.io/kraft", "migration").
   This triggers the Strimzi operator to start dual-write mode (writing metadata to both
   ZooKeeper and the KRaft controller pool).

2. WAIT FOR INITIAL STATE
   Call get_migration_state(namespace, kafka_instance) repeatedly.
   Wait for the state to leave "Unknown" or empty and become "KRaftMigration".
   This may take 30-60 seconds after the annotation is applied.

3. MONITOR STATE PROGRESSION
   The migration moves through three states in order:
     KRaftMigration  →  KRaftDualWriting  →  KRaftPostMigration

   Poll get_migration_state every ~10 seconds. Log each unique state transition.
   If a state has not changed for more than (wait_timeout / 3) seconds, surface a
   warning about possible stall and check pod readiness:
     get_pod_readiness with label 'strimzi.io/cluster=<kafka_instance>'

   Continue polling until state = "KRaftPostMigration".

4. REPORT
   When KRaftPostMigration is reached, report:
   - How long each state took
   - Current pod readiness
   - Confirmation that the cluster is ready for KRaft activation

   If the state does not reach KRaftPostMigration within wait_timeout seconds,
   report clearly and stop — do not proceed to activation.

Important: Do not annotate strimzi.io/kraft=enabled in this phase. That happens in the
next phase after human approval.
"""


def migration_node(state: MigrationState) -> dict:
    settings = Settings()
    llm = get_llm(settings)
    agent = create_react_agent(llm, TOOLS, prompt=SYSTEM_PROMPT)

    task = (
        f"Enable and monitor KRaft migration for Kafka instance '{state['kafka_instance']}' "
        f"in namespace '{state['namespace']}'.\n"
        f"wait_timeout={state.get('wait_timeout', 3600)} seconds"
    )

    result = agent.invoke({"messages": [HumanMessage(content=task)]})
    new_messages = result["messages"]

    # Extract final state from the last assistant message
    final_text = ""
    for msg in reversed(new_messages):
        if hasattr(msg, "content") and msg.content:
            final_text = msg.content if isinstance(msg.content, str) else str(msg.content)
            break

    reached_post_migration = "KRaftPostMigration" in final_text

    return {
        "messages": new_messages,
        "current_phase": "migration",
        "migration_state": "KRaftPostMigration" if reached_post_migration else "unknown",
        "phase_results": {
            **state.get("phase_results", {}),
            "migration": "success" if reached_post_migration else "error",
        },
    }
