"""
LangGraph StateGraph for the ZooKeeper → KRaft migration workflow.

Graph topology:
  START
    └─► prerequisites
          ├─► [END]              (if already on KRaft)
          └─► controller
                └─► migration
                      ├─► [END]  (if migration failed)
                      └─► approval   ← human-in-the-loop interrupt
                            └─► activation
                                  └─► verification
                                        └─► END
"""

from langgraph.checkpoint.memory import MemorySaver
from langgraph.graph import END, START, StateGraph
from langgraph.types import interrupt

from src.nodes.activation import activation_node
from src.nodes.controller import controller_node
from src.nodes.migration import migration_node
from src.nodes.prerequisites import prerequisites_node
from src.nodes.verification import verification_node
from src.state import MigrationState


# ---------------------------------------------------------------------------
# Human-in-the-loop approval node
# ---------------------------------------------------------------------------

def approval_node(state: MigrationState) -> dict:
    """
    Pause the graph and ask the operator whether to proceed with enabling KRaft mode.
    LangGraph's interrupt() serialises state to the checkpointer and raises an exception
    that the caller handles — execution resumes when the graph is re-invoked with the
    operator's answer in the Command.resume value.
    """
    phase_summary = "\n".join(
        f"  {phase}: {status}"
        for phase, status in state.get("phase_results", {}).items()
    )
    decision: str = interrupt(
        {
            "message": (
                "The migration has reached KRaftPostMigration state.\n"
                "The cluster is currently writing metadata to BOTH ZooKeeper and KRaft.\n\n"
                "Phase summary so far:\n"
                f"{phase_summary}\n\n"
                "Enabling KRaft mode will restart all Kafka brokers and controllers,\n"
                "switching the cluster to KRaft-only metadata management.\n\n"
                "Type 'yes' to proceed or 'no' to abort:"
            )
        }
    )
    approved = decision.strip().lower() in ("yes", "y", "proceed")
    return {
        "phase_results": {
            **state.get("phase_results", {}),
            "approval": "approved" if approved else "rejected",
        },
    }


# ---------------------------------------------------------------------------
# Routing functions (conditional edges)
# ---------------------------------------------------------------------------

def route_after_prerequisites(state: MigrationState) -> str:
    """Skip to END if already on KRaft; otherwise continue to controller creation."""
    annotation = state.get("kraft_annotation", "none")
    if annotation == "enabled":
        return "end"
    return "controller"


def route_after_migration(state: MigrationState) -> str:
    """Only proceed to approval if migration reached KRaftPostMigration."""
    results = state.get("phase_results", {})
    if results.get("migration") == "success":
        return "approval"
    return "end"


def route_after_approval(state: MigrationState) -> str:
    """Proceed to activation only when the operator approved."""
    results = state.get("phase_results", {})
    if results.get("approval") == "approved":
        return "activation"
    return "end"


# ---------------------------------------------------------------------------
# Graph builder
# ---------------------------------------------------------------------------

def build_graph() -> StateGraph:
    builder = StateGraph(MigrationState)

    # Nodes
    builder.add_node("prerequisites", prerequisites_node)
    builder.add_node("controller", controller_node)
    builder.add_node("migration", migration_node)
    builder.add_node("approval", approval_node)
    builder.add_node("activation", activation_node)
    builder.add_node("verification", verification_node)

    # Edges
    builder.add_edge(START, "prerequisites")
    builder.add_conditional_edges(
        "prerequisites",
        route_after_prerequisites,
        {"controller": "controller", "end": END},
    )
    builder.add_edge("controller", "migration")
    builder.add_conditional_edges(
        "migration",
        route_after_migration,
        {"approval": "approval", "end": END},
    )
    builder.add_conditional_edges(
        "approval",
        route_after_approval,
        {"activation": "activation", "end": END},
    )
    builder.add_edge("activation", "verification")
    builder.add_edge("verification", END)

    return builder


def compile_graph():
    """Compile the graph with an in-memory checkpointer for interrupt/resume support."""
    builder = build_graph()
    checkpointer = MemorySaver()
    return builder.compile(checkpointer=checkpointer)
