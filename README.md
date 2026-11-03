# terraform-aws-dcv-vdi

A self-hosted [NICE DCV](https://aws.amazon.com/hpc/dcv/) Windows desktop on EC2 — a
WorkSpaces alternative that **can run Docker** (nested virtualization → WSL2 backend),
reachable at a **clean `https://` URL with an auto-renewing Let's Encrypt certificate**.
No ALB, no ACM, **no static credentials**.

Works in any AWS account and partition (commercial or GovCloud) — everything account-,
region-, and domain-specific is a variable.

## Why

Amazon WorkSpaces can't run Docker, and fronting a desktop with an ALB + ACM cert is
heavy and costs a load balancer. This module puts the whole thing on one instance:

- **DCV on EC2** with `cpu_options.nested_virtualization` so Docker Desktop's WSL2
  backend works.
- **Elastic IP + Route53 A record** so the URL is stable.
- **On-box Let's Encrypt** via [win-acme](https://www.win-acme.com/), renewing on the
  box itself. No ACM, no ALB.
- **A `443 → dcv_port` portproxy** because DCV refuses privileged ports, so users type a
  clean `https://host` with no `:8443`.

## The interesting part: on-box ACME with no static keys

DNS-01 needs credentials to write the `_acme-challenge` record. Instead of an IAM user
with long-lived keys sitting on the box, **the instance role trusts itself**:

```hcl
# (excerpt) the role's trust policy lists its own ARN as a principal
principals {
  type        = "AWS"
  identifiers = ["arn:${partition}:iam::${account_id}:role/${name}"]
}
```

win-acme's Route53 plugin (`--route53iamrole <ROLE_NAME>` — the **name**, not an ARN)
calls `AssumeRole` on the role the box is *already running under*, getting fresh,
short-lived STS credentials for each challenge. Nothing static to leak or rotate. The
renewal credential is ephemeral and self-minted. This pattern applies to any EC2 box
doing on-box ACME, Windows or Linux.

## The other gotcha: the reboot loop

The bootstrap installs WSL2 features and reboots to apply them. A boot-time script that
reboots **must be idempotent**, or EC2 `<persist>true>` re-runs it every boot and the box
reboots itself every few minutes forever. This module ships `<persist>false>` **and** a
run-once marker (`C:\dcv-bootstrap.done`) — belt and suspenders.

## Usage

```hcl
module "vdi" {
  source = "github.com/fizz/terraform-aws-dcv-vdi?ref=v0.1.0"

  name                  = "dcv-vdi"
  vpc_id                = "vpc-0123456789abcdef0"
  subnet_id             = "subnet-0123456789abcdef0"   # must reach the internet
  allowed_ingress_cidrs = ["203.0.113.4/32"]           # your IP — never 0.0.0.0/0
  route53_zone_id       = "Z0123456789ABCDEFGHIJ"
  letsencrypt_email     = "you@example.com"

  vdi_users = {
    alice = {
      username = "alice"
      hostname = "alice-vdi.example.com"   # gets an A record + LE cert
    }
    # bob = { username = "bob" }           # IP-only, DCV self-signed cert
  }
}

output "dcv_urls" { value = module.vdi.dcv_urls }
```

Then connect the [DCV client](https://www.amazonaws.cn/en/hpc/dcv/) to the output URL and
sign in with the local admin whose seeded password is in SSM
(`terraform output admin_password_ssm_parameters`).

## Private mode: a desktop with no address on the internet

The default above is a desktop you reach at an https hostname from anywhere. Set
`assign_public_ip = false` and it gets no Elastic IP and no public DNS record at all —
for a desktop you reach over a tailnet, a VPN or a peered VPC instead.

Two ways to gate it, and they are different models.

**A security group in front.** The thing that fronts the desktop has its own group — a
tailnet subnet router, a bastion, an internal load balancer — and that group is the only
ingress. The rule follows the group, so it survives the instance behind it being
replaced, which an address-based rule does not.

```hcl
module "vdi" {
  source = "github.com/fizz/terraform-aws-dcv-vdi?ref=v0.2.0"

  name      = "eval"
  vpc_id    = "vpc-0123456789abcdef0"
  subnet_id = "subnet-0123456789abcdef0" # private, with a NAT route

  assign_public_ip                   = false
  allowed_ingress_cidrs              = []
  allowed_ingress_security_group_ids = ["sg-0123456789abcdef0"]

  enable_nested_virtualization = true

  vdi_users = {
    eval = {
      username = "evaluator"
      hostname = null # no record, no certificate
    }
  }
}
```

**The desktop on the overlay itself.** Join it to the tailnet as a node and DCV traffic
arrives through a tunnel that terminates on the host, never crossing the security group.
Leave **both** ingress lists empty: zero ingress is correct here, and access control
moves into the overlay's ACLs, where the rule follows the person rather than an address.

Install and authenticate the tunnel client from your own provisioning — this module does
not do it for you.

### Two things to know

`hostname` is still what asks for TLS. Setting it with `assign_public_ip = false` issues
a certificate through DNS-01 — which needs no inbound and so still works — but writes no
public A record, so nothing resolves the name unless you manage that elsewhere. For a
private desktop, leave `hostname = null` and accept DCV's own certificate.

The desktop still needs **egress**: DCV licensing, package pulls, the SSM agent and ACME
all reach out. A private subnet with a NAT route, not an isolated one.

### Outputs in private mode

`public_ips` is an empty map. Use `private_ips`, and `dcv_urls` falls back from hostname
to Elastic IP to the private address, so it is correct in all three modes.

## Inputs / outputs

See [`variables.tf`](./variables.tf) and [`outputs.tf`](./outputs.tf). Highlights:

| Input | Notes |
|---|---|
| `vdi_users` | map of desktops; each gets its own EIP, admin password, optional hostname |
| `allowed_ingress_cidrs` | client IPs; `0.0.0.0/0` is strongly discouraged (DCV has its own OS-cred auth) but not blocked — empty list is |
| `dcv_port` | default `8443`; a `443` portproxy fronts it |
| `route53_zone_id` / `letsencrypt_email` | required only if a user has a `hostname` |
| `kms_key_id` | optional CMK for EBS + SSM; `null` uses AWS-managed keys |
| `enable_nested_virtualization` | `true` for Docker; needs a supporting instance type |

## Requirements

- Terraform ≥ 1.3, AWS provider ≥ 5.90 (for `cpu_options.nested_virtualization`).
- A subnet with a route to the internet (IGW/NAT) for DCV licensing, package pulls, SSM, ACME.
- An instance type that supports nested virtualization (e.g. an `*-flex` or metal family).

## Notes

- Pin the win-acme release asset URL in `templates/dcv-bootstrap.ps1.tftpl` for reproducible
  builds, and verify the DCV certificate registry keys against your DCV server version.
- The furnish layer (Docker Desktop + tools) is intentionally out of scope — do it over SSM
  or Ansible after the box is up.
- Prior art: check the Terraform Registry for an existing DCV + Let's Encrypt module before
  standing on this one.

## License

MIT — see [LICENSE](./LICENSE).
