data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # cloud-provider-aws discovers "its" resources through this tag.
  cluster_tag = { "kubernetes.io/cluster/${var.cluster_name}" = "owned" }
}

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr
  # Node names must equal the EC2 private DNS name for cloud-provider-aws,
  # so the VPC has to hand out resolvable hostnames.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.cluster_name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.cluster_name }
}

# Public subnets only: a NAT gateway would cost more than the three nodes'
# compute put together. Nodes get public IPs and are fenced by the security group.
resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.cluster_tag, {
    Name = "${var.cluster_name}-public-${local.azs[count.index]}"
    # Tells cloud-provider-aws these subnets may host internet-facing load balancers.
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.cluster_name}-public" }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
