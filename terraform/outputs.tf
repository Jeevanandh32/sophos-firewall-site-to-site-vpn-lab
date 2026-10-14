output "firewalls" {
  description = "Values needed in the Sophos WebAdmin, including the IPsec settings."
  value = {
    for k, s in local.sites : "site-${k}" => {
      webadmin          = "https://${local.fw_public_ip[k]}:4444"
      ssh               = "ssh -i .keys/sophos-lab.pem admin@${local.fw_public_ip[k]}"
      public_ip         = local.fw_public_ip[k]
      wan_private_ip    = aws_cloudformation_stack.fw[k].outputs["PrivateIPAddressPublicENI"]
      lan_private_ip    = data.aws_network_interface.lan[k].private_ip
      local_network     = "${s.prefix}.0.0/24"
      peer_public_ip    = local.fw_public_ip[s.peer]
      peer_network      = "${local.sites[s.peer].prefix}.0.0/24"
      admin_password_of = "terraform output -json admin_passwords | jq -r '.\"site-${k}\"'"
    }
  }
}

output "clients" {
  value = {
    for k, i in aws_instance.client : "site-${k}" => {
      private_ip = i.private_ip
      ssh        = "aws ec2-instance-connect ssh --instance-id ${i.id} --os-user ubuntu --connection-type eice --private-key-file .keys/sophos-lab.pem"
    }
  }
}

output "admin_passwords" {
  value     = { for k, p in random_password.admin : "site-${k}" => p.result }
  sensitive = true
}

output "config_backup_passwords" {
  value     = { for k, p in random_password.config_backup : "site-${k}" => p.result }
  sensitive = true
}
