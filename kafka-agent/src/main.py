"""
CLI entry point for the Kafka ZooKeeper → KRaft migration agent.

Usage:
  uv run python -m src.main <namespace> <kafka-instance-name> [options]

The interface mirrors the original zk-to-kafka-migration.sh bash script.
"""

import sys
import uuid

import click
from langgraph.types import Command
from rich.console import Console
from rich.panel import Panel
from rich.rule import Rule
from rich.text import Text

from src.graph import compile_graph
from src.state import MigrationState

console = Console()

PHASE_LABELS = {
    "prerequisites": "Phase 1 — Prerequisites & Node Pool Migration",
    "controller": "Phase 2 — Create Controller Node Pool",
    "migration": "Phase 3 — Enable & Monitor KRaft Migration",
    "approval": "Phase 4 — Human Approval",
    "activation": "Phase 5 — Enable Full KRaft Mode",
    "verification": "Phase 6 — Verify & Clean Up ZooKeeper Config",
}


def _print_phase_banner(phase: str) -> None:
    label = PHASE_LABELS.get(phase, phase)
    console.print(Rule(f"[bold cyan]{label}[/bold cyan]"))


def _print_agent_message(text: str) -> None:
    console.print(Panel(text, border_style="dim", padding=(0, 1)))


def _extract_last_agent_text(messages: list) -> str:
    for msg in reversed(messages):
        content = getattr(msg, "content", None)
        if content:
            return content if isinstance(content, str) else str(content)
    return ""


@click.command(
    name="kafka-migration-agent",
    help=(
        "AI agent that automates the migration of a Kafka instance from "
        "ZooKeeper to KRaft on OpenShift."
    ),
)
@click.argument("namespace")
@click.argument("kafka_instance_name")
@click.option("--controller-pool-name", default="", help="Name for the controller node pool.")
@click.option("--controller-replicas", default=0, type=int, help="Number of controller replicas.")
@click.option(
    "--controller-storage-type",
    default="",
    type=click.Choice(["", "persistent-claim", "ephemeral", "jbod"], case_sensitive=False),
    help="Storage type for the controller node pool.",
)
@click.option(
    "--controller-storage-sizes",
    default="",
    help="Storage size(s). Single value for non-JBOD, comma-separated for JBOD (e.g. '100Gi,200Gi').",
)
@click.option("--controller-storage-class", default="", help="Storage class for the controller node pool.")
@click.option(
    "--wait-timeout",
    default=3600,
    show_default=True,
    help="Timeout in seconds for each migration state wait.",
)
@click.option("--skip-prereq-check", is_flag=True, default=False, help="Skip prerequisite checks.")
def main(
    namespace: str,
    kafka_instance_name: str,
    controller_pool_name: str,
    controller_replicas: int,
    controller_storage_type: str,
    controller_storage_sizes: str,
    controller_storage_class: str,
    wait_timeout: int,
    skip_prereq_check: bool,
) -> None:
    console.print(
        Panel.fit(
            Text.from_markup(
                f"[bold]Kafka ZooKeeper → KRaft Migration Agent[/bold]\n"
                f"Namespace     : [cyan]{namespace}[/cyan]\n"
                f"Kafka Instance: [cyan]{kafka_instance_name}[/cyan]"
            ),
            border_style="blue",
        )
    )

    # Build initial state
    initial_state: MigrationState = {
        "namespace": namespace,
        "kafka_instance": kafka_instance_name,
        "controller_pool_name": controller_pool_name,
        "controller_replicas": controller_replicas,
        "controller_storage_type": controller_storage_type,
        "controller_storage_sizes": controller_storage_sizes,
        "controller_storage_class": controller_storage_class,
        "wait_timeout": wait_timeout,
        "skip_prereq_check": skip_prereq_check,
        # Initialise all state fields to defaults
        "kraft_api_version": "",
        "kraft_annotation": "none",
        "using_node_pools": False,
        "existing_pool_conflict": False,
        "existing_pool_owner": "",
        "current_phase": "",
        "migration_state": "",
        "metadata_state": "",
        "messages": [],
        "phase_results": {},
        "errors": [],
        "warnings": [],
    }

    graph = compile_graph()
    thread_id = str(uuid.uuid4())
    config = {"configurable": {"thread_id": thread_id}}

    # ---------------------------------------------------------------------------
    # Run the graph, streaming events to surface phase transitions in real time
    # ---------------------------------------------------------------------------
    current_phase = ""
    interrupted = False

    for event in graph.stream(initial_state, config=config, stream_mode="values"):
        phase = event.get("current_phase", "")
        if phase and phase != current_phase:
            current_phase = phase
            _print_phase_banner(phase)

        # Print the latest agent message if new
        messages = event.get("messages", [])
        if messages:
            last_text = _extract_last_agent_text(messages)
            if last_text:
                _print_agent_message(last_text)

    # Check whether the graph is interrupted (waiting for human approval)
    snapshot = graph.get_state(config)
    if snapshot.next:
        interrupted = True
        console.print()
        console.print(Rule("[bold yellow]Human Approval Required[/bold yellow]"))

        # The interrupt value is stored in the snapshot tasks
        for task in snapshot.tasks:
            if hasattr(task, "interrupts") and task.interrupts:
                for intr in task.interrupts:
                    console.print(Panel(intr.value.get("message", str(intr.value)), border_style="yellow"))

    if interrupted:
        # Prompt operator for decision
        decision = click.prompt(
            "\nYour decision",
            default="no",
            show_default=True,
        )

        console.print()
        console.print(Rule("[bold cyan]Resuming Migration[/bold cyan]"))

        # Resume graph with operator's decision
        for event in graph.stream(
            Command(resume=decision),
            config=config,
            stream_mode="values",
        ):
            phase = event.get("current_phase", "")
            if phase and phase != current_phase:
                current_phase = phase
                _print_phase_banner(phase)

            messages = event.get("messages", [])
            if messages:
                last_text = _extract_last_agent_text(messages)
                if last_text:
                    _print_agent_message(last_text)

    # ---------------------------------------------------------------------------
    # Final summary
    # ---------------------------------------------------------------------------
    final_state = graph.get_state(config).values
    phase_results = final_state.get("phase_results", {})

    console.print()
    console.print(Rule("[bold]Migration Summary[/bold]"))
    for phase, result in phase_results.items():
        colour = "green" if result == "success" else "yellow" if result == "skipped" else "red"
        label = PHASE_LABELS.get(phase, phase)
        console.print(f"  [{colour}]{result.upper():10}[/{colour}]  {label}")

    errors = final_state.get("errors", [])
    if errors:
        console.print()
        for err in errors:
            console.print(f"[red]ERROR:[/red] {err}")

    overall_ok = all(r in ("success", "skipped", "approved") for r in phase_results.values())
    console.print()
    if overall_ok:
        console.print("[bold green]Migration completed successfully.[/bold green]")
    else:
        console.print("[bold red]Migration completed with errors. Review the output above.[/bold red]")
        sys.exit(1)


if __name__ == "__main__":
    main()
