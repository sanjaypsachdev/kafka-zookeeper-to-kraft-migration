#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to display usage
usage() {
    cat << EOF
Usage: $0 <namespace> <kafka-instance-name> [options]

Arguments:
    namespace              OpenShift namespace where Kafka is deployed
    kafka-instance-name   Name of the Kafka instance to migrate

Options:
    --controller-pool-name NAME    Name for the controller node pool (default: controller-{kafka-instance-name})
    --controller-replicas NUM       Number of controller replicas (default: ZooKeeper replicas from Kafka resource)
    --controller-storage-type TYPE  Storage type for controller node pool (default: matches broker storage, options: persistent-claim, ephemeral, jbod)
    --controller-storage-sizes SIZES Storage size(s) for controller node pool
                                     For non-JBOD: single size (e.g., "200Gi")
                                     For JBOD: comma-separated list (e.g., "100Gi,200Gi,300Gi")
                                     Required if storage type is persistent-claim or jbod
    --controller-storage-class CLASS Storage class for controller node pool (default: matches broker storage or ZooKeeper storage class)
    --wait-timeout SECONDS          Timeout for waiting on migration states (default: 3600)
    --skip-prereq-check             Skip prerequisite checks
    --help                          Show this help message

Examples:
    $0 my-namespace my-kafka
    $0 my-namespace my-kafka --controller-pool-name my-controller-pool
    $0 my-namespace my-kafka --controller-replicas 5 --controller-storage-sizes 200Gi
    $0 my-namespace my-kafka --controller-storage-sizes 200Gi --controller-storage-class fast-ssd
    $0 my-namespace my-kafka --controller-storage-type jbod --controller-storage-sizes "100Gi,200Gi,300Gi"
EOF
    exit 1
}

# Default values
WAIT_TIMEOUT=3600
SKIP_PREREQ_CHECK=false
CONTROLLER_POOL_NAME=""  # Will be set to default if not provided
CONTROLLER_REPLICAS=""   # Will use ZooKeeper replicas as default if not provided
CONTROLLER_STORAGE_TYPE=""  # Will default to broker storage type if not provided
CONTROLLER_STORAGE_SIZES=""  # Comma-separated list for JBOD, single value for non-JBOD
CONTROLLER_STORAGE_CLASS=""  # Will use broker storage class or ZooKeeper storage class as default if not provided

# Parse command line arguments
if [[ $# -lt 2 ]]; then
    print_error "Missing required arguments"
    usage
fi

NAMESPACE=$1
KAFKA_INSTANCE=$2
shift 2

# Parse optional arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --controller-pool-name)
            CONTROLLER_POOL_NAME="$2"
            shift 2
            ;;
        --controller-replicas)
            CONTROLLER_REPLICAS="$2"
            shift 2
            ;;
        --controller-storage-type)
            CONTROLLER_STORAGE_TYPE="$2"
            shift 2
            ;;
        --controller-storage-size)
            # Support old parameter name for backward compatibility
            CONTROLLER_STORAGE_SIZES="$2"
            print_warning "--controller-storage-size is deprecated, use --controller-storage-sizes instead"
            shift 2
            ;;
        --controller-storage-sizes)
            CONTROLLER_STORAGE_SIZES="$2"
            shift 2
            ;;
        --controller-storage-class)
            CONTROLLER_STORAGE_CLASS="$2"
            shift 2
            ;;
        --wait-timeout)
            WAIT_TIMEOUT="$2"
            shift 2
            ;;
        --skip-prereq-check)
            SKIP_PREREQ_CHECK=true
            shift
            ;;
        --help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Function to check if oc command is available
check_oc_available() {
    if ! command -v oc &> /dev/null; then
        print_error "oc command not found. Please install the OpenShift CLI."
        exit 1
    fi
    print_success "OpenShift CLI (oc) is available"
}

# Function to get KafkaNodePool API version from cluster
get_kafkanodepool_api_version() {
    # First: try to get the API version from existing KafkaNodePool resources (if namespace is available)
    if oc get namespace "$NAMESPACE" &> /dev/null; then
        local existing_pool=$(oc get kafkanodepool -n "$NAMESPACE" --no-headers 2>/dev/null | head -n 1 | awk '{print $1}')
        if [[ -n "$existing_pool" ]]; then
            local api_version=$(oc get kafkanodepool "$existing_pool" -n "$NAMESPACE" -o jsonpath='{.apiVersion}' 2>/dev/null)
            if [[ -n "$api_version" && "$api_version" != "null" && "$api_version" != "" ]]; then
                echo "$api_version"
                return 0
            fi
        fi
    fi
    
    # Second: try to get from CRD (get the stored version - most reliable)
    local crd_version=$(oc get crd kafkanodepools.kafka.strimzi.io -o jsonpath='{range .spec.versions[?(@.storage==true)]}{.name}{end}' 2>/dev/null | head -n 1)
    if [[ -z "$crd_version" || "$crd_version" == "null" ]]; then
        # Try alternative jsonpath format - get all versions and take the last one (usually the stored version)
        local all_versions=$(oc get crd kafkanodepools.kafka.strimzi.io -o jsonpath='{.spec.versions[*].name}' 2>/dev/null)
        if [[ -n "$all_versions" && "$all_versions" != "null" ]]; then
            # Get the last version (usually the stored one)
            crd_version=$(echo "$all_versions" | awk '{print $NF}')
        fi
    fi
    if [[ -n "$crd_version" && "$crd_version" != "null" && "$crd_version" != "" ]]; then
        echo "kafka.strimzi.io/$crd_version"
        return 0
    fi
    
    # Third: query api-resources with wide output to find the version
    local api_info=$(oc api-resources --api-group=kafka.strimzi.io -o wide 2>/dev/null | grep -i kafkanodepool | head -n 1)
    if [[ -n "$api_info" ]]; then
        # Extract version from the wide output (format: NAME APIGROUP NAMESPACED KIND VERSION)
        local version=$(echo "$api_info" | awk '{print $NF}')
        if [[ -n "$version" && "$version" =~ ^v[0-9] ]]; then
            echo "kafka.strimzi.io/$version"
            return 0
        fi
    fi
    
    # Default fallback
    echo "kafka.strimzi.io/v1beta2"
    print_warning "Could not detect KafkaNodePool API version from cluster, using default: kafka.strimzi.io/v1beta2"
}


# Function to build JBOD storage YAML from Kafka resource
build_jbod_storage_yaml_from_kafka() {
    local storage_yaml="    type: jbod\n    volumes:"
    
    # Get volumes count by checking how many volume IDs exist
    local volume_ids=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage.volumes[*].id}' 2>/dev/null)
    
    if [[ -z "$volume_ids" || "$volume_ids" == "null" ]]; then
        print_error "JBOD volumes not found in Kafka resource spec.kafka.storage.volumes"
        exit 1
    fi
    
    # Count volumes by counting space-separated IDs
    local volume_count=$(echo "$volume_ids" | wc -w)
    
    # Process each volume
    for ((i=0; i<volume_count; i++)); do
        local vol_id=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath="{.spec.kafka.storage.volumes[$i].id}" 2>/dev/null)
        local vol_type=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath="{.spec.kafka.storage.volumes[$i].type}" 2>/dev/null)
        local vol_size=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath="{.spec.kafka.storage.volumes[$i].size}" 2>/dev/null)
        local vol_class=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath="{.spec.kafka.storage.volumes[$i].class}" 2>/dev/null)
        local vol_delete_claim=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath="{.spec.kafka.storage.volumes[$i].deleteClaim}" 2>/dev/null)
        
        if [[ -z "$vol_id" || "$vol_id" == "null" ]]; then
            print_error "Volume $i missing required 'id' field"
            exit 1
        fi
        if [[ -z "$vol_type" || "$vol_type" == "null" ]]; then
            print_error "Volume $i (id=$vol_id) missing required 'type' field"
            exit 1
        fi
        
        storage_yaml="${storage_yaml}\n    - id: ${vol_id}\n      type: ${vol_type}"
        
        if [[ -n "$vol_size" && "$vol_size" != "null" ]]; then
            storage_yaml="${storage_yaml}\n      size: ${vol_size}"
        fi
        
        if [[ -n "$vol_class" && "$vol_class" != "null" ]]; then
            storage_yaml="${storage_yaml}\n      class: ${vol_class}"
        fi
        
        if [[ -n "$vol_delete_claim" && "$vol_delete_claim" != "null" ]]; then
            storage_yaml="${storage_yaml}\n      deleteClaim: ${vol_delete_claim}"
        fi
    done
    
    echo -e "$storage_yaml"
}

# Function to build JBOD storage YAML from existing node pool
build_jbod_storage_yaml_from_pool() {
    local pool_name=$1
    local storage_yaml="    type: jbod\n    volumes:"
    
    # Get volumes count
    local volume_ids=$(oc get kafkanodepool "$pool_name" -n "$NAMESPACE" -o jsonpath='{.spec.storage.volumes[*].id}' 2>/dev/null)
    
    if [[ -z "$volume_ids" || "$volume_ids" == "null" ]]; then
        print_error "JBOD volumes not found in node pool '$pool_name'"
        exit 1
    fi
    
    # Count volumes
    local volume_count=$(echo "$volume_ids" | wc -w)
    
    # Process each volume
    for ((i=0; i<volume_count; i++)); do
        local vol_id=$(oc get kafkanodepool "$pool_name" -n "$NAMESPACE" -o jsonpath="{.spec.storage.volumes[$i].id}" 2>/dev/null)
        local vol_type=$(oc get kafkanodepool "$pool_name" -n "$NAMESPACE" -o jsonpath="{.spec.storage.volumes[$i].type}" 2>/dev/null)
        local vol_size=$(oc get kafkanodepool "$pool_name" -n "$NAMESPACE" -o jsonpath="{.spec.storage.volumes[$i].size}" 2>/dev/null)
        local vol_class=$(oc get kafkanodepool "$pool_name" -n "$NAMESPACE" -o jsonpath="{.spec.storage.volumes[$i].class}" 2>/dev/null)
        local vol_delete_claim=$(oc get kafkanodepool "$pool_name" -n "$NAMESPACE" -o jsonpath="{.spec.storage.volumes[$i].deleteClaim}" 2>/dev/null)
        
        if [[ -z "$vol_id" || "$vol_id" == "null" ]]; then
            print_error "Volume $i missing required 'id' field in pool '$pool_name'"
            exit 1
        fi
        if [[ -z "$vol_type" || "$vol_type" == "null" ]]; then
            print_error "Volume $i (id=$vol_id) missing required 'type' field in pool '$pool_name'"
            exit 1
        fi
        
        storage_yaml="${storage_yaml}\n    - id: ${vol_id}\n      type: ${vol_type}"
        
        if [[ -n "$vol_size" && "$vol_size" != "null" ]]; then
            storage_yaml="${storage_yaml}\n      size: ${vol_size}"
        fi
        
        if [[ -n "$vol_class" && "$vol_class" != "null" ]]; then
            storage_yaml="${storage_yaml}\n      class: ${vol_class}"
        fi
        
        if [[ -n "$vol_delete_claim" && "$vol_delete_claim" != "null" ]]; then
            storage_yaml="${storage_yaml}\n      deleteClaim: ${vol_delete_claim}"
        fi
    done
    
    echo -e "$storage_yaml"
}

# Function to build JBOD storage YAML from comma-separated sizes
build_jbod_storage_yaml_from_sizes() {
    local sizes_list=$1
    local storage_class=$2  # Optional storage class to apply to all volumes
    local storage_yaml="    type: jbod\n    volumes:"
    
    # Save original IFS and set to comma for splitting
    local old_ifs="$IFS"
    IFS=','
    read -ra SIZES <<< "$sizes_list"
    IFS="$old_ifs"  # Restore IFS immediately
    
    local vol_id=0
    
    for size in "${SIZES[@]}"; do
        # Trim whitespace
        size=$(echo "$size" | xargs)
        
        if [[ -z "$size" ]]; then
            print_warning "Skipping empty size in list"
            continue
        fi
        
        storage_yaml="${storage_yaml}\n    - id: ${vol_id}\n      type: persistent-claim\n      size: ${size}"
        
        # Add storage class if provided
        if [[ -n "$storage_class" && "$storage_class" != "null" ]]; then
            storage_yaml="${storage_yaml}\n      class: ${storage_class}"
        fi
        
        vol_id=$((vol_id + 1))
    done
    
    if [[ $vol_id -eq 0 ]]; then
        print_error "No valid sizes found in comma-separated list: $sizes_list"
        exit 1
    fi
    
    echo -e "$storage_yaml"
}

# Function to check if namespace exists
check_namespace() {
    if ! oc get namespace "$NAMESPACE" &> /dev/null; then
        print_error "Namespace '$NAMESPACE' does not exist"
        exit 1
    fi
    print_success "Namespace '$NAMESPACE' exists"
}

# Function to check if Kafka instance exists
check_kafka_instance() {
    if ! oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" &> /dev/null; then
        print_error "Kafka instance '$KAFKA_INSTANCE' not found in namespace '$NAMESPACE'"
        exit 1
    fi
    print_success "Kafka instance '$KAFKA_INSTANCE' found"
}

# Function to check if Kafka is already using KRaft
check_kraft_status() {
    local kraft_annotation=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.strimzi\.io/kraft}' 2>/dev/null || echo "")
    
    if [[ "$kraft_annotation" == "enabled" ]]; then
        print_warning "Kafka instance is already using KRaft mode"
        exit 0
    fi
    
    if [[ "$kraft_annotation" == "migration" ]]; then
        print_warning "Kafka instance is already in migration mode"
        print_info "Continuing with migration monitoring..."
        return 0
    fi
    
    print_info "Kafka is currently using ZooKeeper mode"
}

# Function to migrate existing 'kafka' node pool to a new pool using KafkaRebalance
migrate_existing_kafka_pool() {
    local old_pool_cluster=$1  # This is the Kafka instance that already has 'kafka' pool and is already migrated to KRaft
    
    print_info "Migrating existing 'kafka' node pool from Kafka instance '$old_pool_cluster'..."
    
    # Verify that the existing Kafka instance has been migrated to KRaft
    local kraft_status=$(oc get kafka "$old_pool_cluster" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.strimzi\.io/kraft}' 2>/dev/null || echo "")
    
    if [[ "$kraft_status" != "enabled" ]]; then
        print_warning "Kafka instance '$old_pool_cluster' does not appear to be fully migrated to KRaft (status: ${kraft_status:-not set})"
        print_warning "Continuing anyway, but ensure this Kafka instance has completed KRaft migration"
    else
        print_info "Verified: Kafka instance '$old_pool_cluster' has been migrated to KRaft"
    fi
    
    local new_pool_name="kafka-${old_pool_cluster}"
    
    print_info "Target Kafka instance for Cruise Control and KafkaRebalance: '$old_pool_cluster'"
    print_info "Will migrate 'kafka' pool to '$new_pool_name' for '$old_pool_cluster'"
    
    # Step 1: Get node IDs from existing 'kafka' pool
    print_info "Getting node IDs from existing 'kafka' node pool..."
    local node_ids=$(oc get kafkanodepool kafka -n "$NAMESPACE" -o jsonpath='{.status.nodeIds}' 2>/dev/null)
    
    if [[ -z "$node_ids" || "$node_ids" == "null" || "$node_ids" == "[]" ]]; then
        print_error "Could not retrieve node IDs from existing 'kafka' node pool"
        exit 1
    fi
    
    print_info "Node IDs to migrate: $node_ids"
    
    # Step 2: Get storage configuration from existing 'kafka' pool
    local existing_storage_type=$(oc get kafkanodepool kafka -n "$NAMESPACE" -o jsonpath='{.spec.storage.type}' 2>/dev/null)
    local existing_replicas=$(oc get kafkanodepool kafka -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    
    # Step 3: Create target node pool (without brokers field - KafkaRebalance will handle migration)
    print_info "Creating target node pool '$new_pool_name' for Kafka instance '$old_pool_cluster'..."
    
    # Handle JBOD vs single storage
    local storage_yaml=""
    if [[ "$existing_storage_type" == "jbod" ]]; then
        print_info "Detected JBOD storage in existing 'kafka' node pool"
        storage_yaml=$(build_jbod_storage_yaml_from_pool "kafka")
    else
        # Single storage configuration
        local existing_storage_size=$(oc get kafkanodepool kafka -n "$NAMESPACE" -o jsonpath='{.spec.storage.size}' 2>/dev/null)
        local existing_storage_class=$(oc get kafkanodepool kafka -n "$NAMESPACE" -o jsonpath='{.spec.storage.class}' 2>/dev/null)
        local existing_storage_delete_claim=$(oc get kafkanodepool kafka -n "$NAMESPACE" -o jsonpath='{.spec.storage.deleteClaim}' 2>/dev/null)
        local existing_storage_id=$(oc get kafkanodepool kafka -n "$NAMESPACE" -o jsonpath='{.spec.storage.id}' 2>/dev/null)
        
        storage_yaml="    type: ${existing_storage_type}\n    size: ${existing_storage_size}"
        if [[ -n "$existing_storage_class" && "$existing_storage_class" != "null" ]]; then
            storage_yaml="${storage_yaml}\n    class: ${existing_storage_class}"
        fi
        if [[ -n "$existing_storage_delete_claim" && "$existing_storage_delete_claim" != "null" ]]; then
            storage_yaml="${storage_yaml}\n    deleteClaim: ${existing_storage_delete_claim}"
        fi
        if [[ -n "$existing_storage_id" && "$existing_storage_id" != "null" ]]; then
            storage_yaml="${storage_yaml}\n    id: ${existing_storage_id}"
        fi
    fi
    
    cat <<EOF | oc apply -f -
apiVersion: ${KAFKANODEPOOL_API_VERSION}
kind: KafkaNodePool
metadata:
  name: ${new_pool_name}
  namespace: ${NAMESPACE}
  labels:
    strimzi.io/cluster: ${old_pool_cluster}
spec:
  replicas: ${existing_replicas}
  roles:
    - broker
  storage:
$(echo -e "$storage_yaml")
EOF
    
    if [[ $? -ne 0 ]]; then
        print_error "Failed to create new node pool '$new_pool_name'"
        exit 1
    fi
    
    print_success "New node pool '$new_pool_name' created for Kafka instance '$old_pool_cluster'"
    
    # Wait for new broker pods to be running
    print_info "Waiting for new broker pods from node pool '$new_pool_name' to be ready..."
    print_info "Expected: ${existing_replicas} new broker pods (will have $((existing_replicas * 2)) total brokers: ${existing_replicas} old + ${existing_replicas} new)"
    
    timeout=600  # 10 minutes for pods to start
    elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        # Get pods for the new node pool
        # Strimzi pod naming pattern: {cluster-name}-kafka-{pool-name}-{replica-number}
        # For pool "kafka-${old_pool_cluster}", pods are named like: ${old_pool_cluster}-kafka-${old_pool_cluster}-{number}
        # This pattern distinguishes new pool pods from old pool pods (which are ${old_pool_cluster}-kafka-{number})
        # Match pods that have cluster name, kafka, cluster name again, then number
        local new_pool_pattern="${old_pool_cluster}-kafka-${old_pool_cluster}-"
        local new_pool_pods_raw=$(oc get pods -n "$NAMESPACE" \
            -l strimzi.io/cluster="$old_pool_cluster",strimzi.io/kind=Kafka \
            --no-headers 2>/dev/null | grep "^${new_pool_pattern}" | wc -l)
        
        # Trim whitespace and ensure numeric value (wc -l may include newlines)
        local new_pool_pods=$(echo "$new_pool_pods_raw" | tr -d '[:space:]')
        # Default to 0 if empty or not numeric
        if [[ ! "$new_pool_pods" =~ ^[0-9]+$ ]]; then
            new_pool_pods=0
        fi
        
        # Count ready pods for the new pool (pods matching the new pool name pattern)
        local ready_pods=0
        local all_pods=$(oc get pods -n "$NAMESPACE" \
            -l strimzi.io/cluster="$old_pool_cluster",strimzi.io/kind=Kafka \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)
        
        while IFS=$'\t' read -r pod_name ready_status; do
            # Match pods that start with the new pool pattern (cluster-kafka-cluster-)
            # This matches: ${old_pool_cluster}-kafka-${old_pool_cluster}-{number}
            # This excludes old pool pods which are: ${old_pool_cluster}-kafka-{number}
            if [[ "$pod_name" == ${new_pool_pattern}* ]] && [[ "$ready_status" == "True" ]]; then
                ready_pods=$((ready_pods + 1))
            fi
        done <<< "$all_pods"
        
        # Ensure ready_pods is numeric
        ready_pods=${ready_pods:-0}
        
        if [[ "$new_pool_pods" -ge "$existing_replicas" && "$ready_pods" -ge "$existing_replicas" ]]; then
            print_success "All ${existing_replicas} new broker pods from node pool '$new_pool_name' are ready"
            print_info "Total brokers: ${existing_replicas} (old 'kafka' pool) + ${existing_replicas} (new '$new_pool_name' pool) = $((existing_replicas * 2))"
            break
        fi
        
        if [[ "$new_pool_pods" -gt 0 ]]; then
            echo -n "Pods: ${new_pool_pods}/${existing_replicas}, Ready: ${ready_pods}/${existing_replicas}... "
        fi
        
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo
    
    if [[ $elapsed -ge $timeout ]]; then
        print_error "New broker pods did not become ready within $timeout seconds"
        print_error "Expected ${existing_replicas} pods, but may not all be ready"
        exit 1
    fi
    
    # Step 4: Create KafkaRebalance resource for the existing Kafka instance (old_pool_cluster)
    local rebalance_name="evacuate-old-pool-${old_pool_cluster}"
    print_info "Creating KafkaRebalance resource '$rebalance_name' for Kafka instance '$old_pool_cluster'..."
    
    # Use nodeIds directly as brokers array (already in [0,1,2] format)
    local brokers_array="$node_ids"
    
    cat <<EOF | oc apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaRebalance
metadata:
  name: ${rebalance_name}
  namespace: ${NAMESPACE}
  labels:
    strimzi.io/cluster: ${old_pool_cluster}
spec:
  mode: remove-brokers
  brokers: ${brokers_array}
EOF
    
    if [[ $? -ne 0 ]]; then
        print_error "Failed to create KafkaRebalance resource for Kafka instance '$old_pool_cluster'"
        exit 1
    fi
    
    print_success "KafkaRebalance resource '$rebalance_name' created for Kafka instance '$old_pool_cluster'"
    
    # Step 5: Wait for ProposalReady state
    print_info "Waiting for KafkaRebalance proposal to be ready for Kafka instance '$old_pool_cluster'..."
    timeout=1800  # 30 minutes
    elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        local proposal_status=$(oc get kafkarebalance "$rebalance_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="ProposalReady")].status}' 2>/dev/null || echo "Unknown")
        
        if [[ "$proposal_status" == "True" ]]; then
            print_success "KafkaRebalance proposal is ready for Kafka instance '$old_pool_cluster'"
            break
        fi
        
        local current_status=$(oc get kafkarebalance "$rebalance_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="ProposalReady")].message}' 2>/dev/null || echo "")
        if [[ -n "$current_status" && "$current_status" != "null" ]]; then
            echo -n "Status: $current_status... "
        fi
        
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo
    
    if [[ $elapsed -ge $timeout ]]; then
        print_error "KafkaRebalance proposal did not become ready within $timeout seconds for Kafka instance '$old_pool_cluster'"
        exit 1
    fi
    
    # Step 6: Approve the proposal
    print_info "Approving KafkaRebalance proposal for Kafka instance '$old_pool_cluster'..."
    oc annotate kafkarebalance "$rebalance_name" -n "$NAMESPACE" \
        strimzi.io/rebalance=approve \
        --overwrite
    
    if [[ $? -ne 0 ]]; then
        print_error "Failed to approve KafkaRebalance proposal for Kafka instance '$old_pool_cluster'"
        exit 1
    fi
    
    print_success "KafkaRebalance proposal approved for Kafka instance '$old_pool_cluster'"
    
    # Step 7: Wait for Ready state (completion)
    print_info "Waiting for KafkaRebalance to complete for Kafka instance '$old_pool_cluster'..."
    timeout=3600  # 60 minutes
    elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        local ready_status=$(oc get kafkarebalance "$rebalance_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        
        if [[ "$ready_status" == "True" ]]; then
            print_success "KafkaRebalance completed successfully for Kafka instance '$old_pool_cluster'"
            break
        fi
        
        local current_status=$(oc get kafkarebalance "$rebalance_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
        if [[ -n "$current_status" && "$current_status" != "null" ]]; then
            echo -n "Status: $current_status... "
        fi
        
        sleep 15
        elapsed=$((elapsed + 15))
        echo -n "."
    done
    echo
    
    if [[ $elapsed -ge $timeout ]]; then
        print_warning "KafkaRebalance did not complete within $timeout seconds for Kafka instance '$old_pool_cluster', but continuing..."
    fi
    
    # Step 8: Delete the old 'kafka' pool
    print_info "Deleting old 'kafka' node pool (belonging to Kafka instance '$old_pool_cluster')..."
    oc delete kafkanodepool kafka -n "$NAMESPACE" --wait=true
    
    if [[ $? -ne 0 ]]; then
        print_error "Failed to delete old 'kafka' node pool"
        exit 1
    fi
    
    print_success "Old 'kafka' node pool deleted"
    
    # Step 9: Verify
    print_info "Verifying node pools..."
    local kafka_pool_exists=$(oc get kafkanodepool kafka -n "$NAMESPACE" &> /dev/null && echo "yes" || echo "no")
    local new_pool_exists=$(oc get kafkanodepool "$new_pool_name" -n "$NAMESPACE" &> /dev/null && echo "yes" || echo "no")
    
    if [[ "$kafka_pool_exists" == "no" && "$new_pool_exists" == "yes" ]]; then
        print_success "Verification successful: 'kafka' pool deleted, '$new_pool_name' exists for Kafka instance '$old_pool_cluster'"
    else
        print_warning "Verification: kafka pool exists=$kafka_pool_exists, $new_pool_name exists=$new_pool_exists"
    fi
}

# Function to migrate Kafka to node pools
migrate_kafka_to_node_pools() {
    print_info "Migrating Kafka instance '$KAFKA_INSTANCE' to use node pools..."
    
    # Check if 'kafka' node pool already exists for a different Kafka instance
    local existing_kafka_pool=$(oc get kafkanodepool kafka -n "$NAMESPACE" -o jsonpath='{.metadata.labels.strimzi\.io/cluster}' 2>/dev/null || echo "")
    
    if [[ -n "$existing_kafka_pool" && "$existing_kafka_pool" != "$KAFKA_INSTANCE" ]]; then
        # This is NOT the first Kafka instance being migrated in this namespace
        # There's already a 'kafka' node pool for a different Kafka instance (which has already been migrated to KRaft)
        print_warning "Node pool 'kafka' already exists for Kafka instance '$existing_kafka_pool'"
        print_info "This Kafka instance ('$KAFKA_INSTANCE') is not the first one being migrated to KafkaNodePools in this namespace."
        print_info "The existing Kafka instance '$existing_kafka_pool' has already been migrated to KRaft."
        print_info "Migrating the existing 'kafka' pool from '$existing_kafka_pool' to free up the name..."
        
        # Ensure Cruise Control is enabled for the existing Kafka instance (old_pool_cluster)
        # This is the Kafka instance that already has the 'kafka' pool and has been migrated to KRaft
        local neighbor_has_cc=$(oc get kafka "$existing_kafka_pool" -n "$NAMESPACE" -o jsonpath='{.spec.cruiseControl}' 2>/dev/null || echo "")
        
        if [[ -z "$neighbor_has_cc" || "$neighbor_has_cc" == "null" || "$neighbor_has_cc" == "{}" ]]; then
            print_info "Enabling Cruise Control for existing Kafka instance '$existing_kafka_pool' (the one with the 'kafka' pool)..."
            oc patch kafka "$existing_kafka_pool" -n "$NAMESPACE" --type=json -p='[{"op": "add", "path": "/spec/cruiseControl", "value": {}}]' 2>/dev/null
            
            if [[ $? -ne 0 ]]; then
                print_error "Failed to enable Cruise Control for Kafka instance '$existing_kafka_pool'"
                exit 1
            fi
            
            print_success "Cruise Control enabled for Kafka instance '$existing_kafka_pool'"
            
            # Wait for Cruise Control pods to be ready for the existing Kafka instance
            print_info "Waiting for Cruise Control pods to be ready for Kafka instance '$existing_kafka_pool'..."
            local timeout=600  # 10 minutes
            local elapsed=0
            
            while [[ $elapsed -lt $timeout ]]; do
                local cruise_control_pods=$(oc get pods -n "$NAMESPACE" -l strimzi.io/cluster="$existing_kafka_pool",strimzi.io/kind=Kafka,strimzi.io/name="${existing_kafka_pool}-cruise-control" --no-headers 2>/dev/null | wc -l || echo "0")
                
                if [[ "$cruise_control_pods" -gt 0 ]]; then
                    local ready_pods=$(oc get pods -n "$NAMESPACE" -l strimzi.io/cluster="$existing_kafka_pool",strimzi.io/kind=Kafka,strimzi.io/name="${existing_kafka_pool}-cruise-control" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -c "True" || echo "0")
                    
                    if [[ "$ready_pods" -gt 0 ]]; then
                        print_success "Cruise Control pods are ready for Kafka instance '$existing_kafka_pool'"
                        break
                    fi
                fi
                
                sleep 10
                elapsed=$((elapsed + 10))
                echo -n "."
            done
            echo
            
            if [[ $elapsed -ge $timeout ]]; then
                print_error "Cruise Control pods did not become ready within $timeout seconds for Kafka instance '$existing_kafka_pool'"
                exit 1
            fi
        else
            print_info "Cruise Control is already enabled for Kafka instance '$existing_kafka_pool'"
            # Still verify pods are ready
            print_info "Verifying Cruise Control pods are ready for Kafka instance '$existing_kafka_pool'..."
            local timeout=300
            local elapsed=0
            
            while [[ $elapsed -lt $timeout ]]; do
                local ready_pods=$(oc get pods -n "$NAMESPACE" -l strimzi.io/cluster="$existing_kafka_pool",strimzi.io/kind=Kafka,strimzi.io/name="${existing_kafka_pool}-cruise-control" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -c "True" || echo "0")
                
                if [[ "$ready_pods" -gt 0 ]]; then
                    print_success "Cruise Control pods are ready for Kafka instance '$existing_kafka_pool'"
                    break
                fi
                
                sleep 10
                elapsed=$((elapsed + 10))
                echo -n "."
            done
            echo
        fi
        
        # Migrate the existing pool - this will run Cruise Control and KafkaRebalance for the existing Kafka instance
        migrate_existing_kafka_pool "$existing_kafka_pool"
        
        print_info "Existing 'kafka' pool migration completed for Kafka instance '$existing_kafka_pool'."
        print_info "Proceeding with creating new 'kafka' pool for '$KAFKA_INSTANCE'..."
        echo
    elif [[ -n "$existing_kafka_pool" && "$existing_kafka_pool" == "$KAFKA_INSTANCE" ]]; then
        # 'kafka' pool already exists for THIS Kafka instance
        print_info "Node pool 'kafka' already exists for this Kafka instance. Skipping creation."
        return 0
    else
        # No 'kafka' pool exists - this is the first migration in the namespace
        print_info "No existing 'kafka' node pool found. This is the first Kafka instance being migrated to KafkaNodePools in this namespace."
    fi
    
    # Get Kafka configuration - extract exact values from Kafka resource
    local kafka_replicas=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.replicas}' 2>/dev/null)
    
    # Validate required fields are present
    if [[ -z "$kafka_replicas" || "$kafka_replicas" == "null" ]]; then
        print_error "Kafka replicas not found in Kafka resource spec.kafka.replicas"
        exit 1
    fi
    
    # Get the entire storage object from Kafka resource to ensure exact match
    local storage_json=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage}' 2>/dev/null)
    
    if [[ -z "$storage_json" || "$storage_json" == "null" || "$storage_json" == "{}" ]]; then
        print_error "Storage configuration not found in Kafka resource spec.kafka.storage"
        exit 1
    fi
    
    # Get storage type first to determine if it's JBOD or single storage
    local storage_type=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage.type}' 2>/dev/null)
    
    # Validate required storage fields
    if [[ -z "$storage_type" || "$storage_type" == "null" ]]; then
        print_error "Storage type not found in Kafka resource spec.kafka.storage.type"
        exit 1
    fi
    
    # Handle JBOD vs single storage differently
    local storage_yaml=""
    if [[ "$storage_type" == "jbod" ]]; then
        print_info "Detected JBOD storage configuration in Kafka resource"
        storage_yaml=$(build_jbod_storage_yaml_from_kafka)
    else
        # Single storage configuration
        local storage_size=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage.size}' 2>/dev/null)
        
        if [[ -z "$storage_size" || "$storage_size" == "null" ]]; then
            print_error "Storage size not found in Kafka resource spec.kafka.storage.size"
            exit 1
        fi
        
        # Build storage YAML section with all fields from Kafka resource
        storage_yaml="    type: ${storage_type}\n    size: ${storage_size}"
        
        # Add optional fields if they exist in the Kafka resource
        local storage_class=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage.class}' 2>/dev/null)
        local storage_delete_claim=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage.deleteClaim}' 2>/dev/null)
        local storage_id=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage.id}' 2>/dev/null)
        local storage_overrides=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage.overrides}' 2>/dev/null)
        
        if [[ -n "$storage_class" && "$storage_class" != "null" ]]; then
            storage_yaml="${storage_yaml}\n    class: ${storage_class}"
        fi
        if [[ -n "$storage_delete_claim" && "$storage_delete_claim" != "null" ]]; then
            storage_yaml="${storage_yaml}\n    deleteClaim: ${storage_delete_claim}"
        fi
        if [[ -n "$storage_id" && "$storage_id" != "null" ]]; then
            storage_yaml="${storage_yaml}\n    id: ${storage_id}"
        fi
        if [[ -n "$storage_overrides" && "$storage_overrides" != "null" && "$storage_overrides" != "[]" ]]; then
            # Storage overrides is an array, would need more complex handling
            # For now, we'll note it but may need to handle this differently
            print_warning "Storage overrides found in Kafka resource but not copied to node pool (complex field)"
        fi
    fi
    
    # Create broker node pool named 'kafka' (standard name for broker pool)
    # Using exact replicas and storage from Kafka resource
    print_info "Creating broker node pool 'kafka' with replicas=${kafka_replicas} matching Kafka resource..."
    cat <<EOF | oc apply -f -
apiVersion: ${KAFKANODEPOOL_API_VERSION}
kind: KafkaNodePool
metadata:
  name: kafka
  namespace: ${NAMESPACE}
  labels:
    strimzi.io/cluster: ${KAFKA_INSTANCE}
spec:
  replicas: ${kafka_replicas}
  roles:
    - broker
  storage:
$(echo -e "$storage_yaml")
EOF
    
    if [[ $? -ne 0 ]]; then
        print_error "Failed to create broker node pool"
        exit 1
    fi
    
    print_success "Broker node pool 'kafka' created"
    
    # Verify that replicas and storage match exactly
    print_info "Verifying broker node pool matches Kafka resource configuration..."
    local node_pool_replicas=$(oc get kafkanodepool kafka -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    local node_pool_storage_type=$(oc get kafkanodepool kafka -n "$NAMESPACE" -o jsonpath='{.spec.storage.type}' 2>/dev/null)
    
    if [[ "$node_pool_replicas" != "$kafka_replicas" ]]; then
        print_error "Replicas mismatch! Kafka resource: $kafka_replicas, Node pool: $node_pool_replicas"
        exit 1
    fi
    
    if [[ "$node_pool_storage_type" != "$storage_type" ]]; then
        print_error "Storage type mismatch! Kafka resource: $storage_type, Node pool: $node_pool_storage_type"
        exit 1
    fi
    
    # For JBOD, verify volumes count matches
    if [[ "$storage_type" == "jbod" ]]; then
        local kafka_vol_count=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage.volumes[*].id}' 2>/dev/null | wc -w)
        local pool_vol_count=$(oc get kafkanodepool kafka -n "$NAMESPACE" -o jsonpath='{.spec.storage.volumes[*].id}' 2>/dev/null | wc -w)
        
        if [[ "$kafka_vol_count" != "$pool_vol_count" ]]; then
            print_error "JBOD volumes count mismatch! Kafka resource: $kafka_vol_count, Node pool: $pool_vol_count"
            exit 1
        fi
        print_success "Verified: Broker node pool replicas and JBOD storage match Kafka resource exactly ($kafka_vol_count volumes)"
    else
        # Single storage verification
        local storage_size=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage.size}' 2>/dev/null)
        local node_pool_storage_size=$(oc get kafkanodepool kafka -n "$NAMESPACE" -o jsonpath='{.spec.storage.size}' 2>/dev/null)
        
        if [[ "$node_pool_storage_size" != "$storage_size" ]]; then
            print_error "Storage size mismatch! Kafka resource: $storage_size, Node pool: $node_pool_storage_size"
            exit 1
        fi
        print_success "Verified: Broker node pool replicas and storage match Kafka resource exactly"
    fi
    
    # Enable node pools in Kafka resource
    print_info "Enabling node pools in Kafka resource..."
    oc annotate kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" \
        strimzi.io/node-pools=enabled \
        --overwrite
    
    if [[ $? -ne 0 ]]; then
        print_error "Failed to enable node pools in Kafka resource"
        exit 1
    fi
    
    print_success "Node pools enabled in Kafka resource"
    
    # Wait for Kafka to reconcile with node pools
    print_info "Waiting for Kafka to reconcile with node pools..."
    sleep 10
    
    # Verify node pools are being used
    local node_pool_check=$(oc get kafkanodepool -n "$NAMESPACE" -l strimzi.io/cluster="$KAFKA_INSTANCE" --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ "$node_pool_check" -gt 0 ]]; then
        print_success "Kafka instance successfully migrated to node pools"
    else
        print_warning "Node pools may not be fully reconciled yet, but migration initiated"
    fi
    
    # Remove replicated properties from Kafka resource
    # Remove .spec.kafka.replicas and .spec.kafka.storage as they are now in the node pool
    print_info "Removing replicated properties from Kafka resource (spec.kafka.replicas and spec.kafka.storage)..."
    
    # Use oc patch to remove these fields
    # First, check if these fields exist before trying to remove them
    local has_replicas=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.replicas}' 2>/dev/null)
    local has_storage=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage}' 2>/dev/null)
    
    if [[ -n "$has_replicas" && "$has_replicas" != "null" ]]; then
        # Remove spec.kafka.replicas
        oc patch kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" --type=json -p='[{"op": "remove", "path": "/spec/kafka/replicas"}]' 2>/dev/null
        if [[ $? -eq 0 ]]; then
            print_success "Removed spec.kafka.replicas from Kafka resource"
        else
            print_warning "Failed to remove spec.kafka.replicas (may have already been removed)"
        fi
    fi
    
    if [[ -n "$has_storage" && "$has_storage" != "null" && "$has_storage" != "{}" ]]; then
        # Remove spec.kafka.storage
        oc patch kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" --type=json -p='[{"op": "remove", "path": "/spec/kafka/storage"}]' 2>/dev/null
        if [[ $? -eq 0 ]]; then
            print_success "Removed spec.kafka.storage from Kafka resource"
        else
            print_warning "Failed to remove spec.kafka.storage (may have already been removed)"
        fi
    fi
    
    if [[ -z "$has_replicas" || "$has_replicas" == "null" ]] && [[ -z "$has_storage" || "$has_storage" == "null" || "$has_storage" == "{}" ]]; then
        print_info "Replicated properties already removed from Kafka resource"
    fi
}

check_prerequisites() {
    if [[ "$SKIP_PREREQ_CHECK" == "true" ]]; then
        print_warning "Skipping prerequisite checks"
        return 0
    fi
    
    print_info "Checking prerequisites..."
    
    # Check if THIS specific Kafka instance is using node pools
    # Filter by cluster label to only check node pools for this Kafka instance
    local node_pools=$(oc get kafkanodepool -n "$NAMESPACE" -l strimzi.io/cluster="$KAFKA_INSTANCE" --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [[ "$node_pools" -eq 0 ]]; then
        # Check if Kafka instance has direct broker configuration (old style, not using node pools)
        local kafka_replicas=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.replicas}' 2>/dev/null)
        
        if [[ -n "$kafka_replicas" && "$kafka_replicas" != "null" ]]; then
            print_warning "Kafka instance '$KAFKA_INSTANCE' is not using node pools yet (has direct broker configuration)."
            print_info "Migrating Kafka instance to node pools first..."
            migrate_kafka_to_node_pools
            echo
        else
            print_error "No KafkaNodePool resources found for Kafka instance '$KAFKA_INSTANCE'."
            print_error "Unable to determine Kafka configuration. Please check the Kafka resource manually."
            exit 1
        fi
    else
        print_success "Kafka instance '$KAFKA_INSTANCE' is using node pools (found $node_pools node pool(s))"
    fi
    
    # Check if controller pool already exists
    if oc get kafkanodepool "$CONTROLLER_POOL_NAME" -n "$NAMESPACE" &> /dev/null; then
        print_warning "Controller node pool '$CONTROLLER_POOL_NAME' already exists"
        read -p "Do you want to continue with existing controller pool? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 0
        fi
    else
        print_info "Controller node pool '$CONTROLLER_POOL_NAME' does not exist (will be created)"
    fi
}

# Function to create controller node pool
create_controller_node_pool() {
    # Set default controller pool name if not provided
    if [[ -z "$CONTROLLER_POOL_NAME" ]]; then
        CONTROLLER_POOL_NAME="controller-${KAFKA_INSTANCE}"
    fi
    
    print_info "Creating controller node pool '$CONTROLLER_POOL_NAME'..."
    
    # Determine controller replicas: use user-provided value if set, otherwise get from ZooKeeper
    local controller_replicas=""
    if [[ -n "$CONTROLLER_REPLICAS" ]]; then
        controller_replicas="$CONTROLLER_REPLICAS"
        print_info "Using user-provided controller replicas=${controller_replicas}"
    else
        # Extract ZooKeeper replicas from Kafka resource
        local zookeeper_replicas=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.zookeeper.replicas}' 2>/dev/null)
        if [[ -z "$zookeeper_replicas" || "$zookeeper_replicas" == "null" ]]; then
            print_error "ZooKeeper replicas not found in Kafka resource spec.zookeeper.replicas"
            exit 1
        fi
        controller_replicas="$zookeeper_replicas"
        print_info "Using ZooKeeper replicas=${controller_replicas} as default"
    fi
    
    # Determine storage configuration
    # First, check what storage the broker node pool uses (if it exists)
    local broker_storage_type=""
    local broker_node_pool=""
    
    # Check if 'kafka' node pool exists for this cluster
    local kafka_pool_cluster=$(oc get kafkanodepool kafka -n "$NAMESPACE" -o jsonpath='{.metadata.labels.strimzi\.io/cluster}' 2>/dev/null || echo "")
    
    if [[ -n "$kafka_pool_cluster" && "$kafka_pool_cluster" == "$KAFKA_INSTANCE" ]]; then
        broker_node_pool="kafka"
        broker_storage_type=$(oc get kafkanodepool kafka -n "$NAMESPACE" -o jsonpath='{.spec.storage.type}' 2>/dev/null)
        if [[ -n "$broker_storage_type" && "$broker_storage_type" != "null" ]]; then
            print_info "Broker node pool 'kafka' uses storage type: ${broker_storage_type}"
        fi
    else
        # Fallback: check Kafka resource directly (before migration to node pools)
        broker_storage_type=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage.type}' 2>/dev/null)
        if [[ -n "$broker_storage_type" && "$broker_storage_type" != "null" ]]; then
            print_info "Kafka resource uses storage type: ${broker_storage_type}"
        fi
    fi
    
    # Determine controller storage type
    local storage_type=""
    
    # Check if user provided comma-separated sizes (indicating JBOD)
    local has_comma_sizes=false
    if [[ -n "$CONTROLLER_STORAGE_SIZES" && "$CONTROLLER_STORAGE_SIZES" == *","* ]]; then
        has_comma_sizes=true
    fi
    
    # Determine controller storage type
    if [[ "$has_comma_sizes" == true ]]; then
        # Comma-separated sizes detected - auto-detect jbod type
        if [[ -n "$CONTROLLER_STORAGE_TYPE" && "$CONTROLLER_STORAGE_TYPE" != "jbod" ]]; then
            print_error "Comma-separated sizes provided (indicating JBOD) but storage type is set to '${CONTROLLER_STORAGE_TYPE}'"
            print_error "When providing comma-separated sizes, storage type must be 'jbod' or omitted (will default to jbod)"
            exit 1
        fi
        storage_type="jbod"
        print_info "Auto-detected JBOD storage type from comma-separated sizes"
    elif [[ -n "$CONTROLLER_STORAGE_TYPE" ]]; then
        # Validate user-provided storage type
        if [[ "$CONTROLLER_STORAGE_TYPE" != "persistent-claim" && "$CONTROLLER_STORAGE_TYPE" != "ephemeral" && "$CONTROLLER_STORAGE_TYPE" != "jbod" ]]; then
            print_error "Invalid controller storage type: $CONTROLLER_STORAGE_TYPE"
            print_error "Valid options are: persistent-claim, ephemeral, jbod"
            exit 1
        fi
        storage_type="$CONTROLLER_STORAGE_TYPE"
        print_info "Using user-provided controller storage type=${storage_type}"
        
        # Validate that if jbod is specified, sizes are provided
        if [[ "$storage_type" == "jbod" && -z "$CONTROLLER_STORAGE_SIZES" ]]; then
            # Check if we can default to broker's JBOD config
            if [[ "$broker_storage_type" != "jbod" ]]; then
                print_error "JBOD storage type specified but no sizes provided (--controller-storage-sizes)"
                print_error "Please provide --controller-storage-sizes with comma-separated sizes when using --controller-storage-type jbod"
                exit 1
            fi
        fi
    else
        # Default to broker storage type if available, otherwise persistent-claim
        if [[ -n "$broker_storage_type" && "$broker_storage_type" != "null" ]]; then
            storage_type="$broker_storage_type"
            print_info "Using broker storage type as default: ${storage_type}"
        else
            storage_type="persistent-claim"
            print_info "Using default controller storage type=${storage_type} (broker storage type not found)"
        fi
    fi
    
    # Build storage YAML based on storage type
    local storage_yaml=""
    
    if [[ "$storage_type" == "jbod" ]]; then
        # Handle JBOD storage
        if [[ -n "$CONTROLLER_STORAGE_SIZES" ]]; then
            # User provided comma-separated sizes
            print_info "Using user-provided JBOD sizes for controller: ${CONTROLLER_STORAGE_SIZES}"
            # Get storage class to apply to all volumes
            local jbod_storage_class=""
            if [[ -n "$CONTROLLER_STORAGE_CLASS" ]]; then
                jbod_storage_class="$CONTROLLER_STORAGE_CLASS"
            elif [[ "$broker_storage_type" == "jbod" && -n "$broker_node_pool" ]]; then
                # Try to get storage class from first volume of broker's JBOD config
                jbod_storage_class=$(oc get kafkanodepool "$broker_node_pool" -n "$NAMESPACE" -o jsonpath='{.spec.storage.volumes[0].class}' 2>/dev/null)
            elif [[ "$broker_storage_type" == "jbod" ]]; then
                jbod_storage_class=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage.volumes[0].class}' 2>/dev/null)
            fi
            # Fallback to ZooKeeper storage class
            if [[ -z "$jbod_storage_class" || "$jbod_storage_class" == "null" ]]; then
                jbod_storage_class=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.zookeeper.storage.class}' 2>/dev/null)
            fi
            storage_yaml=$(build_jbod_storage_yaml_from_sizes "$CONTROLLER_STORAGE_SIZES" "$jbod_storage_class")
        elif [[ "$broker_storage_type" == "jbod" && -n "$broker_node_pool" ]]; then
            # Default to broker's JBOD configuration
            print_info "Using broker's JBOD configuration as default for controller"
            storage_yaml=$(build_jbod_storage_yaml_from_pool "$broker_node_pool")
        elif [[ "$broker_storage_type" == "jbod" ]]; then
            # Broker uses JBOD but not in node pool yet - get from Kafka resource
            print_info "Using broker's JBOD configuration from Kafka resource as default for controller"
            storage_yaml=$(build_jbod_storage_yaml_from_kafka)
        else
            print_error "JBOD storage type specified but no sizes provided and broker doesn't use JBOD"
            print_error "Please provide --controller-storage-sizes with comma-separated sizes when using --controller-storage-type jbod"
            exit 1
        fi
    elif [[ "$storage_type" == "ephemeral" ]]; then
        # Ephemeral storage
        if [[ -n "$CONTROLLER_STORAGE_SIZES" ]]; then
            print_warning "Storage sizes provided for ephemeral storage type, but it will be ignored"
        fi
        storage_yaml="    type: ephemeral"
        print_info "Using ephemeral storage (no size required)"
    else
        # Persistent-claim storage
        # Validate storage size requirement
        local controller_storage_size=""
        if [[ -n "$CONTROLLER_STORAGE_SIZES" ]]; then
            # Single size provided (non-JBOD)
            controller_storage_size="$CONTROLLER_STORAGE_SIZES"
            print_info "Using user-provided controller storage size=${controller_storage_size}"
        elif [[ "$broker_storage_type" == "persistent-claim" && -n "$broker_node_pool" ]]; then
            # Default to broker's storage size
            controller_storage_size=$(oc get kafkanodepool "$broker_node_pool" -n "$NAMESPACE" -o jsonpath='{.spec.storage.size}' 2>/dev/null)
            if [[ -n "$controller_storage_size" && "$controller_storage_size" != "null" ]]; then
                print_info "Using broker storage size as default: ${controller_storage_size}"
            fi
        elif [[ "$broker_storage_type" == "persistent-claim" ]]; then
            # Get from Kafka resource
            controller_storage_size=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage.size}' 2>/dev/null)
            if [[ -n "$controller_storage_size" && "$controller_storage_size" != "null" ]]; then
                print_info "Using broker storage size from Kafka resource as default: ${controller_storage_size}"
            fi
        fi
        
        if [[ -z "$controller_storage_size" || "$controller_storage_size" == "null" ]]; then
            print_error "Controller storage type is '${storage_type}', which requires storage size to be provided."
            print_error "Please provide --controller-storage-sizes when using storage type '${storage_type}'."
            exit 1
        fi
        
        # Build storage YAML
        storage_yaml="    type: ${storage_type}\n    size: ${controller_storage_size}"
        
        # Get storage class
        local storage_class=""
        if [[ -n "$CONTROLLER_STORAGE_CLASS" ]]; then
            storage_class="$CONTROLLER_STORAGE_CLASS"
            print_info "Using user-provided controller storage class=${storage_class}"
        elif [[ "$broker_storage_type" == "persistent-claim" && -n "$broker_node_pool" ]]; then
            storage_class=$(oc get kafkanodepool "$broker_node_pool" -n "$NAMESPACE" -o jsonpath='{.spec.storage.class}' 2>/dev/null)
            if [[ -n "$storage_class" && "$storage_class" != "null" ]]; then
                print_info "Using broker storage class as default: ${storage_class}"
            fi
        elif [[ "$broker_storage_type" == "persistent-claim" ]]; then
            storage_class=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage.class}' 2>/dev/null)
            if [[ -n "$storage_class" && "$storage_class" != "null" ]]; then
                print_info "Using broker storage class from Kafka resource as default: ${storage_class}"
            fi
        fi
        
        # Fallback to ZooKeeper storage class if broker doesn't have one
        if [[ -z "$storage_class" || "$storage_class" == "null" ]]; then
            storage_class=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.zookeeper.storage.class}' 2>/dev/null)
            if [[ -n "$storage_class" && "$storage_class" != "null" ]]; then
                print_info "Using ZooKeeper storage class as default: ${storage_class}"
            fi
        fi
        
        # Get optional storage fields
        local storage_delete_claim=""
        local storage_id=""
        
        if [[ "$broker_storage_type" == "persistent-claim" && -n "$broker_node_pool" ]]; then
            storage_delete_claim=$(oc get kafkanodepool "$broker_node_pool" -n "$NAMESPACE" -o jsonpath='{.spec.storage.deleteClaim}' 2>/dev/null)
            storage_id=$(oc get kafkanodepool "$broker_node_pool" -n "$NAMESPACE" -o jsonpath='{.spec.storage.id}' 2>/dev/null)
        elif [[ "$broker_storage_type" == "persistent-claim" ]]; then
            storage_delete_claim=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage.deleteClaim}' 2>/dev/null)
            storage_id=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.storage.id}' 2>/dev/null)
        fi
        
        # Fallback to ZooKeeper if not found in broker
        if [[ -z "$storage_delete_claim" || "$storage_delete_claim" == "null" ]]; then
            storage_delete_claim=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.zookeeper.storage.deleteClaim}' 2>/dev/null)
        fi
        if [[ -z "$storage_id" || "$storage_id" == "null" ]]; then
            storage_id=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.zookeeper.storage.id}' 2>/dev/null)
        fi
        
        # Add optional fields
        if [[ -n "$storage_class" && "$storage_class" != "null" ]]; then
            storage_yaml="${storage_yaml}\n    class: ${storage_class}"
        fi
        if [[ -n "$storage_delete_claim" && "$storage_delete_claim" != "null" ]]; then
            storage_yaml="${storage_yaml}\n    deleteClaim: ${storage_delete_claim}"
        fi
        if [[ -n "$storage_id" && "$storage_id" != "null" ]]; then
            storage_yaml="${storage_yaml}\n    id: ${storage_id}"
        fi
    fi
    
    # Create KafkaNodePool YAML
    cat <<EOF | oc apply -f -
apiVersion: ${KAFKANODEPOOL_API_VERSION}
kind: KafkaNodePool
metadata:
  name: ${CONTROLLER_POOL_NAME}
  namespace: ${NAMESPACE}
  labels:
    strimzi.io/cluster: ${KAFKA_INSTANCE}
spec:
  replicas: ${controller_replicas}
  roles:
    - controller
  storage:
$(echo -e "$storage_yaml")
EOF
    
    if [[ $? -ne 0 ]]; then
        print_error "Failed to create controller node pool"
        exit 1
    fi
    
    # Wait for all controller pod replicas to be ready
    print_info "Waiting for all ${controller_replicas} controller pod replicas to be ready..."
    local timeout=600  # 10 minutes for pods to start
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        # Get controller pods for this cluster and pool
        # Controller pods are named like: {cluster-name}-{pool-name}-{replica-number}
        local controller_pod_pattern="${KAFKA_INSTANCE}-${CONTROLLER_POOL_NAME}-"
        local controller_pods_raw=$(oc get pods -n "$NAMESPACE" \
            -l strimzi.io/cluster="$KAFKA_INSTANCE",strimzi.io/kind=Kafka \
            --no-headers 2>/dev/null | grep "^${controller_pod_pattern}" | wc -l)
        
        # Trim whitespace and ensure numeric value (wc -l may include newlines)
        local controller_pods=$(echo "$controller_pods_raw" | tr -d '[:space:]')
        # Default to 0 if empty or not numeric
        if [[ ! "$controller_pods" =~ ^[0-9]+$ ]]; then
            controller_pods=0
        fi
        
        # Count ready controller pods
        local ready_pods=0
        local all_pods=$(oc get pods -n "$NAMESPACE" \
            -l strimzi.io/cluster="$KAFKA_INSTANCE",strimzi.io/kind=Kafka \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)
        
        while IFS=$'\t' read -r pod_name ready_status; do
            # Match pods that start with the controller pod pattern
            # This matches: ${KAFKA_INSTANCE}-${CONTROLLER_POOL_NAME}-{number}
            if [[ "$pod_name" == ${controller_pod_pattern}* ]] && [[ "$ready_status" == "True" ]]; then
                ready_pods=$((ready_pods + 1))
            fi
        done <<< "$all_pods"
        
        # Ensure ready_pods is numeric
        ready_pods=${ready_pods:-0}
        
        if [[ "$controller_pods" -ge "$controller_replicas" && "$ready_pods" -ge "$controller_replicas" ]]; then
            print_success "All ${controller_replicas} controller pod replicas are ready"
            return 0
        fi
        
        if [[ "$controller_pods" -gt 0 ]]; then
            echo -n "Pods: ${controller_pods}/${controller_replicas}, Ready: ${ready_pods}/${controller_replicas}... "
        fi
        
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo
    print_error "Controller pods did not become ready within $timeout seconds"
    print_error "Expected ${controller_replicas} pods, but may not all be ready"
    exit 1
}

# Function to enable KRaft migration
enable_kraft_migration() {
    print_info "Enabling KRaft migration on Kafka instance..."
    
    # Check current annotation
    local current_annotation=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.strimzi\.io/kraft}' 2>/dev/null || echo "")
    
    if [[ "$current_annotation" == "migration" ]]; then
        print_info "KRaft migration is already enabled"
        return 0
    fi
    
    # Patch Kafka resource to enable migration
    oc annotate kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" \
        strimzi.io/kraft=migration \
        --overwrite
    
    print_success "KRaft migration enabled"
}

# Function to get migration state
get_migration_state() {
    local state=""
    
    # First try: kafkaMetadataState as a string directly (this is what the YAML shows)
    state=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.status.kafkaMetadataState}' 2>/dev/null)
    
    # If empty, try kafkaMetadataState.state (in case it's an object with .state field in other versions)
    if [[ -z "$state" || "$state" == "null" ]]; then
        state=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.status.kafkaMetadataState.state}' 2>/dev/null)
    fi
    
    # Fallback to kafkaMigrationStatus.state (for older versions)
    if [[ -z "$state" || "$state" == "null" ]]; then
        state=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.status.kafkaMigrationStatus.state}' 2>/dev/null)
    fi
    
    # Clean up any whitespace
    state=$(echo "$state" | tr -d '[:space:]')
    
    # Return "Unknown" if still empty
    if [[ -z "$state" || "$state" == "null" ]]; then
        echo "Unknown"
    else
        echo "$state"
    fi
}

# Function to get metadata state
get_metadata_state() {
    local state=""
    
    # First try: kafkaMetadataState as a string directly (this is what the YAML shows)
    state=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.status.kafkaMetadataState}' 2>/dev/null)
    
    # If empty, try kafkaMetadataState.state (in case it's an object with .state field in other versions)
    if [[ -z "$state" || "$state" == "null" ]]; then
        state=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.status.kafkaMetadataState.state}' 2>/dev/null)
    fi
    
    # Clean up any whitespace
    state=$(echo "$state" | tr -d '[:space:]')
    
    # Return "Unknown" if still empty
    if [[ -z "$state" || "$state" == "null" ]]; then
        echo "Unknown"
    else
        echo "$state"
    fi
}

# Function to wait for migration state
wait_for_migration_state() {
    local target_state=$1
    local timeout=${2:-$WAIT_TIMEOUT}
    
    print_info "Waiting for migration state: $target_state (timeout: ${timeout}s)..."
    
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local current_state=$(get_migration_state)
        
        if [[ "$current_state" == "$target_state" ]]; then
            print_success "Migration state reached: $target_state"
            return 0
        fi
        
        if [[ "$current_state" != "Unknown" && "$current_state" != "" ]]; then
            echo -n "Current state: $current_state... "
        fi
        
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo
    print_error "Timeout waiting for migration state: $target_state"
    print_error "Current state: $(get_migration_state)"
    exit 1
}

# Function to monitor migration progress
monitor_migration() {
    print_info "Monitoring migration progress..."
    
    # Get current state
    local current_state=$(get_migration_state)
    
    # Handle empty or unknown states
    if [[ -z "$current_state" || "$current_state" == "Unknown" ]]; then
        print_warning "Migration state is not yet available. Waiting for initial state..."
        sleep 10
        current_state=$(get_migration_state)
        if [[ -z "$current_state" || "$current_state" == "Unknown" ]]; then
            # Try to get more information for debugging
            print_error "Unable to determine migration state. Checking Kafka resource status..."
            local metadata_state_debug=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.status.kafkaMetadataState}' 2>/dev/null || echo "not found")
            local metadata_state_dot_debug=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.status.kafkaMetadataState.state}' 2>/dev/null || echo "not found")
            local migration_status_debug=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.status.kafkaMigrationStatus}' 2>/dev/null || echo "not found")
            print_error "Debug info - kafkaMetadataState object: ${metadata_state_debug}"
            print_error "Debug info - kafkaMetadataState.state: ${metadata_state_dot_debug}"
            print_error "Debug info - kafkaMigrationStatus: ${migration_status_debug}"
            print_error "Please check the Kafka resource manually:"
            print_error "  oc get kafka $KAFKA_INSTANCE -n $NAMESPACE -o jsonpath='{.status.kafkaMetadataState.state}'"
            print_error "  oc get kafka $KAFKA_INSTANCE -n $NAMESPACE -o yaml | grep -A 10 'status:'"
            exit 1
        fi
    fi
    
    print_info "Current migration state: $current_state"
    
    # Handle case where we're already past KRaftMigration
    if [[ "$current_state" == "KRaftDualWriting" ]]; then
        print_info "Migration is already in KRaftDualWriting state. Continuing..."
    elif [[ "$current_state" == "KRaftPostMigration" ]]; then
        print_info "Migration is already in KRaftPostMigration state. Ready to enable KRaft mode."
        return 0
    elif [[ "$current_state" != "KRaftMigration" ]]; then
        # Wait for KRaftMigration state
        wait_for_migration_state "KRaftMigration"
    else
        print_info "Kafka is already in KRaftMigration state."
    fi
    
    print_info "Migration has started. Kafka is now in KRaftMigration state."
    print_info "This phase may take some time as the cluster migrates to KRaft..."
    
    # Wait for KRaftDualWriting state
    wait_for_migration_state "KRaftDualWriting"
    
    print_info "Kafka is now in KRaftDualWriting state."
    print_info "The cluster is writing to both ZooKeeper and KRaft metadata..."
    
    # Wait for KRaftPostMigration state
    wait_for_migration_state "KRaftPostMigration"
    
    print_success "Migration completed! Kafka is now in KRaftPostMigration state."
    print_info "Ready to enable KRaft mode."
}

# Function to enable KRaft mode
enable_kraft_mode() {
    print_info "Enabling KRaft mode..."
    
    # Patch Kafka resource to enable KRaft
    oc annotate kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" \
        strimzi.io/kraft=enabled \
        --overwrite
    
    print_success "KRaft mode enabled"
    print_info "The cluster will now restart in KRaft mode."
}

# Function to verify final state
verify_final_state() {
    print_info "Verifying final migration state..."
    
    local kraft_annotation=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.strimzi\.io/kraft}' 2>/dev/null || echo "")
    
    if [[ "$kraft_annotation" != "enabled" ]]; then
        print_warning "KRaft annotation is: $kraft_annotation"
        print_warning "Please verify the migration status manually."
        return 1
    fi
    
    # Wait for metadata state to reach KRaft
    print_info "Waiting for metadata state to reach 'KRaft' (final state)..."
    local timeout=${WAIT_TIMEOUT}
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        local metadata_state=$(get_metadata_state)
        
        if [[ "$metadata_state" == "KRaft" ]]; then
            print_success "Kafka metadata state is now 'KRaft' - migration fully completed!"
            print_info "Migration from ZooKeeper to KRaft is complete."
            
            # Remove ZooKeeper-related configuration from Kafka resource
            print_info "Removing ZooKeeper-related configuration from Kafka resource..."
            
            # Remove spec.zookeeper section
            local has_zookeeper=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.zookeeper}' 2>/dev/null)
            if [[ -n "$has_zookeeper" && "$has_zookeeper" != "null" && "$has_zookeeper" != "{}" ]]; then
                print_info "Removing spec.zookeeper section..."
                oc patch kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" --type=json -p='[{"op": "remove", "path": "/spec/zookeeper"}]' 2>/dev/null
                if [[ $? -eq 0 ]]; then
                    print_success "Removed spec.zookeeper from Kafka resource"
                else
                    print_warning "Failed to remove spec.zookeeper (may have already been removed)"
                fi
            else
                print_info "spec.zookeeper already removed or not present"
            fi
            
            # Remove log.message.format.version from spec.kafka.config if present
            local has_log_format=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.config.log\.message\.format\.version}' 2>/dev/null)
            if [[ -n "$has_log_format" && "$has_log_format" != "null" ]]; then
                print_info "Removing log.message.format.version from spec.kafka.config..."
                oc patch kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" --type=json -p='[{"op": "remove", "path": "/spec/kafka/config/log.message.format.version"}]' 2>/dev/null
                if [[ $? -eq 0 ]]; then
                    print_success "Removed log.message.format.version from Kafka config"
                else
                    print_warning "Failed to remove log.message.format.version (may have already been removed)"
                fi
            else
                print_info "log.message.format.version not present in Kafka config"
            fi
            
            # Remove inter.broker.protocol.version from spec.kafka.config if present
            local has_protocol_version=$(oc get kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.spec.kafka.config.inter\.broker\.protocol\.version}' 2>/dev/null)
            if [[ -n "$has_protocol_version" && "$has_protocol_version" != "null" ]]; then
                print_info "Removing inter.broker.protocol.version from spec.kafka.config..."
                oc patch kafka "$KAFKA_INSTANCE" -n "$NAMESPACE" --type=json -p='[{"op": "remove", "path": "/spec/kafka/config/inter.broker.protocol.version"}]' 2>/dev/null
                if [[ $? -eq 0 ]]; then
                    print_success "Removed inter.broker.protocol.version from Kafka config"
                else
                    print_warning "Failed to remove inter.broker.protocol.version (may have already been removed)"
                fi
            else
                print_info "inter.broker.protocol.version not present in Kafka config"
            fi
            
            return 0
        fi
        
        if [[ "$metadata_state" == "PreKRaft" ]]; then
            print_info "Metadata state: PreKRaft (ZooKeeper resources being deleted)..."
        elif [[ "$metadata_state" != "Unknown" && "$metadata_state" != "" ]]; then
            echo -n "Current metadata state: $metadata_state... "
        fi
        
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    
    echo
    print_warning "Timeout waiting for metadata state 'KRaft'"
    print_warning "Current metadata state: $(get_metadata_state)"
    print_warning "Migration may still be in progress. Please check manually."
    return 1
}

# Main execution
main() {
    print_info "Starting ZooKeeper to KRaft migration for Kafka instance: $KAFKA_INSTANCE in namespace: $NAMESPACE"
    echo
    
    # Pre-flight checks
    check_oc_available
    
    # Detect KafkaNodePool API version from cluster
    KAFKANODEPOOL_API_VERSION=$(get_kafkanodepool_api_version)
    print_info "Using KafkaNodePool API version: $KAFKANODEPOOL_API_VERSION"
    
    check_namespace
    check_kafka_instance
    check_kraft_status
    check_prerequisites
    
    echo
    print_info "All prerequisites met. Starting migration process..."
    echo
    
    # Step 1: Enable KRaft migration (must be done before creating controller node pool)
    # In ZooKeeper-based clusters, controller node pools are not allowed
    enable_kraft_migration
    echo
    
    # Wait a moment for the operator to reconcile after enabling migration
    print_info "Waiting for operator to reconcile after enabling migration..."
    sleep 5
    
    # Step 2: Create controller node pool (if it doesn't exist)
    # Now that migration is enabled, controller node pools are allowed
    if ! oc get kafkanodepool "$CONTROLLER_POOL_NAME" -n "$NAMESPACE" &> /dev/null; then
        create_controller_node_pool
        echo
    else
        print_info "Using existing controller node pool: $CONTROLLER_POOL_NAME"
        echo
    fi
    
    # Step 3: Monitor migration progress
    monitor_migration
    echo
    
    # Step 4: Enable KRaft mode
    enable_kraft_mode
    echo
    
    # Step 5: Verify final state
    sleep 10  # Give it a moment to update
    verify_final_state
    
    echo
    print_success "Migration process completed!"
    print_info "You can monitor the Kafka pods with: oc get pods -n $NAMESPACE -l strimzi.io/cluster=$KAFKA_INSTANCE"
}

# Run main function
main "$@"


