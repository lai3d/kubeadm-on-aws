output "control_plane_public_ip" {
  value = aws_instance.control_plane.public_ip
}

output "control_plane_private_ip" {
  value = aws_instance.control_plane.private_ip
}

output "worker_public_ips" {
  value = aws_instance.worker[*].public_ip
}

output "ssh_control_plane" {
  value = "ssh -i .ssh/lab_ed25519 ubuntu@${aws_instance.control_plane.public_ip}"
}

# Ansible inventory, regenerated on every apply (git-ignored: it holds public IPs).
resource "local_file" "inventory" {
  filename        = "${path.root}/../ansible/inventory.ini"
  file_permission = "0600"
  content = templatefile("${path.root}/inventory.tftpl", {
    control_plane = aws_instance.control_plane
    workers       = aws_instance.worker
    cluster_name  = var.cluster_name
    region        = var.region
    admin_cidr    = var.admin_cidr
    vpc_cidr      = var.vpc_cidr
    ssh_key       = abspath(trimsuffix(var.ssh_public_key_path, ".pub"))
  })
}
