data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_key_pair" "lab" {
  key_name   = var.cluster_name
  public_key = file(var.ssh_public_key_path)
}

locals {
  node_defaults = {
    ami           = nonsensitive(data.aws_ssm_parameter.ubuntu.value)
    instance_type = var.instance_type
  }
}

resource "aws_instance" "control_plane" {
  ami                    = local.node_defaults.ami
  instance_type          = local.node_defaults.instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.nodes.id]
  key_name               = aws_key_pair.lab.key_name
  iam_instance_profile   = aws_iam_instance_profile.control_plane.name

  # EC2 drops packets whose source/destination is not the instance's own IP.
  # Mandatory for native-routed pod networking; harmless (but kept off) with VXLAN.
  source_dest_check = false

  metadata_options {
    http_tokens = "required"
    # Pods on the pod network need IMDS for instance-role credentials (EBS CSI
    # controller). The default hop limit of 1 only reaches the host, and the
    # usual "2 for containers" is NOT enough here: with Cilium's legacy host
    # routing a packet is routed twice between pod and NIC (measured: 2 times
    # out on the IMDSv2 token PUT, 3 returns HTTP 200).
    http_put_response_hop_limit = 3
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  tags = merge(local.cluster_tag, { Name = "${var.cluster_name}-cp1", Role = "control-plane" })

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_instance" "worker" {
  count = var.worker_count

  ami                    = local.node_defaults.ami
  instance_type          = local.node_defaults.instance_type
  subnet_id              = aws_subnet.public[count.index % length(aws_subnet.public)].id
  vpc_security_group_ids = [aws_security_group.nodes.id]
  key_name               = aws_key_pair.lab.key_name
  iam_instance_profile   = aws_iam_instance_profile.worker.name
  source_dest_check      = false

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 3
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  tags = merge(local.cluster_tag, { Name = "${var.cluster_name}-worker${count.index + 1}", Role = "worker" })

  lifecycle {
    ignore_changes = [ami]
  }
}
