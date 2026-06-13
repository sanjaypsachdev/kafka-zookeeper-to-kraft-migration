"""
Phase 5 — Verify KRaft State and Clean Up ZooKeeper Configuration

The agent in this node:
  - Polls until kafkaMetadataState reaches "KRaft" (passes through "PreKRaft" first)
  - Verifies the strimzi.io/kraft annotation is "enabled"
  - Removes ZooKeeper-related configuration from the Kafka resource:
      * spec.zookeeper
      * spec.kafka.config/log.message.format.version   (if present)
      * spec.kafka.config/inter.broker.protocol.version (if present)
  - Reports a final migration summary
"""

from langchain_core.messages import HumanMessage
from langgraph.prebuilt import create_react_agent

from src.config import get_llm, Settings
from src.state import MigrationState
from src.tools import (
    get_kafka_kraft_annotation,
    get_migration_state,
    get_pod_readiness,
    patch_kafka_json,
    get_kafka_resource,
)

TOOLS = [
    get_kafka_kraft_annotation,
    get_migration_state,
    get_pod_readiness,
    patch_kafka_json,
    get_kafka_resource,
]

SYSTEM_PROMPT = """You are an OpenShift Kafka migration expert. Your task is to complete the
VERIFICATION AND CLEANUP phase of a ZooKeeper-to-KRaft migration.

Steps:

1. POLL FOR KRAFT METADATA STATE
   Call get_migration_state(namespace, kafka_instance) repeatedly until it returns "KRaft".
   The state typically goes: KRaftPostMigration → PreKRaft → KRaft.
   Log each unique transition. If it does not reach "KRaft" within wait_timeout seconds,
   report clearly.

2. VERIFY ANNOTATION
   Call get_kafka_kraft_annotation(namespace, kafka_instance).
   Confirm the value is "enabled".

3. CHECK FULL KAFKA RESOURCE
   Call get_kafka_resource(namespace, kafka_instance) to inspect the current spec.
   Check which ZooKeeper-related fields are still present:
     - spec.zookeeper
     - spec.kafka.config["log.message.format.version"]
     - spec.kafka.config["inter.broker.protocol.version"]

4. CLEAN UP ZOOKEEPER CONFIG
   For each field that is present, issue a patch_kafka_json call:
   - Remove spec.zookeeper:
       '[{"op":"remove","path":"/spec/zookeeper"}]'
   - Remove log.message.format.version (if present):
       '[{"op":"remove","path":"/spec/kafka/config/log.message.format.version"}]'
   - Remove inter.broker.protocol.version (if present):
       '[{"op":"remove","path":"/spec/kafka/config/inter.broker.protocol.version"}]'

   If a remove patch fails (field may already be absent), log a warning and continue —
   do not treat a missing field as a fatal error.

5. FINAL REPORT
   Provide a clear migration completion summary:
   - Confirmation that kafkaMetadataState = KRaft
   - Confirmation that strimzi.io/kraft annotation = enabled
   - Which ZooKeeper fields were removed
   - Any warnings encountered
   - Overall migration result: SUCCESS or PARTIAL (with reasons)
"""


def verification_node(state: MigrationState) -> dict:
    settings = Settings()
    llm = get_llm(settings)
    agent = create_react_agent(llm, TOOLS, prompt=SYSTEM_PROMPT)

    task = (
        f"Verify KRaft migration and clean up ZooKeeper config for Kafka instance "
        f"'{state['kafka_instance']}' in namespace '{state['namespace']}'.\n"
        f"wait_timeout={state.get('wait_timeout', 3600)} seconds"
    )

    result = agent.invoke({"messages": [HumanMessage(content=task)]})
    new_messages = result["messages"]

    final_text = ""
    for msg in reversed(new_messages):
        if hasattr(msg, "content") and msg.content:
            final_text = msg.content if isinstance(msg.content, str) else str(msg.content)
            break

    completed = "KRaft" in final_text and "success" in final_text.lower()

    return {
        "messages": new_messages,
        "current_phase": "verification",
        "metadata_state": "KRaft" if completed else "unknown",
        "phase_results": {
            **state.get("phase_results", {}),
            "verification": "success" if completed else "partial",
        },
    }
