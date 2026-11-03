output "instance_ids" {
  description = "Map of vdi user id -> EC2 instance id."
  value       = { for k, i in aws_instance.vdi : k => i.id }
}

output "public_ips" {
  description = "Map of vdi user id -> Elastic IP."
  value       = { for k, e in aws_eip.vdi : k => e.public_ip }
}

output "private_ips" {
  description = "Map of vdi user id -> the instance's private address. This is the address to connect to over a tailnet or VPN when assign_public_ip is false."
  value       = { for k, i in aws_instance.vdi : k => i.private_ip }
}

output "dcv_urls" {
  description = <<-EOT
    Map of vdi user id -> the URL to connect the DCV client to. The hostname when one
    is set, else the Elastic IP, else the private address for a desktop reached over a
    tailnet or VPN.

    A hostname with assign_public_ip = false issues a certificate but writes no public
    A record, so whatever resolves that name has to be managed outside this module.
  EOT
  value = {
    for k, u in var.vdi_users : k => "https://${coalesce(
      u.hostname,
      try(aws_eip.vdi[k].public_ip, null),
      aws_instance.vdi[k].private_ip,
    )}"
  }
}

output "admin_password_ssm_parameters" {
  description = "Map of vdi user id -> SSM SecureString path holding the seeded initial local-admin password."
  value       = { for k, p in aws_ssm_parameter.admin_password : k => p.name }
}

output "iam_role_arn" {
  description = "The shared instance role ARN (EC2 assumes it; the on-box ACME client self-assumes it for DNS-01)."
  value       = aws_iam_role.vdi.arn
}

output "iam_role_name" {
  description = "The shared instance role name — attach extra inline policies or managed-policy attachments to it from the caller."
  value       = aws_iam_role.vdi.name
}

output "security_group_id" {
  description = "The VDI security group id."
  value       = aws_security_group.vdi.id
}
