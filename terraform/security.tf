# One security group for every node. cloud-provider-aws requires that exactly
# ONE security group attached to an instance carries the cluster tag - it is the
# group it edits when a Service of type LoadBalancer needs NodePorts opened.
resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes"
  description = "kubeadm lab nodes"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.cluster_tag, { Name = "${var.cluster_name}-nodes" })

  lifecycle {
    # The cloud controller adds/removes its own rules on this group.
    ignore_changes = [ingress, egress]
  }
}

locals {
  # Node-to-node traffic. Everything a managed control plane would normally hide.
  intra_cluster_rules = {
    apiserver      = { proto = "tcp", from = 6443, to = 6443, desc = "kube-apiserver" }
    etcd           = { proto = "tcp", from = 2379, to = 2380, desc = "etcd client and peer" }
    etcd_metrics   = { proto = "tcp", from = 2381, to = 2381, desc = "etcd metrics" }
    kubelet        = { proto = "tcp", from = 10250, to = 10250, desc = "kubelet API" }
    kcm_scheduler  = { proto = "tcp", from = 10257, to = 10259, desc = "controller-manager and scheduler metrics" }
    nodeports      = { proto = "tcp", from = 30000, to = 32767, desc = "NodePort services" }
    cilium_vxlan   = { proto = "udp", from = 8472, to = 8472, desc = "Cilium VXLAN overlay" }
    cilium_health  = { proto = "tcp", from = 4240, to = 4240, desc = "Cilium health checks" }
    cilium_hubble  = { proto = "tcp", from = 4244, to = 4244, desc = "Hubble server" }
    cilium_metrics = { proto = "tcp", from = 9962, to = 9964, desc = "Cilium agent, operator and envoy metrics" }
    node_exporter  = { proto = "tcp", from = 9100, to = 9100, desc = "node-exporter" }
    icmp           = { proto = "icmp", from = -1, to = -1, desc = "ICMP (Cilium health, path MTU)" }
  }

  # What the operator's workstation may reach.
  admin_rules = {
    ssh       = { from = 22, to = 22, desc = "SSH" }
    apiserver = { from = 6443, to = 6443, desc = "kube-apiserver" }
    nodeports = { from = 30000, to = 32767, desc = "NodePort services" }
  }
}

resource "aws_vpc_security_group_ingress_rule" "intra" {
  for_each = local.intra_cluster_rules

  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = each.value.proto
  from_port                    = each.value.from
  to_port                      = each.value.to
  description                  = each.value.desc
}

resource "aws_vpc_security_group_ingress_rule" "admin" {
  for_each = local.admin_rules

  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = each.value.from
  to_port           = each.value.to
  description       = "admin: ${each.value.desc}"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "all egress"
}
