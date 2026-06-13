from typing import Annotated
from typing_extensions import TypedDict
from langgraph.graph.message import add_messages


class MigrationState(TypedDict):
    # User-supplied inputs
    namespace: str
    kafka_instance: str
    controller_pool_name: str
    controller_replicas: int
    controller_storage_type: str
    controller_storage_sizes: str
    controller_storage_class: str
    wait_timeout: int
    skip_prereq_check: bool

    # Discovered cluster facts
    kraft_api_version: str
    kraft_annotation: str        # "none" | "migration" | "enabled"
    using_node_pools: bool
    existing_pool_conflict: bool
    existing_pool_owner: str     # Kafka instance that owns the conflicting "kafka" pool

    # Migration tracking
    current_phase: str
    migration_state: str         # KRaftMigration | KRaftDualWriting | KRaftPostMigration
    metadata_state: str          # PreKRaft | KRaft

    # Agent conversation history — accumulated across all phase nodes
    messages: Annotated[list, add_messages]

    # Per-phase outcomes
    phase_results: dict          # phase_name -> "success" | "skipped" | "error"
    errors: list[str]
    warnings: list[str]
