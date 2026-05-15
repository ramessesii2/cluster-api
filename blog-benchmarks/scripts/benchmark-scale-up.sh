#!/bin/bash
# Benchmark: Scale-Up Latency
# Measures time from replica count change to all nodes reporting Ready
#
# Usage: ./benchmark-scale-up.sh <provider> <type> <start_replicas> <end_replicas>
# Example: ./benchmark-scale-up.sh azure machinepool 5 20
# Example: ./benchmark-scale-up.sh azure aks 5 20
#
# type: machinepool | machinedeployment | aks
#   - machinepool:     self-managed MachinePool (VMSS/ASG), namespace mp-bench-<provider>
#   - machinedeployment: self-managed MachineDeployment, namespace md-bench-<provider>
#   - aks:             AKS managed cluster (AzureManagedMachinePool), namespace aks-bench-<provider>

set -euo pipefail

PROVIDER="${1:-azure}"
TYPE="${2:-machinepool}"  # machinepool, machinedeployment, or aks
START_REPLICAS="${3:-5}"
END_REPLICAS="${4:-20}"
RESULTS_DIR="./results/${PROVIDER}/scale-up"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"; }
error() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"; exit 1; }

# Ensure a value is a valid integer, defaulting to 0.
# jsonpath returns "" (not "0") when a status field is absent mid-reconciliation,
# which breaks bash arithmetic comparisons.
sanitize_int() { local v="${1:-0}"; echo "${v:-0}"; }

# Determine namespace and resource based on type and provider
if [[ "$TYPE" == "machinepool" ]]; then
    NAMESPACE="mp-bench-${PROVIDER}"
    RESOURCE_TYPE="machinepool"
    RESOURCE_NAME="mp-bench-${PROVIDER}-workers"
elif [[ "$TYPE" == "aks" ]]; then
    NAMESPACE="aks-bench-${PROVIDER}"
    RESOURCE_TYPE="machinepool"
    RESOURCE_NAME="aks-bench-${PROVIDER}-workers"
else
    NAMESPACE="md-bench-${PROVIDER}"
    RESOURCE_TYPE="machinedeployment"
    RESOURCE_NAME="md-bench-${PROVIDER}-workers"
fi

# AKS is Azure-only
if [[ "$TYPE" == "aks" && "$PROVIDER" != "azure" ]]; then
    error "AKS is only supported with provider=azure (got provider=$PROVIDER)"
fi

mkdir -p "$RESULTS_DIR"

log "Starting Scale-Up Benchmark"
log "Provider: $PROVIDER, Type: $TYPE"
log "Scaling from $START_REPLICAS to $END_REPLICAS replicas"
log "Namespace: $NAMESPACE, Resource: $RESOURCE_NAME"

# Function to count ready nodes for the cluster
count_ready_nodes() {
    local cluster_name
    if [[ "$TYPE" == "machinepool" ]]; then
        cluster_name="mp-bench-${PROVIDER}"
    elif [[ "$TYPE" == "aks" ]]; then
        cluster_name="aks-bench-${PROVIDER}"
    else
        cluster_name="md-bench-${PROVIDER}"
    fi
    
    # Get kubeconfig for workload cluster
    local kubeconfig_secret="${cluster_name}-kubeconfig"
    
    kubectl get secret -n "$NAMESPACE" "$kubeconfig_secret" -o jsonpath='{.data.value}' 2>/dev/null | base64 -d > /tmp/workload-kubeconfig 2>/dev/null || true
    
    local count=0
    if [[ -f /tmp/workload-kubeconfig && -s /tmp/workload-kubeconfig ]]; then
        count=$(kubectl --kubeconfig=/tmp/workload-kubeconfig get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo "0")
    fi
    sanitize_int "$count"
}

# Get current ready replica count from the resource's own status.
# NOTE: For MachinePool (and AKS) clusters, the Cluster object does NOT aggregate worker counts
# (status.workers is empty, conditions report "NoWorkers"/"NoReplicas"). We must read
# from the MachinePool resource directly.
get_current_replicas() {
    local count
    if [[ "$TYPE" == "machinepool" || "$TYPE" == "aks" ]]; then
        count=$(kubectl get machinepool -n "$NAMESPACE" "$RESOURCE_NAME" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    else
        count=$(kubectl get machinedeployment -n "$NAMESPACE" "$RESOURCE_NAME" \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    fi
    sanitize_int "$count"
}

# Record start time
SCALE_START_TIME=$(date +%s.%N)
SCALE_START_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

log "Recording initial state..."
INITIAL_REPLICAS=$(get_current_replicas)
INITIAL_NODES=$(count_ready_nodes)
log "Initial ready replicas: $INITIAL_REPLICAS, Initial ready nodes: $INITIAL_NODES"

# Scale the resource
log "Scaling $RESOURCE_TYPE/$RESOURCE_NAME to $END_REPLICAS replicas..."
if [[ "$TYPE" == "machinepool" || "$TYPE" == "aks" ]]; then
    kubectl patch machinepool -n "$NAMESPACE" "$RESOURCE_NAME" --type=merge -p "{\"spec\":{\"replicas\":$END_REPLICAS}}"
else
    kubectl patch machinedeployment -n "$NAMESPACE" "$RESOURCE_NAME" --type=merge -p "{\"spec\":{\"replicas\":$END_REPLICAS}}"
fi

# Initialize tracking arrays
declare -a NODE_READY_TIMES=()
FIRST_NODE_TIME=""
LAST_CHECK_COUNT=$(sanitize_int "$INITIAL_REPLICAS")

log "Monitoring scale-up progress..."
echo ""

# Poll until all replicas are ready or timeout (30 minutes)
TIMEOUT=$((30 * 60))
ELAPSED=0
POLL_INTERVAL=5

while true; do
    CURRENT_REPLICAS=$(get_current_replicas)
    CURRENT_NODES=$(count_ready_nodes)
    CURRENT_TIME=$(date +%s.%N)
    ELAPSED_SINCE_START=$(echo "$CURRENT_TIME - $SCALE_START_TIME" | bc)

    # For MachinePool and AKS, the Cluster object may not aggregate worker counts.
    # Use the best available signal: the higher of MachinePool's status.readyReplicas
    # and the actual workload cluster worker count (total nodes minus 1 for control-plane
    # or system pool node).
    EFFECTIVE_READY="$CURRENT_REPLICAS"
    if [[ "$TYPE" == "machinepool" || "$TYPE" == "aks" ]]; then
        WORKER_NODES=$((CURRENT_NODES > 0 ? CURRENT_NODES - 1 : 0))
        if [[ "$WORKER_NODES" -gt "$CURRENT_REPLICAS" ]]; then
            warn "MachinePool status lag: ${CURRENT_REPLICAS} readyReplicas but ${WORKER_NODES} worker nodes actually Ready"
            EFFECTIVE_READY="$WORKER_NODES"
        fi
    fi

    # Track when new nodes become ready
    if [[ "$EFFECTIVE_READY" -gt "$LAST_CHECK_COUNT" ]]; then
        NEW_NODES=$((EFFECTIVE_READY - LAST_CHECK_COUNT))
        for i in $(seq 1 $NEW_NODES); do
            NODE_READY_TIMES+=("$ELAPSED_SINCE_START")
        done
        
        if [[ -z "$FIRST_NODE_TIME" ]]; then
            FIRST_NODE_TIME="$ELAPSED_SINCE_START"
        fi
        
        LAST_CHECK_COUNT=$EFFECTIVE_READY
    fi
    
    # Progress indicator
    PERCENT=$((EFFECTIVE_READY * 100 / END_REPLICAS))
    printf "\r[%3d%%] Ready: %d/%d replicas, Nodes: %d, Elapsed: %.1fs" \
        "$PERCENT" "$EFFECTIVE_READY" "$END_REPLICAS" "$CURRENT_NODES" "$ELAPSED_SINCE_START"
    
    # Check if complete
    if [[ "$EFFECTIVE_READY" -ge "$END_REPLICAS" ]]; then
        ALL_READY_TIME="$ELAPSED_SINCE_START"
        echo ""
        log "Scale-up complete!"
        break
    fi
    
    # Check timeout
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        echo ""
        warn "Timeout reached after ${TIMEOUT}s. Current: $EFFECTIVE_READY/$END_REPLICAS"
        ALL_READY_TIME="TIMEOUT"
        break
    fi
    
    sleep $POLL_INTERVAL
done

SCALE_END_TIME=$(date +%s.%N)
SCALE_END_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TOTAL_DURATION=$(echo "$SCALE_END_TIME - $SCALE_START_TIME" | bc)

# Calculate statistics
if [[ ${#NODE_READY_TIMES[@]} -gt 0 ]]; then
    # Sort times for percentile calculation
    IFS=$'\n' SORTED_TIMES=($(sort -n <<<"${NODE_READY_TIMES[*]}")); unset IFS
    
    P50_INDEX=$((${#SORTED_TIMES[@]} / 2))
    P90_INDEX=$((${#SORTED_TIMES[@]} * 90 / 100))
    P99_INDEX=$((${#SORTED_TIMES[@]} * 99 / 100))
    
    P50_TIME="${SORTED_TIMES[$P50_INDEX]:-N/A}"
    P90_TIME="${SORTED_TIMES[$P90_INDEX]:-N/A}"
    P99_TIME="${SORTED_TIMES[$P99_INDEX]:-N/A}"
else
    P50_TIME="N/A"
    P90_TIME="N/A"
    P99_TIME="N/A"
fi

# Output results
echo ""
log "========== RESULTS =========="
echo "Provider:          $PROVIDER"
echo "Type:              $TYPE"
echo "Scale:             $START_REPLICAS -> $END_REPLICAS"
echo "----------------------------"
echo "First node ready:  ${FIRST_NODE_TIME:-N/A}s"
echo "All nodes ready:   ${ALL_READY_TIME}s"
echo "Total duration:    ${TOTAL_DURATION}s"
echo "----------------------------"
echo "P50 provisioning:  ${P50_TIME}s"
echo "P90 provisioning:  ${P90_TIME}s"
echo "P99 provisioning:  ${P99_TIME}s"
echo "============================="

# Save results to JSON
RESULT_FILE="${RESULTS_DIR}/${TYPE}-${START_REPLICAS}-to-${END_REPLICAS}-$(date +%Y%m%d-%H%M%S).json"

cat > "$RESULT_FILE" << EOF
{
  "benchmark": "scale-up",
  "provider": "$PROVIDER",
  "type": "$TYPE",
  "scale": {
    "start": $START_REPLICAS,
    "end": $END_REPLICAS
  },
  "timestamps": {
    "start": "$SCALE_START_ISO",
    "end": "$SCALE_END_ISO"
  },
  "results": {
    "first_node_ready_seconds": ${FIRST_NODE_TIME:-null},
    "all_nodes_ready_seconds": ${ALL_READY_TIME:-null},
    "total_duration_seconds": $TOTAL_DURATION,
    "percentiles": {
      "p50_seconds": ${P50_TIME:-null},
      "p90_seconds": ${P90_TIME:-null},
      "p99_seconds": ${P99_TIME:-null}
    }
  },
  "raw_node_ready_times": [$(IFS=,; echo "${NODE_READY_TIMES[*]:-}")]
}
EOF

log "Results saved to: $RESULT_FILE"
