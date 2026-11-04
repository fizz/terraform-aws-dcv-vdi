# terraform-aws-dcv-vdi
#
# Self-hosted NICE DCV Windows desktop on EC2 — a WorkSpaces alternative that can run
# Docker (nested virtualization -> WSL2 backend), reachable at a clean https URL with an
# on-box auto-renewing Let's Encrypt cert. No ALB, no ACM, no static credentials.
#
# The cert automation is the interesting part: the instance role trusts *itself*, so the
# on-box ACME client (win-acme) calls AssumeRole on the role it is already running under
# to get fresh, short-lived STS creds for each Route53 DNS-01 challenge. Nothing static
# to leak or rotate. See templates/dcv-bootstrap.ps1.tftpl.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  # Any user asking for a public hostname needs the DNS + ACME plumbing.
  wants_tls = length([for u in var.vdi_users : u if u.hostname != null]) > 0
}

# Windows base AMI resolved from the AWS public SSM parameter (always current).
data "aws_ssm_parameter" "windows_ami" {
  name = var.windows_ami_ssm_parameter
}

# -----------------------------------------------------------------------------
# Per-user local-admin password -> SSM SecureString. Terraform SEEDS it (the
# bootstrap reads it to set the Windows admin at first boot); after that the
# operator owns the value, so a later rotation is not clobbered on re-apply.
# -----------------------------------------------------------------------------
resource "random_password" "admin" {
  for_each = var.vdi_users

  length  = 20
  special = true
  # Windows/PowerShell/DCV-login safe: avoid quoting + escaping hazards.
  override_special = "!#%*+-=?_"
}

resource "aws_ssm_parameter" "admin_password" {
  for_each = var.vdi_users

  name   = "${var.ssm_parameter_prefix}/${each.value.username}/admin-password"
  type   = "SecureString"
  key_id = var.kms_key_id
  value  = random_password.admin[each.key].result
  tags   = merge(var.tags, { User = each.value.username })

  lifecycle {
    ignore_changes = [value]
  }
}

# -----------------------------------------------------------------------------
# IAM: one shared instance role. EC2 assumes it; it also trusts ITSELF so the
# on-box ACME client can mint short-lived STS creds for DNS-01 (no static keys).
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }

  # Self-assume, so the on-box ACME client can mint short-lived STS credentials for
  # the DNS-01 challenge. Only a desktop with a hostname runs ACME, so only that
  # desktop needs it.
  #
  # The principal is the account root with a condition pinning it to this role's ARN,
  # not the role ARN itself. Naming the role directly cannot create: IAM validates
  # principals at CreateRole, the role does not exist yet, and it refuses with
  # MalformedPolicyDocument. Adding the same statement to a role that already exists
  # succeeds, which is why a module adopted onto existing infrastructure never shows
  # this and a fresh install always does.
  #
  # The root principal exists from the start, and the condition narrows the grant back
  # to exactly this one role, so nothing else in the account inherits it.
  dynamic "statement" {
    for_each = local.wants_tls ? [1] : []
    content {
      actions = ["sts:AssumeRole"]
      principals {
        type        = "AWS"
        identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
      }
      condition {
        test     = "ArnEquals"
        variable = "aws:PrincipalArn"
        values   = ["arn:${local.partition}:iam::${local.account_id}:role/${var.name}"]
      }
    }
  }
}

resource "aws_iam_role" "vdi" {
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.vdi.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "inline" {
  # DCV automatic licensing on EC2 reads from the regional license bucket.
  statement {
    sid       = "DcvLicense"
    actions   = ["s3:GetObject"]
    resources = ["arn:${local.partition}:s3:::dcv-license.${local.region}/*"]
  }

  # Read the box's own seeded local-admin password at first boot.
  statement {
    sid       = "ReadOwnAdminPassword"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${var.ssm_parameter_prefix}/*"]
  }

  # Decrypt that SecureString when a customer CMK is used.
  dynamic "statement" {
    for_each = var.kms_key_id == null ? [] : [1]
    content {
      sid       = "DecryptAdminPassword"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [var.kms_key_id]
    }
  }

  # ACME DNS-01: publish/clean the _acme-challenge TXT for the VDI hostname.
  dynamic "statement" {
    for_each = local.wants_tls ? [1] : []
    content {
      sid       = "AcmeDns01Write"
      actions   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
      resources = ["arn:${local.partition}:route53:::hostedzone/${var.route53_zone_id}"]
    }
  }
  dynamic "statement" {
    for_each = local.wants_tls ? [1] : []
    content {
      sid       = "AcmeDns01FindZone"
      actions   = ["route53:ListHostedZones", "route53:GetChange"]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "inline" {
  name   = "${var.name}-inline"
  role   = aws_iam_role.vdi.id
  policy = data.aws_iam_policy_document.inline.json
}

resource "aws_iam_instance_profile" "vdi" {
  name = var.name
  role = aws_iam_role.vdi.name
}

# -----------------------------------------------------------------------------
# Security group — DCV web+QUIC and the 443 portproxy, allowlisted CIDRs only.
# -----------------------------------------------------------------------------
# name_prefix + create_before_destroy so this SG is actually REPLACEABLE. A
# fixed-name SG attached to a running instance can't be replaced: destroy-first
# deadlocks on the instance's dependency, and create-first collides on the name.
# name_prefix lets AWS mint a unique name so the new SG is created, the instance
# is rewired onto it, and only then is the old one deleted.
resource "aws_security_group" "vdi" {
  name_prefix = "${var.name}-"
  description = "NICE DCV VDI: DCV web+QUIC and 443 portproxy from allowlisted CIDRs and security groups only"
  vpc_id      = var.vpc_id

  # An ingress rule must name at least one source. These are dynamic so that an empty
  # allowed_ingress_cidrs produces no rule at all, rather than three rules with no
  # source, which AWS rejects.
  dynamic "ingress" {
    for_each = length(var.allowed_ingress_cidrs) > 0 ? [1] : []
    content {
      description = "DCV web (HTTPS)"
      from_port   = var.dcv_port
      to_port     = var.dcv_port
      protocol    = "tcp"
      cidr_blocks = var.allowed_ingress_cidrs
    }
  }

  dynamic "ingress" {
    for_each = length(var.allowed_ingress_cidrs) > 0 ? [1] : []
    content {
      description = "DCV QUIC (UDP)"
      from_port   = var.dcv_port
      to_port     = var.dcv_port
      protocol    = "udp"
      cidr_blocks = var.allowed_ingress_cidrs
    }
  }

  # DCV can't bind privileged ports, so a portproxy fronts 443 -> dcv_port (clean URL).
  dynamic "ingress" {
    for_each = length(var.allowed_ingress_cidrs) > 0 ? [1] : []
    content {
      description = "DCV via 443 portproxy"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = var.allowed_ingress_cidrs
    }
  }

  # The same three rules again, sourced from security groups instead of addresses.
  # A group-sourced rule keeps working when the instance in front is replaced, which
  # an address-sourced one does not. For a private desktop these are the only way in.
  dynamic "ingress" {
    for_each = length(var.allowed_ingress_security_group_ids) > 0 ? [1] : []
    content {
      description     = "DCV web (HTTPS) from allowed security groups"
      from_port       = var.dcv_port
      to_port         = var.dcv_port
      protocol        = "tcp"
      security_groups = var.allowed_ingress_security_group_ids
    }
  }

  dynamic "ingress" {
    for_each = length(var.allowed_ingress_security_group_ids) > 0 ? [1] : []
    content {
      description     = "DCV QUIC (UDP) from allowed security groups"
      from_port       = var.dcv_port
      to_port         = var.dcv_port
      protocol        = "udp"
      security_groups = var.allowed_ingress_security_group_ids
    }
  }

  dynamic "ingress" {
    for_each = length(var.allowed_ingress_security_group_ids) > 0 ? [1] : []
    content {
      description     = "DCV via 443 portproxy from allowed security groups"
      from_port       = 443
      to_port         = 443
      protocol        = "tcp"
      security_groups = var.allowed_ingress_security_group_ids
    }
  }

  egress {
    description = "All egress (DCV licensing, package/tool pulls, SSM, ACME)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# The VDI instances — one per vdi_users entry.
# -----------------------------------------------------------------------------
resource "aws_instance" "vdi" {
  for_each = var.vdi_users

  ami                    = data.aws_ssm_parameter.windows_ami.value
  instance_type          = each.value.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.vdi.id]
  iam_instance_profile   = aws_iam_instance_profile.vdi.name

  dynamic "cpu_options" {
    for_each = var.enable_nested_virtualization ? [1] : []
    content {
      nested_virtualization = "enabled"
    }
  }

  metadata_options {
    http_endpoint = "enabled" # DCV licensing + SSM need IMDS
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = each.value.root_volume_gb
    encrypted   = true
    kms_key_id  = var.kms_key_id
  }

  # Data volume -> Windows D: (user profile + work files).
  ebs_block_device {
    device_name           = "xvdb"
    volume_type           = "gp3"
    volume_size           = each.value.data_volume_gb
    encrypted             = true
    kms_key_id            = var.kms_key_id
    delete_on_termination = false
  }

  user_data = templatefile("${path.module}/templates/dcv-bootstrap.ps1.tftpl", {
    region             = local.region
    ssm_password_param = aws_ssm_parameter.admin_password[each.key].name
    admin_username     = each.value.username
    dcv_port           = var.dcv_port
    # "value or empty string" — NOT coalesce(): coalesce rejects an all-empty
    # argument list, so coalesce(null, "") crashes. This is the common no-TLS path.
    hostname          = each.value.hostname == null ? "" : each.value.hostname
    route53_zone_id   = var.route53_zone_id == null ? "" : var.route53_zone_id
    letsencrypt_email = var.letsencrypt_email == null ? "" : var.letsencrypt_email
    acme_role_name    = var.name
    win_acme_version  = var.win_acme_version
  })

  tags = merge(var.tags, { Name = "${var.name}-${each.key}", User = each.value.username })

  # Don't silently replace a user's box on an AMI refresh or user_data tweak.
  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

resource "aws_eip" "vdi" {
  for_each = var.assign_public_ip ? var.vdi_users : {}

  instance = aws_instance.vdi[each.key].id
  domain   = "vpc"

  tags = merge(var.tags, { Name = "${var.name}-${each.key}", User = each.value.username })
}

# The hostname users type, and the name win-acme certifies.
#
# In public mode it points at the Elastic IP. In private mode there is no Elastic IP, so
# it points at whatever private_dns_target names -- a tailnet address, a VPN address, a
# private IP reached over a peering. A desktop that sets neither gets no record: the
# hostname still drives certificate issuance, and resolving it stays someone else's job.
resource "aws_route53_record" "vdi" {
  for_each = {
    for k, u in var.vdi_users : k => u
    if u.hostname != null && (var.assign_public_ip || u.private_dns_target != null)
  }

  zone_id = var.route53_zone_id
  name    = each.value.hostname
  type    = "A"
  ttl     = 300
  records = [var.assign_public_ip ? aws_eip.vdi[each.key].public_ip : each.value.private_dns_target]
}
