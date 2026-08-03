output "instance_ids" {
  description = "Map of vdi user id -> EC2 instance id."
  value       = { for k, i in aws_instance.vdi : k => i.id }
}

output "public_ips" {
  description = "Map of vdi user id -> Elastic IP."
  value       = { for k, e in aws_eip.vdi : k => e.public_ip }
}

output "dcv_urls" {
  description = "Map of vdi user id -> the URL to connect the DCV client to (hostname if set, else the EIP)."
  value       = { for k, u in var.vdi_users : k => "https://${coalesce(u.hostname, aws_eip.vdi[k].public_ip)}" }
}

output "admin_password_ssm_parameters" {
  description = "Map of vdi user id -> SSM SecureString path holding the seeded initial local-admin password."
  value       = { for k, p in aws_ssm_parameter.admin_password : k => p.name }
}

output "iam_role_arn" {
  description = "The shared instance role ARN (EC2 assumes it; the on-box ACME client self-assumes it for DNS-01)."
  value       = aws_iam_role.vdi.arn
}

output "security_group_id" {
  description = "The VDI security group id."
  value       = aws_security_group.vdi.id
}
