# MachinePool vs MachineDeployment Benchmark Suite

This directory contains test manifests and benchmark scripts for comparing MachinePool and MachineDeployment performance characteristics across Azure, AWS, and GCP.

## Directory Structure

```
blog-benchmarks/
├── README.md                     # This file
├── azure/
│   ├── machinepool/              # Azure VMSS-backed MachinePool manifests
│   └── machinedeployment/        # Azure VM-backed MachineDeployment manifests
├── aws/
│   ├── machinepool/              # AWS ASG-backed MachinePool manifests
│   └── machinedeployment/        # AWS EC2-backed MachineDeployment manifests
├── gcp/
│   ├── machinepool/              # GCP MIG-backed MachinePool manifests
│   └── machinedeployment/        # GCP VM-backed MachineDeployment manifests
└── scripts/
    ├── benchmark-scale-up.sh     # Scale-up latency benchmark
    ├── benchmark-etcd.sh         # etcd pressure benchmark
    ├── benchmark-api-calls.sh    # API call volume benchmark
    └── benchmark-failure.sh      # Failure injection benchmark
```

## Prerequisites

1. **CAPI Management Cluster**: A running management cluster with clusterctl initialized
2. **Provider Credentials**: Configured for each cloud you want to test
3. **kubectl**: Access to both management and workload clusters
4. **jq**: For JSON parsing in benchmark scripts

### Provider-specific setup:

**Azure (CAPZ)**:
```bash
clusterctl init --infrastructure azure
export AZURE_SUBSCRIPTION_ID="<your-subscription>"
export AZURE_TENANT_ID="<your-tenant>"
export AZURE_CLIENT_ID="<your-client>"
export AZURE_CLIENT_SECRET="<your-secret>"
```

**AWS (CAPA)**:
```bash
clusterctl init --infrastructure aws
export AWS_REGION="ap-south-1"
export AWS_ACCESS_KEY_ID="<your-key>"
export AWS_SECRET_ACCESS_KEY="<your-secret>"
export AWS_SSH_KEY_NAME="your-key-name"
```
AWS clusters use `cloud-provider: external`. After the workload cluster control plane is ready, install the AWS Cloud Controller Manager:
```bash
./scripts/install-aws-ccm.sh md-bench-aws md-bench-aws   # or mp-bench-aws for machinepool
```

**GCP (CAPG)**:
```bash
clusterctl init --infrastructure gcp
export GCP_PROJECT="<your-project>"
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/credentials.json"
```

## Benchmark Tests

### Test 1: Scale-Up Latency

Measures time from replica count change to all nodes reporting Ready.

```bash
./scripts/benchmark-scale-up.sh azure machinepool 5 20
./scripts/benchmark-scale-up.sh azure machinedeployment 5 20
```

**Metrics captured**:

- Time to first node Ready
- Time to all nodes Ready
- P50/P90/P99 node provisioning times

### Test 2: etcd Pressure

Compares object count and etcd storage impact.

```bash
./scripts/benchmark-etcd.sh azure 20
```

**Metrics captured**:
- Machine object count
- Total Kubernetes objects created
- etcd database size
- Watch event volume

### Test 3: API Rate Limit Behavior

Measures cloud API call volume during rapid scaling.

```bash
./scripts/benchmark-api-calls.sh azure
```

**Metrics captured**:
- Total API calls to cloud provider
- Throttling events
- API call rate (calls/second)

### Test 4: Failure Injection

Measures recovery behavior when nodes are terminated mid-scale.

```bash
./scripts/benchmark-failure.sh azure machinepool
```

**Metrics captured**:
- Time to detect failure
- Time to recover (replacement node Ready)
- Final state consistency

## Running the Full Benchmark Suite

```bash
# Set your cloud provider
export PROVIDER="azure"  # or "aws" or "gcp"

# Run all benchmarks
./scripts/run-all-benchmarks.sh $PROVIDER

# Results will be written to ./results/$PROVIDER/
```

## Interpreting Results

Results are output in JSON format for easy graphing. Each benchmark produces:

- `raw-data.json`: Individual measurements
- `summary.json`: Aggregated statistics
- `comparison.md`: Markdown table comparing MachinePool vs MachineDeployment

## Cleanup

```bash
# Delete all test clusters
kubectl delete cluster -l benchmark=machinepool-vs-md --all-namespaces
```

## Cost Warning

These benchmarks create real cloud resources. Estimated costs for full suite:
- **Azure**: ~$10-20 for 20-node test
- **AWS**: ~$10-20 for 20-node test
- **GCP**: ~$10-20 for 20-node test

Always clean up resources after testing!
