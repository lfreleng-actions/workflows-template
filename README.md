<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# 🔧 Workflows Template

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/workflows-template) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![pre-commit.ci status badge]][pre-commit.ci results page] [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lfreleng-actions/workflows-template/badge)](https://scorecard.dev/viewer/?uri=github.com/lfreleng-actions/workflows-template)
<!-- prettier-ignore-end -->

The generic, language-agnostic starting point for reusable-workflow
repositories in this GitHub organisation (`go-workflows`,
`node-workflows`, …). It carries the canonical Linux Foundation pipeline
**skeletons and patterns** — not a real pipeline: language-specific
steps are `# TEMPLATE:`-marked placeholders that instantiators
replace with real actions. `python-workflows` is the language-specific
reference implementation of these patterns.

## Skeleton reusable workflows

<!-- markdownlint-disable MD013 -->

| Workflow | Purpose | Trigger style |
| -------- | ------- | ------------- |
| `.github/workflows/build-test.yaml` | Build, test, audit, SBOM and Grype scan skeleton | Pull request |
| `.github/workflows/build-test-release.yaml` | Release skeleton (Model A, tag-driven): tag validation, release artefact attachment and draft-release promotion | Tag push |
| `.github/workflows/merge.yaml` | Merge/publish skeleton (Model B, merge-driven): snapshot publish on every merge plus `releases/` file-triggered release publish | Merge / push to main |

<!-- markdownlint-enable MD013 -->

Each pipeline runs a `repository-metadata` job in parallel (an
informational step that does not gate the build). After `build`, the
test, audit and SBOM/Grype branches run in parallel - none gates
another, so a pull request surfaces every failure at once (jobs in
`{ }` run concurrently; `->` denotes sequence):

```text
build -> { tests | audit | sbom -> grype }
```

The release skeleton wraps this with `tag-validate` up front and a
release-promotion chain at the end. It also **defers `tests` until
`audit` and `grype` have both passed**, so a failing audit skips the
test suite and never reaches release promotion:

```text
tag-validate -> build -> { audit | sbom -> grype } -> tests
  -> attach-artefacts -> promote-release
```

The merge skeleton implements the Jenkins-heritage LF/Gerrit model:

```text
{ resolve-version | build } -> snapshot-publish
check-release -> release-publish (when a release file merged)
```

## Dual release models

Repositories built from this template support **both** release models
so consumers can adopt either — or migrate between them — without
divergent behaviour:

- **Model A — tag-driven** (`build-test-release.yaml`): the version
  comes from a validated, signed semver tag; a GitHub release carries
  the attested artefacts. Canonical for GitHub-native projects and
  Gerrit projects whose tags replicate to the mirror.
- **Model B — merge-driven** (`merge.yaml`): every merge publishes a
  snapshot (version from committed metadata such as
  `version.properties` → `X.Y.Z-SNAPSHOT`); a release triggers from a
  committed release file (`releases/*.yaml`) in the merged change.
  Canonical for Jenkins-heritage LF/Gerrit projects publishing to
  Nexus.

## Usage

Copy a template from [`examples/`](examples/) into your project's
`.github/workflows/` directory and replace the placeholder `uses:` SHA
with a pinned release. Each workflow ships in two forms:

- `github.yaml` — a plain GitHub-native caller (pull-request, tag-push
  or push-to-main triggered).
- `gerrit.yaml` — a Gerrit-wrapped caller for projects where Gerrit is
  the source of truth (SCM), integrating with `gerrit_to_platform`
  voting/commenting.

```text
examples/
  build-test/          { github.yaml, gerrit.yaml }
  build-test-release/  { github.yaml, gerrit.yaml }
  merge/               { github.yaml, gerrit.yaml }
```

All inputs are optional and default to the canonical behaviour; see the
`inputs:` block at the top of each workflow file for the full,
documented list.

## How to instantiate this template

When creating a new `<lang>-workflows` repository from this template:

1. Replace every `# TEMPLATE:` placeholder step in the three skeleton
   workflows with the real language build/test/audit/SBOM/publish
   actions, keeping the step ids and job outputs intact. The
   surrounding job graph, harden-runner wiring, dual checkout, Gerrit
   validation and Grype scan are generic — keep them as-is.
2. Wire real fixture/consumer repositories into
   [`testing.yaml`](.github/workflows/testing.yaml) so the workflows
   run end-to-end against real projects on every pull request.
3. Update this README and all badge/link slugs (`workflows-template` →
   your repository name), and record your design decisions in
   [`docs/BRIEF.md`](docs/BRIEF.md).
4. When new work talks to new/external endpoints, follow the central
   allow-list process: raise a PR against `lfreleng-actions/.github`
   adding the hosts/ports to the org harden-runner allow-list, get it
   released, then pin the new tag's commit SHA in the
   `harden_runner_allowlist` defaults. Reserve `harden_runner_egress:
   'audit'` for bring-up/endpoint discovery.
5. Keep support for **both** release models (Model A and Model B),
   factoring version resolution so the two share building blocks.
6. Update the `examples/` callers to reference your repository and its
   real input surface.

## Gerrit support

The reusable workflows are Gerrit-aware: when a caller sets the
`gerrit_refspec` input they check out the change with
`checkout-gerrit-change-action` instead of `actions/checkout`. Vote and
comment casting live in the `gerrit.yaml` caller examples (clear vote →
run → report vote for verify; comments without votes for merge), never
inside the reusable workflows.

## Testing

[`.github/workflows/testing.yaml`](.github/workflows/testing.yaml)
exercises the build-test skeleton against fixture repositories of
different languages by calling it via its local path. The placeholder
steps are language-agnostic, so the self-test validates the generic
scaffolding regardless of project language — which is the point of this
repository.

## Design

See [`docs/BRIEF.md`](docs/BRIEF.md) for the design decisions behind the
template: what stays generic versus placeholder, the three skeleton
contracts, the dual release-model rationale and the instantiation
checklist.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/workflows-template/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/workflows-template/main.svg
