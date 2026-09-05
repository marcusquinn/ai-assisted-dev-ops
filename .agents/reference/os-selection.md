<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Contextual operating-system selection

These are **opinionated starting points**, not mandatory choices or a vendor
support matrix. Use them when choosing a desktop, VPS, bare-metal host, container
base, development environment, or security workstation. Existing working systems
do not need migration merely to match a preference. aidevops's own supported
platforms remain defined separately in [platform support](platform-support.md).
An Arch/Ubuntu/RHEL derivative is not automatically a verified aidevops platform.

## Decision order

1. Establish workload, users, hardware, budget, support expectations, operating
   burden, existing estate, data location, and any governance/licensing priorities.
2. Apply hard constraints first: vendor-supported **OS release and architecture**,
   CPU features, drivers, required proprietary applications, and security policy.
3. Distinguish host OS, container userspace, VM guest, and development shell. They
   need not match. A container supplies userspace, not a different host kernel or
   CPU architecture; emulation is an explicit performance/support trade-off.
4. Check provider **ready-made images** separately from manual installability.
   Confirm image ID, version, architecture, region, capacity, and maintenance
   status in the provider console/API before provisioning. A marketplace image
   is a third dimension: its bundled application may support less than the OS.
5. Use the preferences below among compatible options. Explain departures rather
   than forcing a preferred distro into an unsupported deployment.
6. Record the exact choice and evidence in the deployment plan, including update
   ownership, backups/restore, monitoring, and rollback. Obtain separate approval
   for billing, repartitioning/reinstallation, or replacing a user's daily OS.

## Opinionated starting points

| Context | Preferred starting point | Conditions and trade-offs |
|---------|--------------------------|---------------------------|
| Modern local desktop/laptop; developers, friends, family | **Omarchy** on supported hardware | An opinionated desktop preference, not “best for everyone”. Verify current image/CPU, graphics, Wi-Fi, suspend, accessibility, essential apps, and recovery. Confirm users want its workflow and have help with rolling-release maintenance; do not assume ARM/Apple Silicon support |
| Windows-like corporate desktop familiarity | **Kubuntu** | KDE desktop familiarity can reduce retraining, but is not Windows application, Microsoft management, or hardware compatibility. Prefer a supported release; check VPN, MDM, smartcards, office/document workflows, accessibility, and support ownership |
| Cost-conscious compatible VPS workloads | **Hetzner ARM (CAX)** plus a workload-appropriate OS | Price/performance preference, not a benchmark result. Check actual CAX capacity/region and ARM64 images, runtime/binary support, containers, agents, and native extensions; use x86 when any required component needs it |
| Minimal targeted Docker/container, compatible binary-only, or appliance workloads | **Alpine Linux** | Strong fit when its small userspace and operating model match the task. “Binary-only” means verified musl-compatible or suitably static binaries, not arbitrary vendor Linux binaries. Check init/service integration and kernel/device requirements separately |
| General-purpose VPS or bare metal | **Rocky Linux** | Prefer its enterprise-oriented lifecycle where application vendors support the exact major release and architecture. Verify repositories, kernel/driver needs, Docker packaging, SELinux, and operational expertise |
| Self-hosted Coolify | **Rocky Linux**, when the target release/install path is supported | Coolify documents Rocky and ARM64 support, but quick-installer guidance is narrower; see the evidence below. Pick a supported alternative when a vendor-supported image or simpler recovery is more valuable |
| Cloudron host | **Ubuntu**, exactly as Cloudron requires | A vendor requirement, not an overrideable distro preference. Use the currently documented fresh x64 host; Cloudron's own containers do not mean Cloudron itself can be installed in Docker/LXC or on ARM |
| CloudLinux / TuxCare / cPanel-oriented estate | **AlmaLinux**, subject to the actual product matrix | Ecosystem affinity is a preference, not a compatibility contract. AlmaLinux, CloudLinux OS, TuxCare services, and cPanel are distinct products with separate versions, architectures, licences, conversions, and support terms |
| Reproducible/disposable scripted dev, CI, or shared team environments | **NixOS** (or Nix environments on a supported existing host) | Pin inputs and document rebuild/rollback. A dev shell is not full-OS reproducibility; keep secrets and mutable state separate. Non-FHS paths, dynamic binaries, daemon assumptions, learning curve, and build-cache availability can add work |
| Security/privacy-oriented workstation | **Parrot OS** | Verify edition, supported hardware/image, and workflow. A security-tool collection does not automatically provide anonymity, hardened isolation, or a maintenance-free daily desktop |
| Authorised penetration testing | **Kali Linux in an isolated VM** | Obtain target-owner authorisation and scope. Use snapshots, appropriate guest architecture, controlled networking, and deliberate device passthrough; avoid shared personal credentials/folders. A VM is not complete containment |
| Amnesic privacy sessions | **Tails** | A specialised live-session choice, not an always-on aidevops/CI/server host. Verify current hardware requirements, boot path, Tor suitability, and persistence settings; do not promise anonymity or zero traces on every machine |

### Alpine and binaries

Alpine uses **musl**, while many externally supplied Linux binaries and native
extensions target **glibc**. “Linux amd64/arm64” alone is insufficient evidence.
Prefer a vendor-provided musl build, an appropriate static build, or a supported
glibc-based userspace. Compatibility shims are not universal replacements for a
vendor-supported runtime. Glibc containers may run on an Alpine host because they
supply their own userspace, but still share the host kernel and CPU architecture.
Also distinguish Alpine's usual OpenRC setup from documentation that assumes
systemd; do not paste systemd-only service instructions without adaptation.

### ARM and ready-made images

For an ARM deployment, verify the host and every workload layer: provider instance,
OS image, container manifests/build targets, runtime, native modules, database
extensions, backup/security/monitoring agents, and proprietary binaries. A
multi-architecture tag is useful only if the selected release actually includes
`linux/arm64`. Check restore/migration compatibility before treating x86 and ARM
instances as interchangeable.

Do not advertise Alpine, Rocky, AlmaLinux, or NixOS as a ready-made provider image
without observing that exact current catalogue entry. If absent, explicitly choose
between a supported stock alternative and an approved manual/custom-image route,
including recovery access, rebuild cost, and update ownership.

## Verified vendor constraints

Checked **2026-09-05**. These observations expire; consult the linked source before
buying hardware, creating servers, or issuing installation commands.

| Source | Observed fact | Recommendation boundary |
|--------|---------------|-------------------------|
| [Coolify installation](https://coolify.io/docs/get-started/installation) | Lists Rocky/AlmaLinux, Alpine, and other Linux families; AMD64 and ARM64 architectures. The same page limits its automatic-install guidance to Ubuntu LTS and notes AlmaLinux may need Docker preinstallation | Do not translate the broad OS list into “the quick installer is supported everywhere”. Resolve the target version/install-path guidance, use its documented manual route where appropriate, and verify all app images separately |
| [Hetzner cost-optimised cloud](https://www.hetzner.com/cloud/cost-optimized/) | Lists CAX Ampere/Arm64 instance types; availability is location/capacity-dependent | Confirm the actual allocatable type, price, location, and architecture-specific image at provisioning time; a catalogue is not a capacity reservation |
| [Hetzner Coolify App image](https://docs.hetzner.com/cloud/apps/list/coolify) | Documents an Ubuntu 24.04-based `coolify` image with a CPX example | Not evidence for a ready-made Rocky image or CAX/ARM Coolify image; inspect the chosen image rather than extrapolating |
| [Cloudron installation](https://docs.cloudron.io/installation/) | Currently calls for fresh Ubuntu Resolute **26.04 x64**, at least 2 GB RAM/20 GB disk, and public HTTP/HTTPS reachability; excludes ARM, LXC, Docker, and OpenVZ installations | Choose a supported x64 host, not Hetzner ARM; recheck the current Ubuntu requirement rather than reusing an old 22.04/24.04 recipe |

No specific cPanel/CloudLinux/TuxCare OS major version or ARM support is certified
by this guide. Before choosing AlmaLinux for one of those products, retrieve that
product's current system requirements, licensing and migration documentation;
record the exact supported combination or mark it unknown. Sponsorship or shared
history does not establish interchangeability or a support entitlement.

Desktop and specialised-OS rows above express selection preferences and checks,
not a claim that each distribution was installed, hardware-tested, or verified by
aidevops on this date.

## Governance, ethics, licensing, and lock-in

Respect the user's stated priorities, including unwanted political/governance
affiliations, but distinguish preference from evidence. If an affiliation affects
a decision, identify the current legal entity, governance/sponsor relationship,
and dated source; do not infer a project's politics from its distro family or a
single contributor. No distribution is certified here as ethically neutral.

Distribution names are not one licence. Check the licences of the actual kernel,
packages, firmware, drivers, bundled applications, management platform, and
commercial support/services, including redistribution or network-service duties
where relevant. “Open source”, “community”, or “self-hosted” does not mean every
feature is free, terms cannot change, or there is no legal/compliance risk.

Compare practical exit costs: portable data, documented rebuilds, restore tests,
identity/DNS dependencies, proprietary management features, and available support.
Prefer open and maintainable options when they satisfy the workload, not at the
expense of a required vendor support contract or essential accessibility feature.

## Routing

- Start provider/platform decisions with [recommendations](../aidevops/recommendations.md)
  and [hosting comparison](../tools/deployment/hosting-comparison.md).
- Check [Hetzner](../services/hosting/hetzner.md),
  [Coolify](../tools/deployment/coolify.md), or
  [Cloudron](../services/hosting/cloudron.md) before platform-specific operations.
- Networking is a separate decision: [NetBird](../services/networking/netbird.md)
  provides a private mesh; [optional GitHub ingress](github-webhook-onboarding.md)
  is not an OS prerequisite or mandatory aidevops component.
