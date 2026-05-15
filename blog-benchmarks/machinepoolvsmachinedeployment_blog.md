## Introduction

If you're not familiar with Cluster API, let me take you back to first
principles. Kubernetes is a container orchestration engine that was
built for running applications at scale. But as adoption grew,
organizations found themselves managing not one cluster, but hundreds of
Kubernetes clusters across environments: from hyperscalers to on-prem,
from dev sandboxes to production fleets. The native solution to this
problem emerged from the Kubernetes SIGs community: **Cluster API
(CAPI)**.

When defining worker node topology, one of the first decisions is which
CAPI primitive to use: **MachineDeployment** or **MachinePool**. Both
produce working Kubernetes nodes, but they differ in who owns the
machine lifecycle. This post breaks down that difference, walks through
the operational trade-offs, and includes benchmark numbers from a real
Azure scale-up test.

## The Two Models Explained

### MachineDeployment: CAPI-Orchestrated Scaling

MachineDeployment follows a familiar pattern and if you've used
Kubernetes Deployments, you'll feel at home. CAPI creates and manages
every object in the hierarchy:

MachineDeployment\
│\
├──► MachineSet (manages replicas)\
│ │\
│ ├──► Machine-1 ──► InfraMachine-1 ──► VM-1\
│ ├──► Machine-2 ──► InfraMachine-2 ──► VM-2\
│ └──► Machine-N ──► InfraMachine-N ──► VM-N\
│\
└──► KubeadmConfigTemplate\
│\
├──► KubeadmConfig-1 ──► Bootstrap Secret-1\
├──► KubeadmConfig-2 ──► Bootstrap Secret-2\
└──► KubeadmConfig-N ──► Bootstrap Secret-N

CAPI creates a Machine object for every node, each with its own
InfraMachine, KubeadmConfig, and bootstrap secret. Every machine's state
is tracked in the management cluster, giving you full lifecycle
visibility.

### MachinePool: Cloud-Native Delegation

MachinePool delegates scaling to your cloud provider's native scaling
group. The exact implementation is provider-dependent — AWS uses Auto
Scaling Groups, Azure uses Virtual Machine Scale Sets, GCP uses Managed
Instance Groups — but the CAPI abstraction is consistent across all of
them:

MachinePool\
│\
├──► InfraMachinePool (wraps cloud scaling group)\
│ │\
│ └──► Cloud Scaling Group (VMSS / ASG / MIG)\
│ │\
│ ├──► VM-1\
│ ├──► VM-2\
│ └──► VM-N\
│\
└──► KubeadmConfig (shared by all instances)\
│\
└──► Single Bootstrap Secret

Regardless of replica count, CAPI creates one InfraMachinePool and one
shared bootstrap configuration. The cloud provider manages the actual
VMs. This means fewer CAPI objects and the cloud provider handles
fleet-level concerns like AZ distribution, instance replacement, and
scaling orchestration natively.

**Scope note:** Both primitives manage **worker nodes**. Control plane
nodes are managed separately by
[KubeadmControlPlane](https://github.com/kubernetes-sigs/cluster-api/tree/main/controlplane),
which requires unique certificates, etcd membership, and differentiated
init/join behavior - concerns that don't apply to interchangeable worker
compute.

## How They Actually Differ

### Object Creation Flow

**MachineDeployment (CAPI drives, cloud follows):**

1.  User sets spec.replicas: 50

2.  MachineDeployment controller creates/updates a MachineSet

3.  MachineSet controller creates 50 Machine objects

4.  Machine controller creates 50 InfraMachine objects

5.  Provider controller provisions 50 VMs

**MachinePool (cloud drives, CAPI observes):**

1.  User sets spec.replicas: 50

2.  MachinePool controller updates InfraMachinePool desired count

3.  Provider controller tells the cloud scaling group to provision VMs

4.  Cloud provider provisions VMs using its native orchestration

5.  InfraMachinePool reports back status.replicas: 50

6.  MachinePool controller observes and updates CAPI status

### Rolling Update Behavior

**MachineDeployment:** CAPI creates a new MachineSet with the updated
spec, scales it up, cordons and drains each old node, then scales down
the old MachineSet.

spec:\
strategy:\
type: RollingUpdate\
rollingUpdate:\
maxSurge: 1\
maxUnavailable: 0

**MachinePool:** CAPI updates the InfraMachinePool spec. The cloud
provider rolls out the change using its native mechanism: Azure uses
VMSS Rolling Upgrade Policy, AWS uses Instance Refresh, GCP uses MIG
update. These are the same battle-tested update mechanisms that
cloud-native teams use outside of CAPI. CAPZ, for example,
[progressively cordons, drains, and
replaces](https://capz.sigs.k8s.io/self-managed/machinepools) individual
machines in the scale set during rolling upgrades. Check your provider's
docs for specifics on cordon/drain behavior.

### Health Checking and Failure Recovery

**MachineDeployment + MachineHealthCheck:** MHC watches Machine objects
and their corresponding Nodes. When a node is unhealthy, MHC deletes the
Machine. The MachineSet creates a replacement.

**MachinePool:** Health checking can work at two levels. If the provider
supports the [MachinePool
Machines](https://github.com/kubernetes-sigs/cluster-api/blob/main/docs/proposals/20220209-machinepool-machines.md)
feature (by setting status.infrastructureMachineKind),
MachineHealthCheck works with individual pool instances, giving you
CAPI-level observability alongside cloud-native healing. Without it, the
scaling group still detects and replaces failed instances on its own
using its native health probes, which is the same recovery model
cloud-native teams rely on outside of CAPI.

## MachinePool Infrastructure Provider Support

MachinePool requires the provider to implement a scaling group
abstraction. The major hyperscalers support it; environments without
native scaling groups don't:

  --------------------------------------------------------------------------------------------------------------------------------------------------------------
  Provider        MachinePool Support             Details
  --------------- ------------------------------- --------------------------------------------------------------------------------------------------------------
  **Azure         Yes                             [AzureMachinePool](https://capz.sigs.k8s.io/self-managed/machinepools) backed by VMSS. Also
  (CAPZ)**                                        AzureManagedMachinePool for AKS.

  **AWS (CAPA)**  Yes                             [AWSMachinePool](https://cluster-api-aws.sigs.k8s.io/topics/machinepools) backed by ASG. Also
                                                  AWSManagedMachinePool for EKS.

  **GCP (CAPG)**  Partial                         [GCPManagedMachinePool](https://cluster-api-gcp.sigs.k8s.io/managed/index.html?highlight=gcpmanage#overview)
                                                  for GKE exists. Self-managed MachinePool via MIG is [tracked but not actively
                                                  developed](https://github.com/kubernetes-sigs/cluster-api-provider-gcp/issues/297).

  **vSphere       No                              No native scaling group primitive.
  (CAPV)**                                        

  **Bare metal**  No                              No scaling group concept on physical hardware.

  **Docker        Yes                             DockerMachinePool for development/testing.
  (CAPD)**                                        
  --------------------------------------------------------------------------------------------------------------------------------------------------------------

## Benchmark: Scale-Up on Azure

To ground the architectural differences in real numbers, I ran a
scale-up benchmark on Azure using CAPZ. Three configurations were tested
side by side: a MachineDeployment, a MachinePool (VMSS-backed), and an
AKS managed node pool. Each scaled from 5 to 20 worker nodes on
identical Standard_D2s_v3 instances.

### Test Setup

Both clusters share the same configuration:

- **Management cluster:** CAPI v1.10+ with CAPZ, running on a single
  Standard_D2s_v3 control plane node

- **Worker node type:** Standard_D2s_v3, Kubernetes v1.32.0

- **Starting replicas:** 5

- **Target replicas:** 20

- **Measurement:** Wall-clock time from spec.replicas patch to all 15
  new nodes reporting Ready

Here are the key resources used for each cluster. Both use the same VM
size, OS disk configuration, and Kubernetes version - the only
difference is the CAPI primitive and the infrastructure it maps to.

**MachineDeployment** - each replica becomes an individual Azure VM
managed by a MachineSet:

apiVersion: cluster.x-k8s.io/v1beta2\
kind: MachineDeployment\
metadata:\
name: md-bench-azure-workers\
spec:\
clusterName: md-bench-azure\
replicas: 5\
template:\
spec:\
version: v1.32.0\
bootstrap:\
configRef:\
kind: KubeadmConfigTemplate\
name: md-bench-azure-workers\
infrastructureRef:\
kind: AzureMachineTemplate\
name: md-bench-azure-workers\
rollout:\
strategy:\
type: RollingUpdate\
rollingUpdate:\
maxSurge: 1\
maxUnavailable: 0

**MachinePool** - replicas are delegated to an Azure VMSS:

apiVersion: cluster.x-k8s.io/v1beta2\
kind: MachinePool\
metadata:\
name: mp-bench-azure-workers\
spec:\
clusterName: mp-bench-azure\
replicas: 5\
failureDomains:\
- \"1\"\
- \"2\"\
- \"3\"\
template:\
spec:\
version: v1.32.0\
bootstrap:\
configRef:\
kind: KubeadmConfig\
name: mp-bench-azure-workers\
infrastructureRef:\
kind: AzureMachinePool\
name: mp-bench-azure-workers\
\-\--\
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1\
kind: AzureMachinePool\
metadata:\
name: mp-bench-azure-workers\
spec:\
location: eastus\
strategy:\
type: RollingUpdate\
rollingUpdate:\
deletePolicy: Oldest\
maxSurge: 25%\
maxUnavailable: 1\
template:\
vmSize: Standard_D2s_v3\
osDisk:\
osType: Linux\
diskSizeGB: 30\
managedDisk:\
storageAccountType: Premium_LRS

### Scale-Up Results

  -------------------------------------------------------------------
  Metric          MachineDeployment   MachinePool     AKS (managed)
  --------------- ------------------- --------------- ---------------
  **First new     \~2m 19s            \~1m 53s        \~1m 32s
  node ready**                                        

  **All 15 new    \~2m 26s            \~2m 47s        \~2m 37s
  nodes ready**                                       

  **P50           \~2m 19s            \~2m 20s        \~1m 38s
  per-node**                                          

  **P90           \~2m 26s            \~2m 47s        \~1m 43s
  per-node**                                          
  -------------------------------------------------------------------

The headline: **self-managed MachineDeployment and MachinePool land in
the same \~2.5 minute ballpark**. MachinePool got its first node ready
\~25 seconds sooner, but MachineDeployment had all 15 new nodes ready
\~20 seconds faster. The P50 is nearly identical at \~2m 20s.

**AKS (AzureManagedMachinePool)** was also benchmarked with the same 5
to 20 scale on Standard_D2s_v3. Here CAPI still declares desired
replicas via MachinePool, but the node pool is fully managed by AKS;
provisioning is handled by Azure's managed control plane.

The cloud provisioning time dominates regardless of which CAPI primitive
triggers it. Azure needs \~2-3 minutes to spin up a Standard_D2s_v3 VM
either way. The arrival patterns differ based on who orchestrates the
work, but the total time to full scale-out is roughly the same.

## The Road Ahead

MachinePool graduated to **Beta in v1.7** and is enabled by default.
Azure and AWS have mature implementations; GCP supports managed pools
for GKE. Dedicated area ownership for MachinePool was established in the
CAPI project in order to move MachinePool from experimental to stable.

The most interesting development is **in-place updates** ([Alpha in
v1.12](https://kubernetes.io/blog/2026/01/27/cluster-api-v1-12-release/)) -
updating machines without deletion. Today this is supported for
KubeadmControlPlane and MachineDeployment, bringing CAPI-managed
in-place behavior to the primitives that track individual machines.
MachinePool has always had in-place update capabilities when the
underlying cloud scaling group supports it.

## Conclusion

MachineDeployment is the default most teams reach for as it's
well-documented, GA, and works everywhere CAPI does. MachinePool,
despite graduating to Beta in v1.7, remains underexplored. That's a
missed opportunity for teams running on hyperscalers.

As the benchmark showed, the cloud provisioning time dominates either
way. What MachinePool does give you is a thinner CAPI footprint over a
richer cloud-native primitive: fewer objects in your management cluster,
native scaling group features (AZ spreading, instance refresh, surge
upgrades) without reimplementing them in CAPI, and an architecture that
aligns with how cloud providers already think about fleet management.
You trade per-Machine visibility for delegation to a battle-tested cloud
primitive.

If you're on Azure, AWS, or GKE and your worker nodes are
interchangeable compute, MachinePool is worth evaluating. If you're on
vSphere, bare metal, or need per-machine lifecycle control,
MachineDeployment remains the right choice. And with in-place updates
now landing in CAPI v1.12, the gap between the two primitives continues
to narrow, giving platform teams more flexibility regardless of which
model they choose.

## Resources

- [Cluster API Documentation](https://cluster-api.sigs.k8s.io/)

- [MachinePool API
  Proposal](https://github.com/kubernetes-sigs/cluster-api/blob/main/docs/proposals/20190919-machinepool-api.md)

- [MachinePool Machines
  Proposal](https://github.com/kubernetes-sigs/cluster-api/blob/main/docs/proposals/20220209-machinepool-machines.md)

- [In-Place Updates
  Proposal](https://github.com/kubernetes-sigs/cluster-api/blob/main/docs/proposals/20240807-in-place-updates-implementation-notes.md)

- [CAPZ MachinePool
  Docs](https://capz.sigs.k8s.io/self-managed/machinepools)

<!-- -->
