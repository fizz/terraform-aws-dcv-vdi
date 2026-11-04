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
  source = "github.com/fizz/terraform-aws-dcv-vdi?ref=v0.3.0"

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
  source = "github.com/fizz/terraform-aws-dcv-vdi?ref=v0.3.0"

  name      = "eval"
  vpc_id    = "vpc-0123456789abcdef0"
  subnet_id = "subnet-0123456789abcdef0" # private, with a NAT route

  assign_public_ip                   = false
  allowed_ingress_cidrs              = []
  allowed_ingress_security_group_ids = ["sg-0123456789abcdef0"]
  route53_zone_id                    = "Z0123456789ABCDEFGHIJ"
  letsencrypt_email                  = "you@example.com"

  enable_nested_virtualization = true

  vdi_users = {
    eval = {
      username = "evaluator"

      # A real certificate and a name that resolves, on a desktop with no public
      # address at all. DNS-01 never connects to the host, so the certificate is
      # issued over the tailnet's head; the A record then points the certified name
      # at the tailnet address.
      hostname           = "eval-vdi.example.com"
      private_dns_target = "100.64.0.5"
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

### A public name for a private address

`hostname` is what asks for TLS, in either mode. Issuance is DNS-01, which never connects
to the host, so a desktop with no ingress and no public address still gets a real
certificate from a public CA.

What was missing until v0.3.0 was the other half: the name that certificate covers has to
resolve to *something*, and in private mode there is no Elastic IP to point it at. Set
`private_dns_target` to the address people actually reach the desktop on and the module
writes the A record for you. Leave it unset and you get a certificate and no record,
which is the old behaviour and still correct when something else owns that name.

Publishing a private address in public DNS is deliberate here. `100.64.0.5` and
`10.121.10.44` are not routable from the internet, so the record gives away a layout, not
an entrance — and it buys a clean `https://` URL with no port, no certificate warning and
no hosts-file edit on every client.

The desktop still needs **egress**: DCV licensing, package pulls, the SSM agent and ACME
all reach out. A private subnet with a NAT route, not an isolated one.

### When the zone is in another account

By default win-acme proves the name with the desktop's own instance role: the role holds
the Route53 grant, assumes itself for short-lived credentials, and writes the challenge.
That works whenever the zone and the desktop share an account.

It stops working the moment they do not, and the failure is easy to misread as a privacy
constraint rather than an account one. `--route53iamrole` takes a role **name** and builds
the ARN from the account win-acme is running in, so it cannot name a role anywhere else;
and Route53 has no resource policy, so the zone cannot be shared back the other way.

Set `acme_role_arn` to a role in the account that owns the zone:

```hcl
route53_zone_id = "Z0123456789ABCDEFGHIJ"
acme_role_arn   = "arn:aws:iam::222222222222:role/dns-acme"
```

This **switches** the mechanism rather than adding to it. The module writes an AWS SDK
profile on the desktop whose `credential_source` is the instance metadata and whose
`role_arn` is that role, points win-acme at it through `AWS_PROFILE`, and drops
`--route53iamrole`. The SDK makes the hop, so there is still no IAM user and no static
key — the instance role's only added permission is `sts:AssumeRole` on that one ARN, and
the Route53 grant stays in the account that owns the zone.

Give that role the narrowest grant that works: `ChangeResourceRecordSets` on the zone,
conditioned to `TXT` at `_acme-challenge.*` names, plus `GetChange` and the list calls.
It has to trust the desktop's instance role.

Do not reuse a role your CI already assumes for applying terraform. Renewal fires from a
scheduled task on the desktop around day sixty, when no workflow is running — that is the
whole reason it needs a role of its own, and folding the challenge grant into an apply
role hands every apply the ability to publish challenge records.

The tempting alternative is delegating the subdomain into the desktop's account so that
everything is local again. Look at what already lives under that name first: a delegation
shadows **every** existing record there, so an app record or an ACM validation record in
the parent zone stops resolving until it is recreated in the new zone.

### Outputs in private mode

`public_ips` is an empty map. Use `private_ips`, and `dcv_urls` falls back from hostname
to Elastic IP to the private address, so it is correct in all three modes. `dns_records`
lists the records this module wrote — a desktop with a hostname and no record is simply
absent from it, which is the fastest way to see that a certified name resolves to nothing.

## Hibernation: stop the desktop without losing the session

A stopped EC2 instance keeps its disks and loses its memory. For a developer desktop that
is the whole cost: the WSL2 VM, the containers, the editor, the warm caches all go, and
coming back is a cold boot and a re-setup. So nobody stops it, and a box that is used four
hours a day bills for twenty-four.

Set `hibernate = true` and a stop writes RAM to the root volume and restores it on start.

```hcl
vdi_users = {
  eval = {
    username       = "evaluator"
    instance_type  = "m8i.2xlarge" # 32 GB RAM
    root_volume_gb = 150           # must exceed the RAM, with room for Windows
    hibernate      = true
  }
}
```

Three things AWS requires, and what this module does about each:

| Requirement | Handled by |
|---|---|
| Encrypted root volume | always — `encrypted = true`, unconditionally |
| Root volume larger than the instance's RAM | a plan-time precondition that reads the real RAM figure from the instance type |
| An instance type that supports hibernation | a plan-time precondition that reads `hibernation_supported` |

Both preconditions fail the **plan**, naming the desktop and the numbers, rather than
letting the first hibernate fail at the moment there is a session to lose.

**Hibernation is launch-time only.** It cannot be switched on for an instance that already
exists, so adding it replaces the desktop: the data volume survives (`delete_on_termination
= false`), everything on `C:` does not. Pair it with `ami` on the same desktop and the
replacement comes back already furnished:

```hcl
eval = {
  username       = "evaluator"
  root_volume_gb = 150
  hibernate      = true
  ami            = "ami-0abc123def4567890" # captured from the desktop being replaced
}
```

`ami` is in `ignore_changes`, so setting it alone never replaces a running desktop. It
takes effect on the replacement that `hibernate` triggers.

## Inputs / outputs

See [`variables.tf`](./variables.tf) and [`outputs.tf`](./outputs.tf). Highlights:

| Input | Notes |
|---|---|
| `vdi_users` | map of desktops; each gets its own EIP, admin password, optional hostname |
| `allowed_ingress_cidrs` | client IPs; `0.0.0.0/0` is strongly discouraged (DCV has its own OS-cred auth) but not blocked — empty list is |
| `dcv_port` | default `8443`; a `443` portproxy fronts it |
| `route53_zone_id` / `letsencrypt_email` | required only if a user has a `hostname` |
| `acme_role_arn` | set only when the zone is in ANOTHER account; switches win-acme from self-assume to an SDK profile that assumes this role |
| `win_acme_version` | pinned win-acme release tag; the route53 plugin is a second, separately versioned download |
| `kms_key_id` | optional CMK for EBS + SSM; `null` uses AWS-managed keys |
| `enable_nested_virtualization` | `true` for Docker; needs a supporting instance type |

Per desktop, inside `vdi_users`:

| Field | Notes |
|---|---|
| `hostname` | Route53 name + Let's Encrypt cert; `null` for DCV's self-signed |
| `private_dns_target` | where that name points when `assign_public_ip = false` |
| `hibernate` | stop without losing the session; launch-time only, so it replaces the desktop |
| `ami` | launch from a captured AMI instead of the current Windows base image |
| `instance_type` / `root_volume_gb` / `data_volume_gb` | per-desktop sizing |

## Requirements

- Terraform ≥ 1.3, AWS provider ≥ 5.90 (for `cpu_options.nested_virtualization`).
- A subnet with a route to the internet (IGW/NAT) for DCV licensing, package pulls, SSM, ACME.
- An instance type that supports nested virtualization (e.g. an `*-flex` or metal family).

## Notes

- win-acme is pinned by `win_acme_version`, and the Route53 validation plugin is a second
  download at the same tag — it is **not** inside `win-acme.x64.pluggable.zip`. Without it,
  `--validation route53` fails only after the ACME account is registered, which reads as a
  Let's Encrypt problem rather than a missing file.
- The certificate is deployed by **copying the PEMs** to
  `C:\Windows\System32\config\systemprofile\AppData\Local\NICE\dcv\` (key under `private\`).
  DCV reads that fixed path and ignores the `connectivity` registry values: setting
  `certificate-file` there applies without error and changes nothing, and the server keeps
  serving its self-signed certificate.
- The furnish layer (Docker Desktop + tools) is intentionally out of scope — do it over SSM
  or Ansible after the box is up.
- Prior art: check the Terraform Registry for an existing DCV + Let's Encrypt module before
  standing on this one.

## License

MIT — see [LICENSE](./LICENSE).
