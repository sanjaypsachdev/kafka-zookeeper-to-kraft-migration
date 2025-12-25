# Migrating Kafka from ZooKeeper to KRaft in OpenShift

This guide walks you through the process of migrating a Kafka cluster from ZooKeeper-based metadata management to KRaft (Kafka Raft) mode in an OpenShift environment. KRaft eliminates the dependency on ZooKeeper, simplifying the architecture and improving performance.

## Overview

The migration process involves several key phases:

1. **Prerequisites**: Ensuring your Kafka instance is ready for migration
2. **Node Pool Migration**: Converting to KafkaNodePool architecture (if not already done)
3. **Controller Pool Creation**: Setting up KRaft controller nodes
4. **Migration Initiation**: Starting the dual-write phase
5. **State Monitoring**: Tracking progress through migration states
6. **KRaft Activation**: Enabling full KRaft mode
7. **Cleanup**: Removing ZooKeeper dependencies

## Why Migrate from ZooKeeper to KRaft?

KRaft (Kafka Raft) is the new metadata management system for Apache Kafka that replaces ZooKeeper. There are several compelling reasons to migrate:

### Simplified Architecture

- **Eliminates External Dependency**: KRaft removes the need for a separate ZooKeeper cluster, reducing the number of components you need to manage and monitor
- **Unified System**: Metadata management is now handled directly within Kafka, creating a more cohesive and self-contained system
- **Reduced Operational Overhead**: Fewer services to deploy, configure, and maintain means less complexity in your infrastructure

### Improved Performance and Scalability

- **Faster Metadata Operations**: KRaft provides faster metadata operations compared to ZooKeeper, resulting in quicker topic creation, partition reassignment, and configuration updates
- **Better Scalability**: KRaft can handle larger numbers of partitions and topics more efficiently than ZooKeeper-based clusters
- **Reduced Latency**: With metadata management integrated into Kafka, metadata operations have lower latency

### Enhanced Reliability

- **Simplified Failure Recovery**: KRaft's design simplifies failure recovery scenarios
- **Better Consistency**: The Raft consensus algorithm provides strong consistency guarantees for metadata operations
- **Reduced Failure Points**: Eliminating ZooKeeper removes a potential point of failure from your system

### Future-Proofing

- **ZooKeeper Deprecation**: Apache Kafka is moving away from ZooKeeper, and future versions will only support KRaft mode
- **New Features**: Many new Kafka features and improvements are being developed exclusively for KRaft mode
- **Long-term Support**: Migrating now ensures your cluster is ready for future Kafka versions and features

## Understanding Kafka Node Pools

Kafka Node Pools (KafkaNodePool) are a Kubernetes/OpenShift resource that allows you to manage Kafka broker and controller nodes as separate, configurable groups. This architecture provides greater flexibility and control over your Kafka cluster configuration.

### What are Node Pools?

A KafkaNodePool is a custom resource that defines a group of Kafka nodes (brokers or controllers) with specific characteristics:

- **Roles**: Each node pool can be configured with specific roles:
  - **Broker**: Handles data storage and client requests
  - **Controller**: Manages cluster metadata (used in KRaft mode)
  - **Both**: Can serve as both broker and controller (for smaller clusters)

- **Configuration**: Each pool can have its own:
  - Number of replicas
  - Storage configuration (type, size, storage class)
  - Resource limits and requests
  - JVM settings and other broker-specific configurations

### Benefits of Node Pools

- **Separation of Concerns**: Brokers and controllers can be managed independently, allowing you to scale and configure them separately based on their specific needs
- **Flexible Scaling**: Scale broker and controller pools independently based on workload requirements
- **Resource Optimization**: Allocate different resources to brokers (which handle data) versus controllers (which handle metadata)
- **Easier Management**: Node pools make it easier to manage heterogeneous Kafka clusters where different nodes may have different configurations

### Node Pool Architecture

In a traditional Kafka resource, broker configuration is embedded directly in the Kafka resource specification. With node pools:

- **Kafka Resource**: Defines cluster-wide settings, listeners, authorization, and other shared configurations
- **KafkaNodePool Resources**: Define individual groups of nodes with their specific configurations
- **Label-based Association**: Node pools are associated with a Kafka cluster through labels (`strimzi.io/cluster`)

This separation allows for more flexible cluster topologies and easier management of complex deployments.

## Architecture Comparison

The following diagrams illustrate the architectural differences between ZooKeeper-based and KRaft-based Kafka deployments on OpenShift.

### ZooKeeper-Based Architecture (Legacy)

In the traditional architecture, Kafka relies on an external ZooKeeper cluster for metadata management. This creates a dependency between two separate systems that must be managed and monitored independently.

![ZooKeeper-Based Kafka Architecture](images/kafka-zookeeper-architecture.png)

**Key Characteristics:**
- Separate ZooKeeper cluster required for metadata management
- Kafka brokers depend on ZooKeeper for all metadata operations
- Two separate systems to manage, monitor, and maintain
- ZooKeeper cluster must be sized and scaled independently

### KRaft-Based Architecture (Modern)

In the KRaft architecture, metadata management is handled by dedicated controller nodes within the Kafka cluster itself, eliminating the external ZooKeeper dependency.

![KRaft-Based Kafka Architecture](images/kafka-kraft-architecture.png)

**Key Characteristics:**
- No external ZooKeeper dependency - metadata managed within Kafka
- Controller nodes handle metadata using Raft consensus protocol
- Broker nodes handle data storage and client requests
- Unified system with independent scaling of controllers and brokers
- Node pools allow flexible configuration and management

### Migration Benefits Visualized

The migration from ZooKeeper to KRaft results in:

- **Reduced Components**: Eliminates the separate ZooKeeper cluster
- **Unified Management**: All components managed through Kafka and KafkaNodePool resources
- **Better Performance**: Integrated metadata management reduces latency
- **Simplified Operations**: Single system to monitor and maintain

## Prerequisites

Before beginning the migration, verify the following:

- You have access to the OpenShift cluster with appropriate permissions
- The `oc` CLI tool is installed and configured
- Your Kafka instance is running and healthy
- You know the namespace and Kafka instance name

Verify your Kafka instance exists:

```bash
oc get kafka <kafka-instance-name> -n <namespace>
```

Check if the instance is already using KRaft:

```bash
oc get kafka <kafka-instance-name> -n <namespace> -o jsonpath='{.metadata.annotations.strimzi\.io/kraft}'
```

If this returns `enabled`, your cluster is already running in KRaft mode and no migration is needed.

## Phase 1: Migrating to Node Pools

Before migrating to KRaft, your Kafka instance must use the KafkaNodePool architecture. If your Kafka resource still has direct broker configuration (spec.kafka.replicas and spec.kafka.storage), you need to migrate to node pools first.

### Checking Current Configuration

First, check if your Kafka instance is already using node pools:

```bash
oc get kafkanodepool -n <namespace> -l strimzi.io/cluster=<kafka-instance-name>
```

If no node pools are found, check if the Kafka resource has direct broker configuration:

```bash
oc get kafka <kafka-instance-name> -n <namespace> -o jsonpath='{.spec.kafka.replicas}'
```

### Handling Existing 'kafka' Node Pool Conflicts

If you're migrating multiple Kafka instances in the same namespace, you may encounter a situation where a node pool named `kafka` already exists for a different Kafka instance. In this case, you'll need to migrate that existing pool first.

Check if a `kafka` node pool exists for a different cluster:

```bash
oc get kafkanodepool kafka -n <namespace> -o jsonpath='{.metadata.labels.strimzi\.io/cluster}'
```

If this returns a different cluster name, you'll need to:

1. Enable Cruise Control for that existing Kafka instance (if not already enabled)
2. Create a new node pool for that instance
3. Use KafkaRebalance to migrate partitions from the old pool to the new pool
4. Delete the old `kafka` pool

This process is detailed in the "Migrating an Existing Node Pool" section below.

### Creating the Broker Node Pool

If your Kafka instance doesn't use node pools yet, extract the current configuration:

```bash
# Get Kafka replicas
oc get kafka <kafka-instance-name> -n <namespace> -o jsonpath='{.spec.kafka.replicas}'

# Get storage configuration
oc get kafka <kafka-instance-name> -n <namespace> -o jsonpath='{.spec.kafka.storage.type}'
oc get kafka <kafka-instance-name> -n <namespace> -o jsonpath='{.spec.kafka.storage.size}'
oc get kafka <kafka-instance-name> -n <namespace> -o jsonpath='{.spec.kafka.storage.class}'
```

Create a broker node pool with the same configuration. Replace the placeholders with your actual values:

```bash
cat <<EOF | oc apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: kafka
  namespace: <namespace>
  labels:
    strimzi.io/cluster: <kafka-instance-name>
spec:
  replicas: <kafka-replicas>
  roles:
    - broker
  storage:
    type: <storage-type>
    size: <storage-size>
    class: <storage-class>
EOF
```

NOTE: Above KafkaNodePool is using non-jbod based storage, update it accordingly if you want to use jbod based storage.

Wait for the node pool pods to become ready:

```bash
oc get pods -n <namespace> -l strimzi.io/cluster=<kafka-instance-name>,strimzi.io/pool-name=kafka --field-selector=status.phase=Running
```

Verify that all pods show `Ready` in the READY column (e.g., `1/1` or `2/2`). All pods should be in `Running` state and ready before proceeding.

### Enabling Node Pools in Kafka Resource

Once the node pool is ready, enable node pools in your Kafka resource:

```bash
oc annotate kafka <kafka-instance-name> -n <namespace> \
  strimzi.io/node-pools=enabled \
  --overwrite
```

### Removing Replicated Properties

After node pools are enabled and working, remove the replicated properties from the Kafka resource:

```bash
# Remove spec.kafka.replicas
oc patch kafka <kafka-instance-name> -n <namespace> \
  --type=json \
  -p='[{"op": "remove", "path": "/spec/kafka/replicas"}]'

# Remove spec.kafka.storage
oc patch kafka <kafka-instance-name> -n <namespace> \
  --type=json \
  -p='[{"op": "remove", "path": "/spec/kafka/storage"}]'
```

## Phase 2: Migrating an Existing Node Pool (If Needed)

If you need to free up the `kafka` node pool name because it's used by another cluster, follow these steps.

### Enabling Cruise Control

First, ensure Cruise Control is enabled for the existing Kafka instance:

```bash
oc patch kafka <existing-kafka-instance> -n <namespace> \
  --type=json \
  -p='[{"op": "add", "path": "/spec/cruiseControl", "value": {}}]'
```

Wait for Cruise Control pods to be ready:

```bash
oc get pods -n <namespace> \
  -l strimzi.io/cluster=<existing-kafka-instance>,strimzi.io/kind=Kafka,strimzi.io/name=<existing-kafka-instance>-cruise-control
```

### Getting Node IDs

Retrieve the node IDs from the existing `kafka` pool:

```bash
oc get kafkanodepool kafka -n <namespace> -o jsonpath='{.status.nodeIds}'
```

This will return an array like `[0,1,2]` that you'll need for the rebalance operation.

### Creating a New Node Pool

Create a new node pool for the existing Kafka instance. Get the configuration from the existing pool:

```bash
oc get kafkanodepool kafka -n <namespace> -o yaml
```

Create a new pool (typically named `kafka-<cluster-name>`) with the same configuration:

```bash
cat <<EOF | oc apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: kafka-<existing-kafka-instance>
  namespace: <namespace>
  labels:
    strimzi.io/cluster: <existing-kafka-instance>
spec:
  replicas: <replicas>
  roles:
    - broker
  storage:
    type: <storage-type>
    size: <storage-size>
    class: <storage-class>
EOF
```

NOTE: Above KafkaNodePool is using non-jbod based storage, update it accordingly if you want to use jbod based storage.

Wait for the new pool and its pods to be ready before proceeding.

### Creating KafkaRebalance Resource

Create a KafkaRebalance resource to migrate partitions from the old brokers to the new ones:

```bash
cat <<EOF | oc apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaRebalance
metadata:
  name: evacuate-old-pool-<existing-kafka-instance>
  namespace: <namespace>
  labels:
    strimzi.io/cluster: <existing-kafka-instance>
spec:
  mode: remove-brokers
  brokers: [0,1,2]
EOF
```

Replace `[0,1,2]` with the actual node IDs you retrieved earlier.

### Approving the Rebalance

Wait for the proposal to be ready:

```bash
oc get kafkarebalance evacuate-old-pool-<existing-kafka-instance> -n <namespace> \
  -o jsonpath='{.status.conditions[?(@.type=="ProposalReady")].status}'
```

Or just wait for ProposalReady using below command:

```bash
oc get kafkarebalance evacuate-old-pool-<existing-kafka-instance> -n <namespace> -w
```

When it returns `True` or the status is 'ProposalReady' from the second command above, approve the rebalance:

```bash
oc annotate kafkarebalance evacuate-old-pool-<existing-kafka-instance> -n <namespace> \
  strimzi.io/rebalance=approve \
  --overwrite
```

Monitor the rebalance completion:

```bash
oc get kafkarebalance evacuate-old-pool-<existing-kafka-instance> -n <namespace> \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

### Deleting the Old Pool

Once the rebalance is complete, delete the old `kafka` node pool:

```bash
oc delete kafkanodepool kafka -n <namespace> --wait=true
```

## Phase 3: Creating the Controller Node Pool

KRaft requires controller nodes to manage metadata. Create a controller node pool that will replace ZooKeeper.

### Determining Controller Configuration

If you want to replicate the replica count and storage sizing from the existing Zookeeper then get the ZooKeeper configuration to use as a baseline for the controller pool:

```bash
# Get ZooKeeper replicas
oc get kafka <kafka-instance-name> -n <namespace> -o jsonpath='{.spec.zookeeper.replicas}'

# Get ZooKeeper storage configuration
oc get kafka <kafka-instance-name> -n <namespace> -o jsonpath='{.spec.zookeeper.storage.type}'
oc get kafka <kafka-instance-name> -n <namespace> -o jsonpath='{.spec.zookeeper.storage.size}'
oc get kafka <kafka-instance-name> -n <namespace> -o jsonpath='{.spec.zookeeper.storage.class}'
```

**Note**: If ZooKeeper uses ephemeral storage and you want to use persistent storage for Kraft controller then specify a persistent storage size for the controller pool.

### Creating the Controller Pool

Create a controller node pool. The default name is `controller-<kafka-instance-name>`, but you can choose any name:

```bash
cat <<EOF | oc apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: controller-<kafka-instance-name>
  namespace: <namespace>
  labels:
    strimzi.io/cluster: <kafka-instance-name>
spec:
  replicas: <kraft-controller-replica-count>
  roles:
    - controller
  storage:
    type: <storage-type>
    size: <storage-size>
    class: <storage-class>
EOF
```

NOTE: Above KafkaNodePool is using non-jbod based storage, update it accordingly if you want to use jbod based storage.

Wait for the controller pool pods to be ready:

```bash
oc get pods -n <namespace> -l strimzi.io/cluster=<kafka-instance-name>,strimzi.io/pool-name=controller-<kafka-instance-name> --field-selector=status.phase=Running
```

Verify that all pods show `Ready` in the READY column (e.g., `1/1` or `2/2`). All pods should be in `Running` state and ready before proceeding.

## Phase 4: Initiating KRaft Migration

Once the controller pool is ready, you can start the migration process.

### Enabling Migration Mode

Enable KRaft migration by annotating the Kafka resource:

```bash
oc annotate kafka <kafka-instance-name> -n <namespace> \
  strimzi.io/kraft=migration \
  --overwrite
```

This annotation tells Strimzi to begin the migration process. The cluster will start operating in dual-write mode, writing metadata to both ZooKeeper and KRaft.

## Phase 5: Monitoring Migration Progress

The migration progresses through several states. Monitor the migration state:

```bash
oc get kafka <kafka-instance-name> -n <namespace> \
  -o jsonpath='{.status.kafkaMigrationStatus.state}'
```

### Migration States

The migration progresses through these states:

1. **KRaftMigration**: The initial migration phase where the cluster is preparing for dual-write mode
2. **KRaftDualWriting**: The cluster is writing metadata to both ZooKeeper and KRaft
3. **KRaftPostMigration**: Migration is complete, and the cluster is ready to switch to full KRaft mode

Monitor the state transition:

```bash
# Check current migration state
oc get kafka <kafka-instance-name> -n <namespace> \
  -o jsonpath='{.status.kafkaMigrationStatus.state}'

# Check for any error conditions
oc get kafka <kafka-instance-name> -n <namespace> \
  -o jsonpath='{.status.kafkaMigrationStatus}'
```

Wait for the state to reach `KRaftPostMigration` before proceeding. This phase can take significant time depending on your cluster size and data volume.

## Phase 6: Enabling Full KRaft Mode

Once the migration state reaches `KRaftPostMigration`, you can enable full KRaft mode:

```bash
oc annotate kafka <kafka-instance-name> -n <namespace> \
  strimzi.io/kraft=enabled \
  --overwrite
```

This will cause the cluster to restart in KRaft-only mode, no longer using ZooKeeper for metadata management.

## Phase 7: Verifying Final State

After enabling KRaft mode, verify that the migration is complete.

### Checking Metadata State

Monitor the metadata state until it reaches `KRaft`:

```bash
oc get kafka <kafka-instance-name> -n <namespace> \
  -o jsonpath='{.status.kafkaMetadataState.state}'
```

The metadata state will transition through `PreKRaft` (ZooKeeper resources being cleaned up) to `KRaft` (fully migrated).

### Verifying KRaft Annotation

Confirm the KRaft annotation is set to `enabled`:

```bash
oc get kafka <kafka-instance-name> -n <namespace> \
  -o jsonpath='{.metadata.annotations.strimzi\.io/kraft}'
```

### Cleaning Up ZooKeeper Configuration

Once the metadata state is `KRaft`, you can safely remove ZooKeeper-related configuration from the Kafka resource:

```bash
# Remove the ZooKeeper section
oc patch kafka <kafka-instance-name> -n <namespace> \
  --type=json \
  -p='[{"op": "remove", "path": "/spec/zookeeper"}]'

# Remove log.message.format.version if present
oc patch kafka <kafka-instance-name> -n <namespace> \
  --type=json \
  -p='[{"op": "remove", "path": "/spec/kafka/config/log.message.format.version"}]'

# Remove inter.broker.protocol.version if present
oc patch kafka <kafka-instance-name> -n <namespace> \
  --type=json \
  -p='[{"op": "remove", "path": "/spec/kafka/config/inter.broker.protocol.version"}]'
```

## Monitoring and Troubleshooting

### Monitoring Pods

Monitor the Kafka pods throughout the migration:

```bash
oc get pods -n <namespace> -l strimzi.io/cluster=<kafka-instance-name>
```

### Checking Pod Logs

If you encounter issues, check the pod logs:

```bash
oc logs <pod-name> -n <namespace>
```

### Viewing Full Kafka Resource Status

Get a comprehensive view of the Kafka resource status:

```bash
oc get kafka <kafka-instance-name> -n <namespace> -o yaml
```

Look for:
- `status.kafkaMigrationStatus.state`: Current migration state
- `status.kafkaMetadataState.state`: Current metadata state
- Any error conditions or warnings

### Common Issues

**Migration state stuck**: If the migration state doesn't progress, check:
- Controller pod is running and healthy
- Check logs from the Controller pod and see if there are any errors
- Broker pods are running and healthy
- No errors in broker pod logs
- Sufficient resources have been allocated to both controller as well as broker pods (CPU, memory, storage)

**Metadata state not reaching KRaft**: This may indicate:
- Migration is still in progress (be patient, this can take time)
- Controller pods are not ready
- Check logs from the Controller pod and see if there are any errors
- Network connectivity issues between brokers and controllers

**Node pool not ready**: Check:
- Storage class is available
- Sufficient storage quota
- Pod scheduling constraints

## Summary

The migration from ZooKeeper to KRaft involves:

1. Ensuring your Kafka instance uses node pools
2. Creating a Kraft controller node pool to replace ZooKeeper
3. Enabling migration mode to start dual-write operations
4. Monitoring the migration through its various states
5. Enabling full KRaft mode once migration completes
6. Cleaning up ZooKeeper configuration

The entire process is designed to be non-disruptive, with the cluster continuing to serve traffic throughout the migration. However, it's recommended to perform this migration during a maintenance window and ensure you have proper backups.

Once complete, your Kafka cluster will run entirely on KRaft, eliminating the ZooKeeper dependency and simplifying your infrastructure.

## References

For more information about Kafka KRaft migration and related topics, refer to the following Red Hat documentation:

- **Red Hat Streams for Apache Kafka Documentation**: [Streams for Apache Kafka Documentation](https://docs.redhat.com/en/documentation/red_hat_streams_for_apache_kafka/2.9/html/getting_started_with_streams_for_apache_kafka_on_openshift/index)
- **Streams for Apache Kafka on OpenShift**: [Deploying and Managing Streams for Apache Kafka on OpenShift](https://docs.redhat.com/en/documentation/red_hat_streams_for_apache_kafka/3.1/html/deploying_and_managing_streams_for_apache_kafka_on_openshift/index)
- **Kafka Node Pools**: [Using Kafka Node Pools](https://docs.redhat.com/en/documentation/red_hat_streams_for_apache_kafka/3.1/html/streams_for_apache_kafka_on_openshift_overview/kafka-components_str#kafka-concepts-node-pools-str)
- **Zookeeper to KRaft Migration**: [Migrating from ZooKeeper to KRaft](https://docs.redhat.com/en/documentation/red_hat_streams_for_apache_kafka/2.9/html-single/deploying_and_managing_streams_for_apache_kafka_on_openshift/index#proc-deploy-migrate-kraft-str)

Note: Documentation links are publicly accessible and may change over time. Always refer to the latest version of the documentation for your specific product version.

