# Instance profiles stand in for IRSA / Pod Identity, which need an OIDC issuer
# this lab does not set up. Anything on the node can use these permissions -
# acceptable for a lab, not for production.

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# --- Control plane: runs the AWS cloud controller manager ---------------------

resource "aws_iam_role" "control_plane" {
  name               = "${var.cluster_name}-control-plane"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Policy from the cloud-provider-aws prerequisites (control plane node).
data "aws_iam_policy_document" "control_plane" {
  statement {
    sid = "CloudControllerManager"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeTags",
      "ec2:DescribeInstances",
      "ec2:DescribeRegions",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeVolumes",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInstanceTopology",
      "ec2:DescribeVpcs",
      "ec2:CreateSecurityGroup",
      "ec2:CreateTags",
      "ec2:ModifyInstanceAttribute",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:DeleteSecurityGroup",
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:AttachLoadBalancerToSubnets",
      "elasticloadbalancing:ApplySecurityGroupsToLoadBalancer",
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:CreateLoadBalancerPolicy",
      "elasticloadbalancing:CreateLoadBalancerListeners",
      "elasticloadbalancing:ConfigureHealthCheck",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:DeleteLoadBalancerListeners",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DetachLoadBalancerFromSubnets",
      "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
      "elasticloadbalancing:SetLoadBalancerPoliciesForBackendServer",
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeLoadBalancerPolicies",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTags",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:SetLoadBalancerPoliciesOfListener",
      "elasticloadbalancing:SetSecurityGroups",
      "iam:CreateServiceLinkedRole",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "control_plane" {
  name   = "cloud-controller-manager"
  role   = aws_iam_role.control_plane.id
  policy = data.aws_iam_policy_document.control_plane.json
}

resource "aws_iam_instance_profile" "control_plane" {
  name = "${var.cluster_name}-control-plane"
  role = aws_iam_role.control_plane.name
}

# --- Workers: kubelet lookups + the EBS CSI controller ------------------------

resource "aws_iam_role" "worker" {
  name               = "${var.cluster_name}-worker"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "worker" {
  statement {
    sid = "NodeLookups"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeRegions",
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:GetRepositoryPolicy",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
      "ecr:BatchGetImage",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "worker" {
  name   = "node"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker.json
}

# The EBS CSI controller pods are scheduled on workers and pick up the
# instance role through IMDS (hence the raised hop limit on the instances).
resource "aws_iam_role_policy_attachment" "worker_ebs_csi" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_instance_profile" "worker" {
  name = "${var.cluster_name}-worker"
  role = aws_iam_role.worker.name
}
