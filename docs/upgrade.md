# kubeadm upgrade run: v1.36.6 → v1.37.2

A record of an actual run of `make upgrade` (`ansible/upgrade.yml`) against this
lab on 2026-11-20. Output is trimmed; nothing is edited apart from `...` cuts.

## Procedure

kubeadm upgrades one minor version at a time, control plane first.

| # | Where | Step |
|---|-------|------|
| 1 | control plane | Snapshot etcd (`etcdctl snapshot save`) |
| 2 | control plane | Point apt at the `v1.37` package repo, upgrade the **kubeadm** package only |
| 3 | control plane | `kubeadm upgrade plan v1.37.2` |
| 4 | control plane | `kubeadm upgrade apply v1.37.2` — etcd, apiserver, controller-manager, scheduler static pods, CoreDNS, certificates |
| 5 | control plane | `kubectl drain`, upgrade **kubelet** + kubectl, restart kubelet, `kubectl uncordon` |
| 6 | each worker, one at a time | upgrade kubeadm → `kubeadm upgrade node` → drain → upgrade kubelet → restart → uncordon → wait for Ready and for the sample app to be fully available |
| 7 | cluster | Move `aws-cloud-controller-manager` to the matching minor (`v1.36.1` → `v1.37.0`) |

On a managed service steps 1–5 and 7 are one API call. Here they are the operator's.

## Before

```
NAME                                            STATUS   ROLES           VERSION   INTERNAL-IP   OS-IMAGE             KERNEL-VERSION   CONTAINER-RUNTIME
ip-10-0-1-254.ap-southeast-1.compute.internal   Ready    worker          v1.36.6   10.0.1.254    Ubuntu 24.04.5 LTS   7.0.0-1017-aws   containerd://2.4.2
ip-10-0-1-55.ap-southeast-1.compute.internal    Ready    control-plane   v1.36.6   10.0.1.55     Ubuntu 24.04.5 LTS   7.0.0-1017-aws   containerd://2.4.2
ip-10-0-2-193.ap-southeast-1.compute.internal   Ready    worker          v1.36.6   10.0.2.193    Ubuntu 24.04.5 LTS   7.0.0-1017-aws   containerd://2.4.2
Client Version: v1.36.6
Server Version: v1.36.6
```

## `kubeadm upgrade plan`

```
[upgrade/versions] Cluster version: 1.36.6
[upgrade/versions] kubeadm version: v1.37.2
[upgrade/versions] Target version: v1.37.2

Components that must be upgraded manually after you have upgraded the control plane with 'kubeadm upgrade apply':
COMPONENT   NODE                                            CURRENT   TARGET
kubelet     ip-10-0-1-254.ap-southeast-1.compute.internal   v1.36.6   v1.37.2
kubelet     ip-10-0-1-55.ap-southeast-1.compute.internal    v1.36.6   v1.37.2
kubelet     ip-10-0-2-193.ap-southeast-1.compute.internal   v1.36.6   v1.37.2

COMPONENT                 NODE                                           CURRENT   TARGET
kube-apiserver            ip-10-0-1-55.ap-southeast-1.compute.internal   v1.36.6   v1.37.2
kube-controller-manager   ip-10-0-1-55.ap-southeast-1.compute.internal   v1.36.6   v1.37.2
kube-scheduler            ip-10-0-1-55.ap-southeast-1.compute.internal   v1.36.6   v1.37.2
kube-proxy                                                               1.36.6    v1.37.2
CoreDNS                                                                  v1.14.2   v1.14.6
etcd                      ip-10-0-1-55.ap-southeast-1.compute.internal   3.6.8-0   3.7.0-0

API GROUP                 CURRENT VERSION   PREFERRED VERSION   MANUAL UPGRADE REQUIRED
kubeproxy.config.k8s.io   -                 v1alpha1            no
kubelet.config.k8s.io     v1beta1           v1beta1             no
```

The plan lists kube-proxy although this cluster has none (Cilium replaces it).
The apply step below detects that and skips it.

## `kubeadm upgrade apply v1.37.2`

```
[upgrade/preflight] You have chosen to upgrade the cluster version to "v1.37.2"
[upgrade/control-plane] Upgrading your static Pod-hosted control plane to version "v1.37.2" (timeout: 5m0s)...
[upgrade/staticpods] Preparing for "etcd" upgrade
[upgrade/staticpods] Renewing etcd-server certificate
...
[upgrade/staticpods] Component "etcd" upgraded successfully!
[upgrade/staticpods] Preparing for "kube-apiserver" upgrade
[upgrade/staticpods] Renewing apiserver certificate
...
[upgrade/staticpods] Component "kube-apiserver" upgraded successfully!
[upgrade/staticpods] Component "kube-controller-manager" upgraded successfully!
[upgrade/staticpods] Component "kube-scheduler" upgraded successfully!
[upgrade/control-plane] The control plane instance for this node was successfully upgraded!
[upgrade/kubelet-config] The kubelet configuration for this node was successfully upgraded!
[addons] Applied essential addon: CoreDNS
[upgrade/addon] Skipping the addon/kube-proxy phase. The addon is disabled.

[upgrade] SUCCESS! A control plane node of your cluster was upgraded to "v1.37.2".
```

Two things worth knowing that the output shows:

- `kubeadm upgrade apply` **renews the control plane certificates** as a side
  effect. A cluster that is upgraded at least once a year never hits the
  one-year certificate expiry; one that is not, does.
- The old static pod manifests are kept under `/etc/kubernetes/tmp/kubeadm-backup-manifests-<timestamp>/`,
  which together with the etcd snapshot is the rollback path.

## Draining a worker

```
node/ip-10-0-2-193.ap-southeast-1.compute.internal cordoned
evicting pod kube-system/coredns-559f6c778d-2g8c5
evicting pod monitoring/prometheus-kube-prometheus-stack-prometheus-0
evicting pod demo/echo-57f7f5994-5m7bt
evicting pod monitoring/alertmanager-kube-prometheus-stack-alertmanager-0
evicting pod kube-system/ebs-csi-controller-7dfb9cdcd6-rgfp2
...
node/ip-10-0-2-193.ap-southeast-1.compute.internal drained
```

## After

```
NAME                                            STATUS   ROLES           VERSION   INTERNAL-IP   OS-IMAGE             KERNEL-VERSION   CONTAINER-RUNTIME
ip-10-0-1-254.ap-southeast-1.compute.internal   Ready    worker          v1.37.2   10.0.1.254    Ubuntu 24.04.5 LTS   7.0.0-1017-aws   containerd://2.4.2
ip-10-0-1-55.ap-southeast-1.compute.internal    Ready    control-plane   v1.37.2   10.0.1.55     Ubuntu 24.04.5 LTS   7.0.0-1017-aws   containerd://2.4.2
ip-10-0-2-193.ap-southeast-1.compute.internal   Ready    worker          v1.37.2   10.0.2.193    Ubuntu 24.04.5 LTS   7.0.0-1017-aws   containerd://2.4.2
Client Version: v1.37.2
Server Version: v1.37.2
```

All pods `Running`, all 25 Prometheus scrape targets `up` again a few minutes later.

## Availability during the upgrade

While the playbook ran, a loop on the workstation requested the sample app
through the NLB once per second (3 s timeout):

```
probes: 349    HTTP 200: 349    failures: 0
```

What that does and does not show:

- The **data plane** stayed up: the app has two replicas spread over both
  workers, workers were drained one at a time, and the playbook waits for the
  Deployment to be fully available before touching the next node.
- The **control plane** did *not* stay up. With a single control plane node,
  the API server restarts during `kubeadm upgrade apply` (it shows 1 restart
  afterwards), so `kubectl` and controllers are briefly unavailable. Running
  workloads are unaffected, but nothing can be scheduled or reconciled in that
  window. Avoiding that needs three control plane nodes behind a load balancer.
- Prometheus was down while its node was drained: its EBS volume lives in one
  availability zone and the only other worker is in a different one, so it
  could not be rescheduled. It came back on the same node after the uncordon
  (in a second run it was still initialising 36 seconds after the playbook
  finished, which is why `scripts/verify.sh` waits for it).

## What went wrong on the way

The first attempt failed at step 1: the etcd snapshot task used `crictl`, which
is no longer pulled in as a dependency of the kubeadm packages, so the binary
was not on the node. The task now runs `etcdctl` through `kubectl exec` in the
etcd static pod instead. Nothing had been changed on the cluster at that point.

The procedure was then run a second time on a freshly built cluster and
completed in one pass.
