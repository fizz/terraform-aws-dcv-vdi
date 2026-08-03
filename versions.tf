terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 6.0 for two reasons: cpu_options.nested_virtualization (Docker Desktop's
      # WSL2 backend) and the aws_region data source's `region` attribute (`name` was
      # deprecated in 6.0). If plan rejects nested_virtualization, set
      # enable_nested_virtualization = false.
      version = ">= 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}
