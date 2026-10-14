variable "region" {
  description = "AWS region for both sites."
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "AZ used by both sites."
  type        = string
  default     = "us-east-1a"
}

variable "admin_cidr" {
  description = "Your public IP as /32. Only this address can reach WebAdmin (4444) and SSH (22) on the firewalls."
  type        = string
}

variable "sophos_ami" {
  description = "Sophos Firewall standalone PAYG AMI (v22.0.2.546 in us-east-1)."
  type        = string
  default     = "ami-02cfeae4bb63590a2"
}

variable "firewall_instance_type" {
  description = "Smallest size the Sophos template allows."
  type        = string
  default     = "t3.medium"
}

variable "client_instance_type" {
  type    = string
  default = "t3.micro"
}
