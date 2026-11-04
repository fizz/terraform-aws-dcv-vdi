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

variable "assign_public_ip" {
  description = <<-EOT
    Give each desktop an Elastic IP and a public Route53 A record. True keeps the
    original behaviour: a desktop reachable at a clean https hostname from the
    internet, with an on-box Let's Encrypt certificate.

    Set it to false for a desktop that is reached over a private network instead --
    a tailnet, a VPN or a peered VPC. No Elastic IP is created and no public A
    record is written, so the desktop has no address on the internet at all.
    Pair it with allowed_ingress_security_group_ids so the gate is a security
    group rather than a CIDR.

    A private desktop still needs egress for DCV licensing, package pulls and the
    SSM agent, so place it in a subnet with a NAT route.
  EOT
  type        = bool
  default     = true
}

variable "allowed_ingress_security_group_ids" {
  description = <<-EOT
    Security groups allowed to reach DCV, in addition to allowed_ingress_cidrs.
    Use this instead of a CIDR when the thing in front of the desktop has its own
    group -- a tailnet subnet router, a bastion, a load balancer. The rule follows
    the group rather than an address, so it survives the instance behind it being
    replaced.

    With assign_public_ip = false and allowed_ingress_cidrs = [], these groups are
    the only way in.
  EOT
  type        = list(string)
  default     = []
}

variable "allowed_ingress_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach DCV (443 tcp + dcv_port tcp/udp). Scope this to the
    users' client IPs. 0.0.0.0/0 is strongly discouraged but not blocked: DCV
    enforces its own OS-credential auth, so open ingress can be a defensible,
    informed choice — but it exposes the login surface to the whole internet.
    Prefer /32s.

    An empty list is allowed only when allowed_ingress_security_group_ids names at
    least one group, which is the private-tailnet case. The two together must leave
    some way in.
  EOT
  type        = list(string)
  default     = []

}

# Both lists empty is legitimate and is the third mode: the desktop is itself a node on
# an overlay network -- a tailnet, a WireGuard mesh -- so DCV traffic arrives through a
# tunnel that terminates on the host and never crosses the security group at all. Access
# control then lives in the overlay's own ACLs, which is a better place for it: the rule
# follows the person rather than an address or a group.
#
# There is deliberately no validation forcing one of the two to be non-empty. It was
# there, and it rejected exactly this case.

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

variable "win_acme_version" {
  description = <<-EOT
    win-acme release tag to install, e.g. "v2.2.9.1701". It is a release tag rather than
    a `latest` URL on purpose: the bootstrap runs once at first boot, so a desktop built
    today and its replacement built next month would otherwise get different ACME clients
    with no record of which, and that difference surfaces as a renewal that stops working
    on one box.

    The tag also names the files. The pluggable release and the route53 validation plugin
    are two separate downloads, both versioned -- the plugin is not inside the pluggable
    zip, and without it `--validation route53` fails after the ACME account is already
    registered, which reads as a Let's Encrypt problem rather than a missing file.
  EOT
  type        = string
  default     = "v2.2.9.1701"
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

  # AWS publishes one character set for tags and then enforces it unevenly. EC2 and S3
  # take a comma; IAM and SSM reject it. A module that tags all four therefore fails
  # halfway through an apply, having already created the resources whose services are
  # lenient, and the error names a service rather than the character.
  #
  # Checking it here moves that discovery from the middle of an apply to `terraform
  # validate`, which costs nothing and runs before anything exists. No linter does this:
  # tflint's only tag rule checks that keys are present, not that values are legal.
  validation {
    condition = alltrue([
      for v in values(var.tags) : can(regex("^[\\p{L}\\p{Z}\\p{N}_.:/=+\\-@]*$", v))
    ])
    error_message = "A tag value may hold only letters, separators, digits and _ . : / = + - @ — a comma is the usual offender. Rejected: ${join(", ", [for k, v in var.tags : "${k}=${v}" if !can(regex("^[\\p{L}\\p{Z}\\p{N}_.:/=+\\-@]*$", v))])}"
  }

  validation {
    condition = alltrue([
      for k in keys(var.tags) : can(regex("^[\\p{L}\\p{Z}\\p{N}_.:/=+\\-@]*$", k)) && !startswith(lower(k), "aws:")
    ])
    error_message = "A tag key may hold only letters, separators, digits and _ . : / = + - @, and may not begin with the reserved aws: prefix."
  }
}
