# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A bash automation script and documentation guide for migrating Apache Kafka clusters from ZooKeeper-based metadata management to KRaft mode on OpenShift, using the Strimzi operator (Red Hat Streams for Apache Kafka).

## Running the Script

```bash
# Basic usage (requires oc CLI logged in to OpenShift)
./zk-to-kafka-migration.sh <namespace> <kafka-instance-name>

# With all major options
./zk-to-kafka-migration.sh <namespace> <kafka-instance-name> \
  --controller-pool-name <name> \
  --controller-replicas <num> \
  --controller-storage-type <persistent-claim|ephemeral|jbod> \
  --controller-storage-sizes <size-or-comma-list> \
  --controller-storage-class <class> \
  --wait-timeout <seconds> \
  --skip-prereq-check

# Help
./zk-to-kafka-migration.sh --help
```

Prerequisites: `oc` CLI in PATH, logged in with `oc login <cluster-url>`, and appropriate RBAC in the target namespace.

## Architecture Overview

### Migration Phases (automated by the script)

1. **Node Pool Migration** — If the Kafka resource has direct `spec.kafka.replicas`/`spec.kafka.storage` (pre-node-pool style), the script creates a `KafkaNodePool` with role `broker`, annotates the Kafka resource with `strimzi.io/node-pools=enabled`, then removes the redundant fields.

2. **Existing Pool Conflict Resolution** — If a `kafka`-named `KafkaNodePool` already exists in the namespace but belongs to a different cluster, the script enables Cruise Control on that cluster, creates a new pool for it, runs a `KafkaRebalance` in `remove-brokers` mode to evacuate partitions, then deletes the old pool.

3. **Controller Pool Creation** — Creates a `KafkaNodePool` with role `controller` (default name: `controller-<kafka-instance-name>`), using ZooKeeper replica count and storage as defaults unless overridden.

4. **Migration Initiation** — Annotates the Kafka resource with `strimzi.io/kraft=migration` to start dual-write mode.

5. **State Monitoring** — Polls `status.kafkaMigrationStatus.state` through: `KRaftMigration` → `KRaftDualWriting` → `KRaftPostMigration`.

6. **KRaft Activation** — Annotates with `strimzi.io/kraft=enabled` to switch the cluster to KRaft-only.

7. **Cleanup** — Patches out `spec.zookeeper`, `spec.kafka.config/log.message.format.version`, and `spec.kafka.config/inter.broker.protocol.version`.

### Key Kubernetes Resources Involved

- `Kafka` — cluster-wide config; migration state tracked at `status.kafkaMigrationStatus.state` and `status.kafkaMetadataState.state`
- `KafkaNodePool` — node group with role `broker` or `controller`; associated to a cluster via label `strimzi.io/cluster`
- `KafkaRebalance` — used in `remove-brokers` mode to evacuate partitions before deleting a pool

### JBOD Storage

The script handles both standard `persistent-claim` and multi-disk JBOD volumes. For JBOD, pass comma-separated sizes: `--controller-storage-sizes "100Gi,200Gi,300Gi"`. The `KafkaNodePool` YAML structure for JBOD uses `spec.storage.type: jbod` with a `volumes` list.

### API Version Detection

`get_kafkanodepool_api_version()` determines the correct `apiVersion` at runtime by checking existing resources, then the CRD, then `oc api-resources`. Falls back to `kafka.strimzi.io/v1beta2`.

## Updating Architecture Diagrams

Diagram source is in `mermaid-diagrams.md`. To regenerate the PNGs in `images/`:

```bash
npm install -g @mermaid-js/mermaid-cli
mmdc -i mermaid-diagrams.md -o images/kafka-zookeeper-architecture.png
mmdc -i mermaid-diagrams.md -o images/kafka-kraft-architecture.png
```

Or paste the Mermaid blocks into https://mermaid.live/ and download.
