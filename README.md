# kubeadm-on-aws

A self-managed Kubernetes cluster on plain EC2 instances, built with `kubeadm`
— no EKS. Terraform creates the infrastructure, Ansible turns three Ubuntu
machines into a cluster, and everything a managed control plane normally does
for you is done explicitly here: the container runtime, the control plane
bootstrap, pod networking, the AWS cloud integration, storage, ingress,
monitoring and a version upgrade.

**This is a lab, not a production design.** It exists to work through the
parts of Kubernetes that a managed service hides. The
[limitations](#what-this-is-not) are listed at the end.

## What gets built

```
                      workstation (terraform, ansible, curl)
                          │ SSH 22 / API 6443 / NodePort          │ HTTP 80
                          │ (admin IP only)                       │ (admin IP only)
                          ▼                                       ▼
┌─ VPC 10.0.0.0/16 ───────────────────────────────────────── AWS NLB ──────────┐
│                                                     (created by the cloud    │
│  public subnet AZ-a                public subnet AZ-b controller manager)    │
│ ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐     │         │
│ │ control plane    │ │ worker 1         │ │ worker 2         │◄────┘         │
│ │ etcd, apiserver, │ │ kubelet          │ │ kubelet          │  NodePort     │
│ │ scheduler, KCM   │ │ containerd       │ │ containerd       │               │
│ │ AWS cloud ctrl   │ │ Cilium + Envoy   │ │ Cilium + Envoy   │               │
│ │ Cilium           │ │ EBS CSI          │ │ EBS CSI          │               │
│ └────────┬─────────┘ └────────┬─────────┘ └────────┬─────────┘               │
│          └────── Cilium VXLAN overlay, pods 10.244.0.0/16 ──┘                │
│                                                       EBS gp3 volumes (CSI)  │
└──────────────────────────────────────────────────────────────────────────────┘
```

| Layer | Choice |
|-------|--------|
| Infrastructure | Terraform: VPC, 2 public subnets, 1 security group, 2 IAM instance profiles, 3 × `t3.medium` (Ubuntu 24.04) |
| Runtime | containerd 2.x, systemd cgroup driver |
| Bootstrap | kubeadm (`v1beta4` config), 1 control plane + 2 workers, Kubernetes 1.36 → upgraded to 1.37 |
| Pod network | Cilium 1.20, VXLAN overlay, **kube-proxy replaced by eBPF** |
| Cloud integration | [cloud-provider-aws](https://github.com/kubernetes/cloud-provider-aws) (external cloud controller manager) |
| Load balancing | Gateway API (Cilium's built-in controller) → `Service type=LoadBalancer` → AWS NLB |
| Storage | AWS EBS CSI driver, default `gp3` StorageClass |
| Monitoring | kube-prometheus-stack (Prometheus on an EBS volume, Alertmanager, Grafana) |
| Sample app | 2-replica echo server, exposed on a NodePort and through the Gateway |

Ingress goes through the Gateway API rather than ingress-nginx: the
ingress-nginx project was retired and its repository archived in 2026.

## Running it

Requirements: Terraform ≥ 1.9, Ansible (tested with ansible-core 2.22), `jq`,
`curl`, GNU make, an SSH client, and AWS credentials in your environment. Nothing is installed on
the workstation for Kubernetes itself — `kubectl` and `helm` run on the
control plane node.

```bash
export AWS_PROFILE=<your profile>           # credentials never enter this repo
python3 -m venv .venv && .venv/bin/pip install ansible-core   # if Ansible is not installed

make init        # generates a throwaway SSH key in .ssh/, terraform init
make apply       # VPC, security group, IAM, 3 instances      (~1 min)
make cluster     # containerd, kubeadm init/join, Cilium, cloud controller, sample app (~6 min)
make verify      # checks from the workstation
make extras      # EBS CSI, NLB-backed Gateway, Prometheus/Grafana   (~3 min)
make verify
make upgrade     # kubeadm upgrade 1.36 → 1.37, node by node   (~6 min)
make destroy     # deletes the NLB and EBS volumes first, then terraform destroy
```

`make apply` detects your public IP and restricts SSH, the API server, the
NodePort range and the NLB to it (`ADMIN_CIDR=x.x.x.x/32 make apply` to override).

**Cost:** three `t3.medium` instances plus an NLB are roughly US$0.17–0.20 per
hour in `ap-southeast-1`. Run `make destroy` when you are done. Always use
`make destroy` rather than `terraform destroy` — see gotcha 11.

Versions are pinned in [`ansible/group_vars/all.yml`](ansible/group_vars/all.yml).

### Layout

```
terraform/            network.tf  security.tf  iam.tf  compute.tf  (writes ansible/inventory.ini)
ansible/site.yml      MVP: 01-nodes → 02-control-plane → 03-cni → 04-cloud-provider → 05-workers → 06-demo-app
ansible/extras.yml    10-ebs-csi → 11-gateway → 12-monitoring
ansible/upgrade.yml   kubeadm minor upgrade
ansible/teardown.yml  removes cloud resources that controllers created
ansible/templates/    kubeadm configs and Helm values, with the reasoning in comments
scripts/verify.sh     end-to-end checks
docs/upgrade.md       record of a real upgrade run
```

## What was verified

From a run on 2026-11-20 (`make verify`, output trimmed). After the fixes
described below, the whole sequence — `apply`, `cluster`, `extras`, `verify`,
`upgrade`, `verify`, `destroy` — was repeated from scratch (nothing left over from the first run)
in one pass with no failed task.

```
NAME                                            STATUS   ROLES           VERSION   INTERNAL-IP   KERNEL-VERSION   CONTAINER-RUNTIME
ip-10-0-1-254.ap-southeast-1.compute.internal   Ready    worker          v1.36.6   10.0.1.254    7.0.0-1017-aws   containerd://2.4.2
ip-10-0-1-55.ap-southeast-1.compute.internal    Ready    control-plane   v1.36.6   10.0.1.55     7.0.0-1017-aws   containerd://2.4.2
ip-10-0-2-193.ap-southeast-1.compute.internal   Ready    worker          v1.36.6   10.0.2.193    7.0.0-1017-aws   containerd://2.4.2

=== Cloud provider integration (providerID, zone labels) ===
NAME                                            PROVIDER_ID                        ZONE              TYPE
ip-10-0-1-254.ap-southeast-1.compute.internal   aws:///ap-southeast-1a/i-…         ap-southeast-1a   t3.medium
ip-10-0-1-55.ap-southeast-1.compute.internal    aws:///ap-southeast-1a/i-…         ap-southeast-1a   t3.medium
ip-10-0-2-193.ap-southeast-1.compute.internal   aws:///ap-southeast-1b/i-…         ap-southeast-1b   t3.medium

=== Cilium (kube-proxy replacement, routing mode) ===
KubeProxyReplacement:    True   [ens5 10.0.1.55 (Direct Routing)]
Cilium:                  Ok   1.20.5
Routing:                 Network: Tunnel [vxlan]   Host: Legacy
Cluster health:          3/3 reachable
kube-proxy daemonsets: 0 (expect 0)

=== Sample app via NodePort 30080 on every worker ===
   5 worker -> echo-57f7f5994-5m7bt
   3 worker -> echo-57f7f5994-6gbp7

=== Sample app via Gateway API -> AWS NLB ===
gateway/public   cilium   a63…elb.ap-southeast-1.amazonaws.com   PROGRAMMED=True
   3 nlb -> echo-57f7f5994-5m7bt
   3 nlb -> echo-57f7f5994-6gbp7

=== EBS CSI ===
gp3 (default)   ebs.csi.aws.com   Delete   WaitForFirstConsumer
monitoring   prometheus-…-db-prometheus-…-0   Bound   pvc-5b0b1584-…   10Gi   RWO   gp3

=== Monitoring ===
Grafana via NLB (Host: grafana.kubeadm.lab): HTTP 200
Prometheus scrape targets: 25 up, 0 down
  (apiserver, etcd, controller-manager, scheduler, coredns, kubelet ×9, node-exporter ×3, …)
```

- All pods `Running`; the two echo replicas sit on different nodes, so getting
  answers from both through one node's NodePort shows cross-node pod traffic
  over the overlay.
- `kubeadm upgrade` from v1.36.6 to v1.37.2 completed on all three nodes, with
  349 of 349 once-per-second requests through the NLB answered during the run.
  Details and caveats in [docs/upgrade.md](docs/upgrade.md).
- `make destroy` left no load balancers, target groups, volumes, instances,
  security groups, IAM roles or VPC behind (checked with the AWS CLI).

## EC2 gotchas, and how each was handled

Things that cost time, or would have. Items marked **(hit)** actually broke
during the build; the rest were designed around up front.

### 1. Node names must be the EC2 private DNS name

cloud-provider-aws maps a `Node` object to an EC2 instance by name and expects
`ip-10-0-1-55.ap-southeast-1.compute.internal`. Ubuntu sets only the short
hostname `ip-10-0-1-55`. Before `kubeadm` runs, the playbook reads
`local-hostname` from IMDS and sets it as the system hostname
([`01-nodes.yml`](ansible/playbooks/01-nodes.yml)); the VPC has DNS hostnames enabled.

### 2. `--cloud-provider=external` leaves nodes tainted until a controller you install removes it

Every kubelet is started with `cloud-provider: external`
([`kubeadm-init.yaml.j2`](ansible/templates/kubeadm-init.yaml.j2)). The node
then registers with the taint `node.cloudprovider.kubernetes.io/uninitialized`
and nothing ordinary — CoreDNS included — schedules until the AWS cloud
controller manager has filled in `providerID`, addresses and zone labels.
So the order matters: CNI → cloud controller → workers.

### 3. The cloud controller must run on the host network **(hit)**

The Helm chart runs the controller as a normal pod by default. On the pod
network it crashed in a loop:

```
Cloud provider could not be initialized: could not init cloud provider "aws":
operation error ec2imds: GetRegion, request canceled, context deadline exceeded
```

The component that makes nodes usable should not depend on pod networking or
cluster DNS. Fixed with `hostNetworking: true`
([`ccm-values.yaml.j2`](ansible/templates/ccm-values.yaml.j2)). The underlying
reason it could not reach IMDS is the next item.

### 4. IMDSv2 hop limit: 2 is not enough behind Cilium **(hit)**

Pods that use the instance role (the EBS CSI controller) need IMDS. The usual
advice is "set the hop limit to 2 for containers". With it set to 2, a test
pod's TCP handshake to `169.254.169.254` completed but the token `PUT` never
got an answer. Changing only the hop limit:

| `http_put_response_hop_limit` | `PUT /latest/api/token` from a pod |
|---|---|
| 2 | timeout |
| 3 | HTTP 200 |

Cilium's default ("legacy") host routing sends a packet through two routed
hops between the pod and the NIC, so the response's TTL runs out one hop
early. Set to 3 in [`compute.tf`](terraform/compute.tf).

### 5. Cilium's default pod CIDR swallows the VPC

Cilium's `cluster-pool` IPAM defaults to `10.0.0.0/8`. The VPC is
`10.0.0.0/16`, so pod addresses would collide with node addresses. The pool is
set explicitly to `10.244.0.0/16`, matching kubeadm's `podSubnet`
([`cilium-values.yaml.j2`](ansible/templates/cilium-values.yaml.j2)).

### 6. Without kube-proxy, Cilium needs to be told where the API server is

kubeadm is run with `skipPhases: [addon/kube-proxy]`. That removes the thing
that makes the `kubernetes` Service IP work, which is how Cilium would normally
find the API server — so `k8sServiceHost` / `k8sServicePort` point at the
control plane's address directly.

### 7. Security group ports are yours to know

Node-to-node rules, all scoped to the node security group itself
([`security.tf`](terraform/security.tf)):

| Port | Purpose |
|------|---------|
| 6443/tcp | kube-apiserver |
| 2379–2380/tcp | etcd client and peer |
| 10250/tcp | kubelet API (logs, exec, metrics) |
| 30000–32767/tcp | NodePort range (also what the NLB targets) |
| 8472/udp | Cilium VXLAN |
| 4240/tcp, ICMP | Cilium node-to-node health checks |
| 4244/tcp | Hubble |
| 2381, 10257–10259, 9100, 9962–9964/tcp | metrics: etcd, controller-manager, scheduler, node-exporter, Cilium |

From the admin IP only: 22, 6443 and the NodePort range.

### 8. Source/destination check

EC2 drops packets whose source or destination address is not the instance's
own. That breaks **natively routed** pod networking, where pod IPs appear on
the VPC network. In VXLAN mode pod packets are encapsulated between node IPs
and the check never sees a pod address, so this lab does not strictly depend
on it. It is disabled on all nodes anyway (`source_dest_check = false`) so that
switching Cilium to native routing is not blocked by it — that switch would
also need VPC routes for the pod CIDRs.

### 9. MetalLB layer 2 does not work in a VPC

L2 mode announces a service IP with gratuitous ARP. A VPC is not a real
layer-2 network: ARP is answered by the VPC itself and only for addresses AWS
has assigned to a network interface. So `Service type=LoadBalancer` is
implemented the AWS way instead — the cloud controller manager creates an NLB
that targets the nodes on the Service's NodePort. That requires:

- the tag `kubernetes.io/cluster/<name>` on the instances, the subnets and
  **exactly one** security group per instance (the controller edits that group
  to admit the NLB's traffic and refuses to guess between two);
- `kubernetes.io/role/elb = 1` on the public subnets;
- IAM permissions for the control plane's instance role ([`iam.tf`](terraform/iam.tf));
- `--configure-cloud-routes=false`, because pod routing is Cilium's job and the
  controller would otherwise try to manage VPC route tables.

The Gateway passes the NLB annotations to its generated Service through
`spec.infrastructure.annotations` ([`gateway.yaml.j2`](ansible/templates/gateway.yaml.j2)),
including `load-balancer-source-ranges`. An NLB has no security group of its
own here and preserves the client address, so that restriction ends up as
rules the controller writes into the node security group:

```
tcp   30186   <admin-ip>/32   kubernetes.io/rule/nlb/client=…    # clients, via the NodePort
tcp   30186   10.0.1.0/24     kubernetes.io/rule/nlb/health=…    # NLB health checks, per subnet
tcp   30186   10.0.2.0/24     kubernetes.io/rule/nlb/health=…
icmp  3/4     <admin-ip>/32   kubernetes.io/rule/nlb/mtu         # path MTU discovery
```

### 10. EBS volumes are zonal

The StorageClass uses `WaitForFirstConsumer`, so a volume is created in the
availability zone of the node the pod was scheduled to, not in a random one.
The flip side showed up in the upgrade: with one worker per zone, a pod with a
volume cannot move to the other worker when its node is drained. Prometheus
waited and came back on the same node once it was uncordoned.

### 11. Controllers create AWS resources that Terraform does not know about

The NLB and the EBS volumes are created from inside the cluster, so they are
not in Terraform's state. AWS will not delete a subnet while the NLB's network
interfaces are in it, and the volumes would simply stay behind, still billed.
[`teardown.yml`](ansible/teardown.yml) deletes Gateways, LoadBalancer Services
and PersistentVolumeClaims first and waits for the controllers to clean up;
`make destroy` runs it before Terraform.

### 12. kubeadm hides control plane metrics on localhost

kube-controller-manager, kube-scheduler and etcd's metrics endpoint bind to
`127.0.0.1` by default, so Prometheus shows them as down. The kubeadm config
sets `bind-address: 0.0.0.0` for the first two and
`listen-metrics-urls: http://0.0.0.0:2381` for etcd, and the security group
limits those ports to cluster nodes. kube-proxy monitoring is disabled since
there is no kube-proxy.

### 13. Smaller ones

- **API server certificate:** the control plane's public IP is added to
  `certSANs`, otherwise `kubectl` from outside fails TLS verification. The
  public IP changes if the instance is stopped and started; an Elastic IP or a
  load balancer in front would fix that.
- **Cloud controller version** follows the Kubernetes minor version, so it is
  part of the upgrade playbook.
- **`crictl` is not installed** with the kubeadm packages any more **(hit)** —
  the etcd snapshot step in the upgrade uses `kubectl exec` instead.
- **No IRSA / Pod Identity:** those need an OIDC issuer for the cluster. The
  lab uses instance profiles, which means any pod on a node can use that
  node's permissions.

## What this is not

- **Not highly available.** One control plane node, one etcd member. The API
  is unavailable while that node upgrades or reboots, and losing its disk
  loses the cluster. `controlPlaneEndpoint` is set so more control plane nodes
  could be joined later, but that also needs a load balancer in front of them.
- **Not private.** Nodes sit in public subnets with public IPs to avoid paying
  for a NAT gateway; only the security group keeps them closed. A real
  deployment would use private subnets and reach the nodes through SSM or a
  bastion.
- **No etcd backup schedule.** One snapshot is taken before the upgrade and
  stays on the same disk as etcd.
- **Coarse credentials.** Instance-profile permissions are shared by every pod
  on a node; the control plane role uses `Resource: "*"`.
- **No TLS on the Gateway**, no NetworkPolicies, no Pod Security admission
  configuration, no audit logging, no encryption of Secrets at rest.
- **Not autoscaled.** Three fixed instances; no cluster autoscaler or
  Karpenter, no node replacement if an instance dies.
- **Single run of each scenario.** The results above come from a lab run, not
  from sustained operation.
