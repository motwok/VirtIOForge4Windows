# Releasing VirtIOForge

VirtIOForge is released on GitHub with one asset per release:

| Asset | Content |
|---|---|
| `VirtIOForge-X.Y.Z-scripts.zip` | the scripts with README, LICENSE and NOTICE |

Scripts in `tools/` are not part of the asset; they are only available from the repository. Changes to
them alone do not produce a release.

Versions follow [Semantic Versioning](https://semver.org) (0.x before 1.0). **Every merge into
`master` that changes the product is a release**, that is changes to `src` (scripts) or `build`
(packaging script). Merges that only touch documentation, tests, `tools` or CI build nothing new; they
are listed in the next real release. There is no manual release step: merging a pull request is the
approval. As long as `src/scripts` does not exist, nothing is released.

No Windows or virtio-win files are part of any release.

## Workflows at a glance

| Workflow | File | Trigger | What it does |
|---|---|---|---|
| **Build** | `build.yml` | PR to `master`, push to `master` | Lint (parser, ASCII check, PSScriptAnalyzer), tests (Pester, 100 % coverage) and the package build. On `master`, if the product changed since the last release, it builds the release asset with the new version, publishes the release `vX.Y.Z` and attaches the asset. |
| **Release Drafter** | `release-drafter.yml` | PR events, push to `master` | Labels pull requests from their Conventional Commit titles and keeps the release notes of the next version up to date. |

All actions are pinned to a commit SHA (with the version as a comment). There are no scheduled runs and
no automatic dependency updates: whenever a workflow is changed, its actions are raised to the latest
release by hand.

## Release flow

```mermaid
flowchart LR
  O[maintainer merges a PR] --> M[master]
  M --> C{product files<br/>changed since last release?}
  C -- "no (docs, CI)" --> Q[no release,<br/>listed in the next one]
  C -- yes --> B[Build workflow:<br/>lint, tests, package]
  B --> T{checks green,<br/>archive complete,<br/>no binaries inside}
  T -- ok --> R[publish release vX.Y.Z]
  R --> A[attach ZIP]
  T -- fails --> N[no release, nothing published,<br/>GitHub notifies the maintainer]
```

1. A change is merged into `master` through a PR (feature branch, squash merge).
2. The Build workflow runs lint and tests and builds the package.
3. The **package check** verifies that the ZIP contains every product script, no repo-only script and
   no binary (no `.sys`, `.cat`, `.inf`, `.cab`, images, installers or executables). If any check
   fails, there is no release.
4. On success the release `vX.Y.Z` is published with notes generated from the merged pull requests and
   the asset `VirtIOForge-X.Y.Z-scripts.zip` is attached. Tag, release and asset always belong to the
   same commit.

## Version numbers

The next version follows from the labels of the merged pull requests:

| Labels | Version step |
|---|---|
| `breaking`, `major` | major |
| `feature`, `enhancement` | minor |
| anything else (`fix`, `docs`, `chore`, no label) | patch |

Labels are set automatically from Conventional Commit titles (`feat:`, `fix:`, `docs:`, ...).

## Rollback

Releases are never rebuilt. Use the asset of an earlier release instead.
