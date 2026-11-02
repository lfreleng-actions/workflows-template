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

All three take the same five `harden_runner_*` inputs, which
[Egress allow-list](#egress-allow-list) describes.

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

## GitHub CLI telemetry

The release skeleton shells out to `gh`, which posts usage events to
`cafe.github.com` unless told otherwise. The reusable workflow and the
`build-test-release` caller examples both set:

```yaml
env:
  GH_TELEMETRY: 'false'
```

Three reasons this matters here:

- No step needs that endpoint. The GitHub CLI sends telemetry from a
  separate hidden `gh send-telemetry` subcommand on a two-second
  timeout, so disabling it leaves every `gh` command working as normal.
- The organisation runs harden-runner under `egress-policy: block`, so
  an unnecessary call shows up as a blocked connection. That noise
  competes with genuine findings in the run insights.
- Adding `cafe.github.com` to the shared allow-list instead would widen
  egress across every repository in the organisation to carry
  analytics. Disabling the call at source keeps that policy tight.

`GH_TELEMETRY` takes precedence over `DO_NOT_TRACK`, so this one
variable covers both. A workflow-level `env:` block does not cross the
`workflow_call` boundary, which is why the reusable workflow and the
caller examples each set it.

Any caller-side job stacked after the release job — a registry publish
step, for instance — inherits the value from the caller workflow.

## Egress allow-list

Every job in the three skeletons loads its egress allow-list through
[`harden-runner-block-action`](https://github.com/lfreleng-actions/harden-runner-block-action)
and then runs harden-runner on it. The skeletons take the same five
inputs for this and pass them to every block-action step they run.
A repository instantiated from this template keeps the whole set:
every `*-workflows` repository in the organisation exposes it, so a
caller can move between them without relearning the inputs.

<!-- markdownlint-disable MD013 -->

| Input                                  | Type      | Default                       | Passed to block-action as                                    |
| -------------------------------------- | --------- | ----------------------------- | ------------------------------------------------------------ |
| `harden_runner_egress`                 | `string`  | `block`                       | harden-runner's `egress-policy`                              |
| `harden_runner_allowlist`              | `string`  | the organisation list, pinned | `config`                                                     |
| `harden_runner_supplemental_allowlist` | `string`  | `''`                          | `supplemental_config`, with `supplemental_required` when set |
| `harden_runner_supplemental_unpinned`  | `boolean` | `false`                       | `supplemental_unpinned`                                      |
| `harden_runner_extra_endpoints`        | `string`  | `''`                          | `extra_endpoints`                                            |

<!-- markdownlint-enable MD013 -->

[`tests/test-harden-runner-inputs.sh`](tests/test-harden-runner-inputs.sh)
fails when a workflow drops one of these inputs, changes its type,
default or description, passes it in another form, or lets a
block-action step carry on past a missing named list. It names
nothing specific to this repository, so an instantiated repository
keeps it unchanged; the `harden-runner-inputs` hook in
`.pre-commit-config.yaml` runs it whenever a workflow changes.

### A supplemental list of your own organisation

The organisation list covers the hosts every project needs. A project
that reaches hosts of its own, such as ONAP's `registry.nordix.org`,
names a supplemental list, which the action merges with the baseline
in the same coordinate grammar. An organisation that keeps its list in
its own `.github` repository can follow it at the default branch
rather than a pinned commit, so a host added there takes effect on the
next run without a pin bump in every caller:

```yaml
    with:
      harden_runner_supplemental_allowlist: 'onap//'
      harden_runner_supplemental_unpinned: true
```

`onap//` names the `onap` organisation's `.github` repository with no
file path, so the action searches that repository, at its default
branch, for the organisation's list. From an `onap` repository it
tries these files in order, and the first that exists wins:

1. `.github/harden-runner/onap/allow_list.txt`, the organisation's
   own list;
2. `.github/harden-runner/allow_list.txt`, the repository-wide
   default;
3. `.github/harden-runner/<org>/allow_list.txt`, when a single
   organisation directory carries that file (the sole-org fallback;
   two or more such directories match nothing).

Putting the list at the first path keeps the search unambiguous. When
none of the three exists, the job fails, because the workflows require
a supplemental list a caller names (see
[A missing list fails the job](#a-missing-list-fails-the-job)). The
*Search / fallback chain* section of the action's README describes the
search in full.

The action allows an unpinned list from the caller's own
organisation alone, so `onap//` unpinned works from an `onap`
repository and nowhere else.

### A list in another organisation

A supplemental list from any other organisation must carry a pin,
`<org>//<path>@<commit SHA>`, and `harden_runner_supplemental_unpinned`
stays `false`. The action refuses to follow another organisation's
default branch: a push there would otherwise change what your runners
may reach.

### A missing list fails the job

Whenever a caller names `harden_runner_supplemental_allowlist`, the
workflows also pass `supplemental_required: 'true'`. A caller naming a
list depends on it, so a list the action cannot find fails the job at
the block-action step, before anything runs, rather than at the first
blocked connection. This holds under `harden_runner_egress: audit`
too: no block-action step in the skeletons tolerates its own failure.

### Inline endpoints, a short-term fix

`harden_runner_extra_endpoints` adds `host:port` endpoints to the
allow-list inline, for example while a supplemental list waits for a
review:

```yaml
    with:
      harden_runner_extra_endpoints: 'registry.nordix.org:443'
```

Treat it as a stopgap. Endpoints passed inline live in one caller, so
every other caller that needs the host fails until it copies them;
the lasting fix is to add the host to the organisation's list or to a
supplemental list. The action validates the endpoints before it
fetches anything, and reports any the list already carries as
redundant. The *Inline extra endpoints* section of the action's README
gives the accepted format.

### Audit trail for an unpinned list

An unpinned list can change between two runs of the same commit.
`harden-runner-block-action` records which list it read and the
commit it resolved in its `supplemental_source` and `supplemental_sha`
outputs, which together say which revision of the list a given run
allowed.

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
   your repository name).
4. When new work talks to new/external endpoints, follow the central
   allow-list process: raise a PR against `lfreleng-actions/.github`
   adding the hosts/ports to the org harden-runner allow-list, get it
   released, then pin the new tag's commit SHA in the
   `harden_runner_allowlist` defaults. Hosts that one project alone
   needs belong in that project's supplemental list, and
   `harden_runner_extra_endpoints` covers the wait for either change
   to land; see [Egress allow-list](#egress-allow-list). Reserve
   `harden_runner_egress: 'audit'` for bring-up/endpoint discovery.
   Keep the five `harden_runner_*` inputs and
   `tests/test-harden-runner-inputs.sh` as they are, so the check
   stays the same across the organisation.
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
different languages, calling it by self-repository path
(`uses: $/.github/workflows/build-test.yaml`), which resolves this
repository at the commit already running. The placeholder
steps are language-agnostic, so the self-test validates the generic
scaffolding regardless of project language — which is the point of this
repository. The legs also pass a same-organisation supplemental list,
unpinned, and an inline endpoint the organisation list already
carries, so the allow-list inputs run on every pull request without
granting anything new.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/workflows-template/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/workflows-template/main.svg
