variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "cluster_name" {
  description = "Cluster name. Also used in the kubernetes.io/cluster/<name> tags that cloud-provider-aws relies on."
  type        = string
  default     = "kubeadm-lab"
}

variable "admin_cidr" {
  description = "CIDR allowed to reach SSH, the API server and NodePorts (your public IP as x.x.x.x/32)."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be a valid CIDR and must not be 0.0.0.0/0."
  }
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key installed on the nodes."
  type        = string
  default     = "../.ssh/lab_ed25519.pub"
}

variable "vpc_cidr" {
  description = "VPC CIDR. Must not overlap the pod CIDR (10.244.0.0/16) or service CIDR (10.96.0.0/12)."
  type        = string
  default     = "10.0.0.0/16"
}

variable "instance_type" {
  description = "Instance type for all nodes. kubeadm needs >= 2 vCPU / 2 GiB on the control plane."
  type        = string
  default     = "t3.medium"
}

variable "worker_count" {
  description = "Number of worker nodes (spread across two AZs)."
  type        = number
  default     = 2
}

variable "root_volume_gb" {
  description = "Root volume size per node."
  type        = number
  default     = 30
}
