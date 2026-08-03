variable "name" {
  description = "Name prefix for the IAM role, instance profile, security group, and instance profile. The IAM role name is also what the on-box ACME client self-assumes, so keep it stable."
  type        = string
  default     = "dcv-vdi"
}

variable "vpc_id" {
  description = "VPC to place the VDI in."
  type        = string
}

variable "subnet_id" {
  description = "Subnet for the VDI instance(s). Needs a route to the internet (IGW or NAT) for DCV licensing, tool/package pulls, SSM, and ACME."
  type        = string
}

variable "vdi_users" {
  description = <<-EOT
    VDI instances to create, keyed by a short id. Each entry is one Windows desktop
    with its own Elastic IP, seeded local-admin password (in SSM), and optional public
    hostname. Set `hostname` to get a Route53 A record + auto-renewing Let's Encrypt cert;
    leave it null for an IP-only box with DCV's self-signed cert.
  EOT
  type = map(object({
    username       = string
    instance_type  = optional(string, "m8i-flex.xlarge")
    root_volume_gb = optional(number, 100)
    data_volume_gb = optional(number, 100)
    hostname       = optional(string) # FQDN inside route53_zone_id; null = no DNS / no LE cert
  }))
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach DCV (443 tcp + dcv_port tcp/udp). Scope this to the users' IPs — never 0.0.0.0/0."
  type        = list(string)

  validation {
    condition     = !contains(var.allowed_ingress_cidrs, "0.0.0.0/0")
    error_message = "Refusing 0.0.0.0/0 on a remote-desktop ingress. Scope allowed_ingress_cidrs to real client IPs."
  }
}

variable "dcv_port" {
  description = "Port NICE DCV serves web + QUIC on. A 443 portproxy fronts it so the URL needs no :port (DCV can't bind privileged ports)."
  type        = number
  default     = 8443
}

variable "windows_ami_ssm_parameter" {
  description = "AWS public SSM parameter that resolves the Windows base AMI."
  type        = string
  default     = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

variable "route53_zone_id" {
  description = "Route53 hosted zone id for the VDI hostnames and the ACME DNS-01 challenge. Required if any vdi_users entry sets a hostname."
  type        = string
  default     = null
}

variable "letsencrypt_email" {
  description = "Contact email for Let's Encrypt account registration (win-acme). Required if any vdi_users entry sets a hostname."
  type        = string
  default     = null
}

variable "kms_key_id" {
  description = "KMS key ARN for EBS volume and SSM SecureString encryption. Null uses the AWS-managed keys (aws/ebs, aws/ssm)."
  type        = string
  default     = null
}

variable "ssm_parameter_prefix" {
  description = "SSM path prefix for the per-user seeded admin passwords, e.g. /dcv-vdi/<username>/admin-password."
  type        = string
  default     = "/dcv-vdi"
}

variable "enable_nested_virtualization" {
  description = "Enable nested virtualization so Docker Desktop's WSL2 backend works. Requires a supporting instance type (e.g. an *-flex or metal family)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}
