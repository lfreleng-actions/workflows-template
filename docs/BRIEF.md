<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

<!-- markdownlint-disable MD013 -->

# Design Brief: Workflows Template

This document records the design decisions behind `workflows-template`:
the generic, language-agnostic starting point for reusable-workflow
repositories in the `lfreleng-actions` organisation.

## Goal

Provide the canonical skeleton that new reusable-workflow repositories
(`go-workflows`, `node-workflows`, and future language repos) copy as
their first commit, so every language repo inherits the same proven
pipeline shape, security posture and Gerrit integration by default.
`python-workflows` is the language-specific reference implementation of
the patterns carried here.

The template deliberately carries **skeletons and patterns, not a real
pipeline**: language-specific steps are `# TEMPLATE:`-marked placeholder
steps that instantiators replace with real actions.

## Why a template repository?

- The generic parts of the LF pipeline (job graph, harden-runner
  wiring, dual checkout, Gerrit validation, SBOM/Grype chain, release
  plumbing) are identical across languages; re-deriving them per repo
  invites drift and security regressions.
- A template that passes its own linting, self-test and a zero-finding
  zizmor audit gives each new language repo a verified-secure baseline
  rather than a blank page.
- Divergence then stays where it belongs: in the language-specific
  build/test/audit/SBOM/publish actions.

## What is generic vs placeholder

Generic (transfers verbatim, do NOT rewrite when instantiating):

- `gerrit-validate` — root job validating the Gerrit input contract;
  always runs (only the step is conditional) so `needs:` chains never
  get skip-propagated.
- `repository-metadata` — informational job, runs in parallel.
- Harden-runner triple in every job (block-mode allow-list load +
  harden-runner block, or harden-runner audit), fail-secure: anything
  other than `audit` means block.
- Dual checkout switch (`checkout-gerrit-change-action` when
  `gerrit_refspec` set, `actions/checkout` otherwise).
- The Grype job: downloads the `sbom-files` artifact, scans
  `sbom:sbom-cyclonedx.json`, honours `grype_fail_on`,
  `grype_permit_fail` and the `NO_BLOCK_AUDIT_FAIL` repository
  variable (exit code 2 = findings, soft-failable; other non-zero =
  tool failure).
- Release plumbing on Model A: `tag-validate` (semver, signed,
  reject-development, ensure-draft-release), `attach-artefacts`
  (`release-assets-action`), `promote-release`
  (`draft-release-promote-action` + idempotency check).
- Release-file detection on Model B (`check-release`): `git diff-tree`
  against `releases/` in the merged commit, safe `version:` extraction
  with a character-class guard before values reach `$GITHUB_OUTPUT`.

Placeholder (`# TEMPLATE:` marked, replaced when instantiating):

- Build steps (produce a trivial `dist/template-artefact.txt` and emit
  `artefact_name`/`artefact_path` outputs to exercise the plumbing).
- Test and audit steps (demonstrate the `*_permit_fail`/NO_BLOCK
  soft-fail wiring).
- SBOM generation (writes a minimal VALID empty CycloneDX JSON so the
  downstream Grype job stays fully functional).
- Version resolution on Model B (the `version.properties` parse
  pattern — parsed, never `source`d).
- Credential loading and registry publish steps on Model B.
- Build provenance attestation on Model A (commented
  `actions/attest-build-provenance` example; attesting the trivial
  placeholder artefact provides no value).

## The three skeletons and their contracts

| Skeleton | Model | Contract |
| --- | --- | --- |
| `build-test.yaml` | PR verification | `build -> { tests \| audit \| sbom -> grype }`; parallel fan-out so every failure surfaces |
| `build-test-release.yaml` | Model A (tag-driven) | `tag-validate -> build -> { audit \| sbom -> grype } -> tests -> attach-artefacts -> promote-release`; gating inversion (audits gate tests); workflow output `tag` |
| `merge.yaml` | Model B (merge-driven) | `{ resolve-version \| build } -> snapshot-publish`; `check-release -> release-publish` when a release file merged; optional `OP_SERVICE_ACCOUNT_TOKEN`/`VAULT_MAPPING_JSON` secrets |

Shared `workflow_call` conventions:

- Workflow `name:` prefixed `[R]`.
- All inputs `required: false` with sensible defaults (the "curated
  middle" input surface); lowercase snake_case names (`GERRIT_*`
  UPPERCASE names are reserved for the dispatch inputs on caller
  workflows).
- `repository` + `ref` inputs on every workflow so the self-test can
  run against fixture repos.
- Four Gerrit inputs (`gerrit_refspec`, `gerrit_project`,
  `gerrit_branch`, `gerrit_url`) with `vars.GERRIT_URL` fallback.
- Top-level `permissions: {}`; minimal per-job grants with explanatory
  comments on anything beyond `contents: read`; `timeout-minutes` on
  every job; every `uses:` pinned to a full commit SHA with a
  `# vX.Y.Z` comment.
- Never interpolate `${{ }}` expressions into `run:` blocks — all
  dynamic values are env-mediated (zizmor template-injection).
- `persist-credentials: false` on every `actions/checkout`.

## Dual release-model rationale

The organisation must support both release mechanisms flexibly
(template-level requirement, not a per-language afterthought):

- **Model A (tag-driven)**: version from a validated, signed semver
  tag; GitHub release with attached, attested artefacts; optional
  registry publication. Canonical for GitHub-native projects and Gerrit
  projects whose tags replicate to the mirror. Release callers are
  tag-push triggered ONLY — there is no Gerrit change context on a tag,
  so no votes are cast and the Gerrit/GitHub caller pair is
  near-identical.
- **Model B (merge-driven)**: every merge publishes a snapshot; a
  committed `releases/*.yaml` file triggers a release. Canonical for
  Jenkins-heritage LF/Gerrit projects publishing to Nexus (the
  production-proven ONAP flow).

Rather than two parallel stacks, the version source is factored out: a
resolve-version stage (Model B) and tag validation (Model A) feed
otherwise-identical build/publish jobs, so consumers can adopt either
model — or migrate from B to A — without behavioural divergence.

Signing/attestations (Model A): the `attestations` and `sigstore_sign`
inputs (default `true`) follow the python-workflows precedent, with
`id-token: write` + `attestations: write` granted only to the build
job. Keyless (OIDC) signing only. The inputs stay toggleable because
some Gerrit-mirrored or air-gapped consumers cannot reach the public
Sigstore infrastructure. Snapshot publishes (Model B) skip
release-grade signing by default.

## Central allow-list policy

Block-mode egress is the default and the production posture. The
allow-list is not maintained per-repo: `harden-runner-block-action`
retrieves the central org allow-list from the `lfreleng-actions/.github`
repository, pinned in the `harden_runner_allowlist` input default
(v0.4.1 at the time of writing). When new work talks to new endpoints,
raise a PR against `lfreleng-actions/.github` adding the hosts/ports,
get it released, then pin the new tag's commit SHA — the allow-list
update is a sequenced prerequisite of any change introducing new
egress. `audit` mode exists for diagnosis/bring-up only and is the
mechanism for discovering the endpoint list to submit.

## Self-test approach

`testing.yaml` calls the build-test skeleton **by local path** (so it
always validates the current branch) against fixture repositories of
different languages, fanned out via a `fail-fast: false` matrix. The
placeholder steps are language-agnostic, so the matrix passes for any
fixture — by design: the template self-test validates the generic
scaffolding (job graph, harden-runner, dual checkout, artifact
plumbing, SBOM/Grype chain), not a language pipeline.

The release and merge skeletons are not self-tested: they need a signed
semver tag-push or merged-commit context (and would create releases or
exercise publish legs), neither of which is available or safe on a pull
request. Instantiating repos validate them through their own
release/merge cycles.

## Instantiation checklist

1. Copy the template over the new repo's boilerplate as the first
   commit of the implementation PR series.
2. Replace every `# TEMPLATE:` placeholder with real language actions,
   keeping step ids and job outputs intact.
3. Wire real fixture/consumer repos into `testing.yaml`.
4. Rename all slugs (README badges/links, examples `uses:` paths).
5. Follow the central allow-list process for any new endpoints the
   language toolchain contacts.
6. Keep both release models working; extend inputs on demand (curated
   middle).
7. Update `docs/BRIEF.md` with the language repo's own decisions.
8. Verify: pre-commit hooks green, zizmor (auditor persona) reports
   zero findings, self-test passes.

## Repo hygiene kept from actions-template

`.pre-commit-config.yaml` (frozen-SHA hook pins), `.yamllint`,
`.gitlint` (Conventional Commits + DCO), `.editorconfig`,
`dependabot.yml` (weekly, cooldown 7 days), REUSE/SPDX layout,
`SECURITY.md`, `release-drafter.yaml`, `openssf-scorecard.yaml`,
`clear-action-cache.yaml`, and the newer `tag-push.yaml` generation
(harden-runner block + tag-validate-action v1.0.4).
