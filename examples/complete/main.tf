# Example: one Docker-capable DCV desktop with a public hostname + auto-renewing LE cert.
# Aimed at a personal AWS account (e.g. the `fd-sapro-main` profile), but nothing here is
# account-specific beyond the values you fill in.

terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.90"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  # profile = "fd-sapro-main"   # uncomment to target your personal account
}

module "vdi" {
  source = "../../"

  name = "dcv-vdi"

  # --- fill these in for your account ---
  vpc_id                = "vpc-xxxxxxxxxxxxxxxxx"
  subnet_id             = "subnet-xxxxxxxxxxxxxxxxx" # must reach the internet (IGW/NAT)
  allowed_ingress_cidrs = ["203.0.113.4/32"]         # your IP — never 0.0.0.0/0
  route53_zone_id       = "Zxxxxxxxxxxxxxxxxxxxx"
  letsencrypt_email     = "you@example.com"

  vdi_users = {
    me = {
      username = "me"
      hostname = "my-vdi.example.com" # gets a Route53 A record + LE cert
      # instance_type = "m8i-flex.xlarge"   # override defaults if needed
    }
  }

  tags = { Project = "dcv-vdi-demo" }
}

output "dcv_urls" {
  value = module.vdi.dcv_urls
}

output "admin_password_ssm_parameters" {
  description = "Read these with: aws ssm get-parameter --name <path> --with-decryption"
  value       = module.vdi.admin_password_ssm_parameters
}
