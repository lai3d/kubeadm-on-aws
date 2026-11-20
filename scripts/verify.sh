#!/usr/bin/env bash
# End-to-end checks, run from the workstation. Reads hosts from the generated
# Ansible inventory; talks to the cluster over SSH so no local kubectl is needed.
set -euo pipefail

cd "$(dirname "$0")/.."
INV=ansible/inventory.ini
[[ -f $INV ]] || { echo "no $INV - run 'make apply' first" >&2; exit 1; }

val() { awk -F= -v k="$1" '$1==k {print $2}' "$INV"; }
CP_IP=$(val control_plane_public_ip)
KEY=$(val ansible_ssh_private_key_file)
WORKER_IPS=$(awk '/^\[workers\]/{f=1;next} /^\[/{f=0} f && NF {sub("ansible_host=","",$2); print $2}' "$INV")

k() {
  ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "ubuntu@$CP_IP" "kubectl $(printf '%q ' "$@")"
}

section() { printf '\n=== %s ===\n' "$*"; }

section "Nodes"
k get nodes -o wide

section "Cloud provider integration (providerID, zone labels)"
k get nodes -o custom-columns='NAME:.metadata.name,PROVIDER_ID:.spec.providerID,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type'

section "Pods not Running/Completed (expect none)"
k get pods -A --field-selector 'status.phase!=Running,status.phase!=Succeeded' 2>&1 || true

section "kube-system"
k get pods -n kube-system -o wide

section "Cilium (kube-proxy replacement, routing mode)"
k -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null \
  | grep -E 'KubeProxyReplacement|Routing|IPAM|Cluster health|Cilium:' || true
echo "kube-proxy daemonsets: $(k -n kube-system get ds -o name | grep -c kube-proxy || true) (expect 0)"

section "Sample app via NodePort 30080 on every worker"
for ip in $WORKER_IPS; do
  for _ in 1 2 3 4; do
    printf '%s -> %s\n' "worker" "$(curl -s --max-time 5 "http://$ip:30080/hostname")"
  done
done | sort | uniq -c

if k get gateway -n gateway public >/dev/null 2>&1; then
  section "Sample app via Gateway API -> AWS NLB"
  k get gateway,httproute -A
  NLB=$(k -n gateway get gateway public -o jsonpath='{.status.addresses[0].value}')
  echo "waiting for NLB targets to become healthy..."
  for i in $(seq 1 60); do
    if curl -sf --max-time 5 "http://$NLB/hostname" >/dev/null; then break; fi
    sleep 10
  done
  for _ in 1 2 3 4 5 6; do
    printf 'nlb -> %s\n' "$(curl -s --max-time 5 "http://$NLB/hostname")"
  done | sort | uniq -c
fi

if k get sc gp3 >/dev/null 2>&1; then
  section "EBS CSI (StorageClass, bound volumes)"
  k get sc
  k get pvc -A
  k get pv
fi

if k get ns monitoring >/dev/null 2>&1; then
  section "Monitoring"
  k get pods -n monitoring
  GRAFANA_HOST=$(k -n monitoring get httproute grafana -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null || true)
  if [[ -n ${NLB:-} && -n $GRAFANA_HOST ]]; then
    echo "Grafana via NLB (Host: $GRAFANA_HOST): HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: $GRAFANA_HOST" "http://$NLB/api/health")"
  fi
  echo "Prometheus scrape targets by health:"
  k -n monitoring exec sts/prometheus-kube-prometheus-stack-prometheus -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/targets?state=active' \
    | jq -r '.data.activeTargets[] | "\(.health) \(.labels.job)"' | sort | uniq -c
fi
