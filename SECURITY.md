# Security Policy

VirtIOForge runs as administrator, changes Windows images and installs drivers and software. That makes
it security-sensitive by nature, and reports are taken seriously.

## Reporting a vulnerability

**Please report vulnerabilities privately; do not open a public issue, pull request, or discussion for a
security problem.**

Use **GitHub's private vulnerability reporting**:

1. Go to the repository's **Security** tab ->
   **[Report a vulnerability](https://github.com/motwok/VirtIOForge4Windows/security/advisories/new)**.
2. Describe the issue with enough detail to reproduce and assess it.

This keeps the report private between you and the maintainer and integrates with GitHub Security
Advisories for a coordinated fix and disclosure.

### What to include

- A clear description of the vulnerability and its **impact**.
- **Steps to reproduce** (or a proof of concept).
- Affected **version** of VirtIOForge, the **Windows version** and the **virtio-win version** used.
- Any suggested mitigation, if you have one.

## What to expect

This is a single-maintainer project, so responses are best-effort rather than bound to a fixed SLA. You
can expect an acknowledgement of your report, an assessment, and, for confirmed issues, a coordinated fix
and disclosure. Credit is given to reporters who want it.

Please give a reasonable amount of time for a fix before any public disclosure.

## Supported versions

Only the **latest release** receives security fixes. Older releases are not patched; please update to
the newest one.

| Version | Supported |
|---|---|
| Latest release | yes |
| Older releases | no |

## Scope

VirtIOForge deliberately does things that can look alarming but are by design:

- it runs **as administrator** and downloads the virtio-win ISO from the Fedora project, unless you
  provide one,
- it adds the virtio-win drivers to **copies** of Windows images with DISM and builds a new ISO from them,
- it installs the virtio-win drivers into the running Windows with `pnputil` and updates its WinRE,
- it installs the virtio-win guest tools silently, also during Windows Setup.

These documented behaviors are **not** vulnerabilities on their own. Genuine security issues include, for
example: installing a driver or program that does not come from the selected virtio-win ISO; changing the
original Windows media; writing outside the documented locations; or a way for a non-administrator to
make VirtIOForge install or run something.
