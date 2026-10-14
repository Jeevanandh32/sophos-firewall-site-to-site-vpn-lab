locals {
  # Each site is its own VPC: <prefix>.0.0/24 = LAN (private), <prefix>.1.0/24 = WAN (public).
  sites = {
    a = { prefix = "10.10", peer = "b" }
    b = { prefix = "10.20", peer = "a" }
  }
}

# Stack names get a suffix because the template's Secrets Manager secrets are
# named after the stack and linger for 30 days after deletion.
resource "random_id" "suffix" {
  byte_length = 2
}

resource "random_password" "admin" {
  for_each         = local.sites
  length           = 20
  override_special = "!#%*-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "random_password" "config_backup" {
  for_each         = local.sites
  length           = 20
  override_special = "!#%*-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "tls_private_key" "lab" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "lab" {
  key_name   = "sophos-lab-${random_id.suffix.hex}"
  public_key = tls_private_key.lab.public_key_openssh
}

resource "local_sensitive_file" "ssh_key" {
  content         = tls_private_key.lab.private_key_openssh
  filename        = "${path.module}/.keys/sophos-lab.pem"
  file_permission = "0600"
}

# --- Firewalls: Sophos's official standalone PAYG template, one stack per site ---
# Source: github.com/sophos-iaas/aws-cf-templates xg/22.0.2.546/standalone_payg.yaml

resource "aws_cloudformation_stack" "fw" {
  for_each      = local.sites
  name          = "sophos-lab-site-${each.key}-${random_id.suffix.hex}"
  template_body = file("${path.module}/sophos-standalone-payg.yaml")
  capabilities  = ["CAPABILITY_IAM"]

  parameters = {
    AMI                    = var.sophos_ami
    AvailabilityZone       = var.availability_zone
    PublicNetworkPrefix    = each.value.prefix
    InstanceSize           = var.firewall_instance_type
    KeyName                = aws_key_pair.lab.key_name
    TrustedNetworkCIDR     = var.admin_cidr
    PublicNetworkCIDR      = var.admin_cidr
    OptUsingEIPonFirewall  = "yes"
    OptExistingElasticIpId = ""
    SophosFirewallName     = "fw-site-${each.key}"
    BasicAdminPassword     = random_password.admin[each.key].result
    ConfigBackupPassword   = random_password.config_backup[each.key].result
    AgreeUserTerms         = "yes"
    SendLearningStats      = "off"
    CentralUsername        = ""
    CentralPassword        = ""
    EnableCloudWatch       = "no"
  }

  timeouts {
    create = "30m"
    delete = "30m"
  }
}

# CloudFormation tags what it creates, which lets us look up IDs the template doesn't output.
data "aws_vpc" "site" {
  for_each = local.sites
  filter {
    name   = "tag:aws:cloudformation:stack-name"
    values = [aws_cloudformation_stack.fw[each.key].name]
  }
  filter {
    name   = "tag:aws:cloudformation:logical-id"
    values = ["VPC"]
  }
}

data "aws_subnet" "lan" {
  for_each = local.sites
  filter {
    name   = "tag:aws:cloudformation:stack-name"
    values = [aws_cloudformation_stack.fw[each.key].name]
  }
  filter {
    name   = "tag:aws:cloudformation:logical-id"
    values = ["SubnetPrivate"]
  }
}

data "aws_security_group" "wan" {
  for_each = local.sites
  filter {
    name   = "tag:aws:cloudformation:stack-name"
    values = [aws_cloudformation_stack.fw[each.key].name]
  }
  filter {
    name   = "tag:aws:cloudformation:logical-id"
    values = ["SecurityGroupPublic"]
  }
}

data "aws_network_interface" "lan" {
  for_each = local.sites
  filter {
    name   = "tag:aws:cloudformation:stack-name"
    values = [aws_cloudformation_stack.fw[each.key].name]
  }
  filter {
    name   = "tag:aws:cloudformation:logical-id"
    values = ["PrivateENI"]
  }
}

locals {
  fw_public_ip = { for k, s in aws_cloudformation_stack.fw : k => s.outputs["PublicIPAddress"] }
}

# The template only opens TCP on the WAN side. IPsec needs IKE (UDP 500),
# NAT-T (UDP 4500, used because EIPs are 1:1 NAT) and ESP, from the peer only.
resource "aws_vpc_security_group_ingress_rule" "ike" {
  for_each          = local.sites
  security_group_id = data.aws_security_group.wan[each.key].id
  description       = "IKE from peer firewall"
  ip_protocol       = "udp"
  from_port         = 500
  to_port           = 500
  cidr_ipv4         = "${local.fw_public_ip[each.value.peer]}/32"
}

resource "aws_vpc_security_group_ingress_rule" "nat_t" {
  for_each          = local.sites
  security_group_id = data.aws_security_group.wan[each.key].id
  description       = "IPsec NAT-T from peer firewall"
  ip_protocol       = "udp"
  from_port         = 4500
  to_port           = 4500
  cidr_ipv4         = "${local.fw_public_ip[each.value.peer]}/32"
}

resource "aws_vpc_security_group_ingress_rule" "esp" {
  for_each          = local.sites
  security_group_id = data.aws_security_group.wan[each.key].id
  description       = "ESP from peer firewall"
  ip_protocol       = "50"
  cidr_ipv4         = "${local.fw_public_ip[each.value.peer]}/32"
}

# --- Ubuntu client behind each firewall ---

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# EC2 Instance Connect Endpoint: SSH to the private clients with no bastion
# and no public IPs. Free of charge.
resource "aws_security_group" "eice" {
  for_each    = local.sites
  name        = "sophos-lab-eice-${each.key}"
  description = "Instance Connect Endpoint egress to clients"
  vpc_id      = data.aws_vpc.site[each.key].id

  egress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${each.value.prefix}.0.0/24"]
  }
}

resource "aws_security_group" "client" {
  for_each    = local.sites
  name        = "sophos-lab-client-${each.key}"
  description = "Lab client. Filtering is the firewall's job; this only scopes access."
  vpc_id      = data.aws_vpc.site[each.key].id

  ingress {
    description     = "SSH via Instance Connect Endpoint"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eice[each.key].id]
  }

  ingress {
    description = "Anything from lab address space (local LAN and the remote site over the tunnel)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.10.0.0/16", "10.20.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ec2_instance_connect_endpoint" "site" {
  for_each           = local.sites
  subnet_id          = data.aws_subnet.lan[each.key].id
  security_group_ids = [aws_security_group.eice[each.key].id]
  preserve_client_ip = false
  tags               = { Name = "sophos-lab-eice-${each.key}" }
}

resource "aws_instance" "client" {
  for_each                    = local.sites
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.client_instance_type
  subnet_id                   = data.aws_subnet.lan[each.key].id
  private_ip                  = "${each.value.prefix}.0.50"
  associate_public_ip_address = false
  key_name                    = aws_key_pair.lab.key_name
  vpc_security_group_ids      = [aws_security_group.client[each.key].id]

  metadata_options {
    http_tokens = "required"
  }

  user_data = <<-EOF
    #cloud-config
    hostname: client-site-${each.key}
  EOF

  tags = { Name = "client-site-${each.key}" }
}
