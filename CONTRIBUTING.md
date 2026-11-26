# Contributing to VirtIOForge

Thanks for your interest in VirtIOForge!

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md); please be respectful.

> **Security issue?** Do **not** open a public issue; report it privately, see [SECURITY.md](SECURITY.md).

## Ways to contribute

- **Bug reports**: [open an issue](https://github.com/motwok/VirtIOForge4Windows/issues)
- **Feature requests**: [open an issue](https://github.com/motwok/VirtIOForge4Windows/issues)
- **Pull requests** are welcome, see below.

Ideas, reproductions and well-described problems are genuinely valuable too.

## Repository layout

| Path | Content |
|---|---|
| `src/scripts/` | the scripts and their shared module; shipped in the ZIP |
| `tools/` | repo-only scripts; never shipped |
| `tests/` | Pester tests; `tests/Invoke-Tests.ps1` runs them as the Build workflow does (one process per file, merged coverage, 100 % required) |
| `build/` | packaging script used by the Build workflow |
| `docs/` | user documentation |
| `.github/` | workflows, issue and PR templates, release notes configuration |

## Pull requests

VirtIOForge runs as administrator, changes Windows images and installs drivers, including the storage
driver of the system disk. A mistake can leave a machine or an installation medium unbootable, so every
change is reviewed carefully before it is merged. To make that easy:

- For anything larger than a small fix, open an issue first so the approach can be agreed on.
- Keep a pull request focused on one change. Work on a branch of your fork and target `master`.
- Use a Conventional Commit style title, for example `feat: ...`, `fix: ...`, `docs: ...`.
- Write code, comments and documentation in English.
- Scripts must run with what ships with Windows: the ISO scripts on Windows PowerShell 5.1 with
  Desktop Experience, the scripts for a running Windows on PowerShell 2.0 (Windows 7 / Server 2008
  R2), also on Server Core.
  No Windows ADK, no external modules or tools; anything else needs to be agreed in an issue first.
- Never include Windows or virtio-win files (drivers, catalogs, installers, images) in a pull request.
- Do not put raw non-ASCII characters into source code; write them as escape sequences.
- Diagrams in Markdown are Mermaid, not ASCII art.
- Test your change in a virtual machine with a snapshot, never first on a machine you need. Describe
  in the pull request what you tested (Windows version and edition, virtio-win version, hypervisor).

By submitting a pull request you agree that your contribution is licensed under the
**GNU AGPL v3** (see [LICENSE](LICENSE)).

## Writing a good bug report

Please include:

- **What happened** and **what you expected**.
- The **VirtIOForge version** and the **mode** (prepare an ISO, add drivers, update drivers).
- The **virtio-win version** and where it came from.
- The **Windows version, build and edition** of the ISO (`Get-WindowsImage`) or the running Windows
  (`winver`).
- The **hypervisor**: QEMU/libvirt version, machine type, disk bus.
- The relevant part of the **output or log**.
- **Steps to reproduce**, if you can; even rough ones help.

Remove host names, IP addresses or other details you do not want to make public before posting.

## Feature requests

Describe the problem you're trying to solve, not just a proposed solution; it helps find the best fit.
Note that not every request will be implemented; VirtIOForge intentionally stays small and focused.

## Forking

VirtIOForge is licensed under the **GNU AGPL v3** (see [LICENSE](LICENSE)). You are of course free to
fork and modify it under those terms.

## Support Me

If VirtIOForge helps you, you can support it: [Buy Me a Coffee](https://ko-fi.com/motwok)
