#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Wiring check for the Grype gating policy.
#
# Every reusable (workflow_call) workflow that calls
# lfreleng-actions/grype-scan-action must expose the grype_* policy
# inputs with the organisation's defaults, validate each string input
# in gerrit-validate, and pass each through to the scan. The check runs
# each validation step against valid and invalid values, so a step
# that names an input but accepts anything fails. A verify lane
# (one with grype_gate_when) must also take its dependency-change
# verdict from the repository-metadata job, guarded so that a failed
# or skipped metadata job gates. A release lane gates always. Every
# repository-metadata-action call pins the same release. The detection
# wiring the families retired must not come back: a
# dependency-change-action step, its dependency-change.json sidecar,
# or the scan's dependency-change-manifest input.
#
# It first checks the real workflows, then mutates a copy of one of
# them in each way the check must catch and expects each mutant to
# fail, so a check that silently passes everything fails here too.
#
# Usage: bash tests/test-grype-policy-inputs.sh [<workflows-dir>]
#
# Needs python3 with PyYAML, and bash. The calendar-date cases need
# GNU date ('date' or 'gdate'); without it they are skipped with a
# notice, except under CI=true, where that fails.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workflows="${1:-${repo_root}/.github/workflows}"

if [ ! -d "${workflows}" ]; then
  echo "ERROR: workflows directory not found: ${workflows}" >&2
  exit 1
fi

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "ERROR: python3 cannot import yaml; install PyYAML" >&2
  exit 1
fi

# '-I' keeps the working directory off sys.path.
python3 -I - "${workflows}" <<'PYEOF'
import copy
import functools
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

GRYPE = "lfreleng-actions/grype-scan-action"
# Detection belongs to repository-metadata-action; a workflow calling
# this directly, or carrying its sidecar, has the retired wiring back.
LEGACY_DETECTOR = "lfreleng-actions/dependency-change-action"
LEGACY_SIDECAR = "dependency-change.json"
METADATA = "lfreleng-actions/repository-metadata-action"
# v0.5.1; v0.4.0 was the first release with dependency_change.
METADATA_PIN = "f0e5d2d8dc1154a5d702b75acc551eff6ba072dc"

# name -> (type, default), for every lane that runs the scan.
COMMON = {
    "grype_enabled": ("boolean", True),
    "grype_fail_on": ("string", "medium"),
    "grype_permit_fail": ("boolean", False),
    "grype_bypass_repository": ("string", ""),
    "grype_dependency_policy": ("string", "declared"),
    "grype_transitive_fail_on": ("string", "critical"),
    "grype_only_fixed": ("boolean", True),
}
# Verify lanes only: the release lane always gates.
VERIFY = {
    "grype_gate_when": ("string", "always"),
    "grype_dependency_ecosystems": ("string", ""),
    "grype_dependency_patterns": ("string", ""),
    "grype_remediation_window_days": ("string", ""),
    "grype_remediation_window_start": ("string", ""),
}
# The gerrit-validate step that checks the policy inputs.
VALIDATION_STEP = "Validate Grype policy inputs"
# (input, value, accepted, needs GNU date) cases the validation step
# must decide correctly; every lane also accepts its defaults. Booleans
# are typed by GitHub, and the patterns are left to the detector, whose
# grammar governs, so neither has a case.
COMMON_CASES = [
    ("grype_fail_on", "none", True, False),
    ("grype_fail_on", "Medium", False, False),
    ("grype_bypass_repository", "lfreleng-actions/.github", True, False),
    ("grype_bypass_repository", "lfreleng-actions", False, False),
    ("grype_bypass_repository", "a/b c", False, False),
    ("grype_dependency_policy", "direct", False, False),
    ("grype_transitive_fail_on", "severe", False, False),
]
VERIFY_CASES = [
    ("grype_gate_when", "dependencies-changed", True, False),
    ("grype_gate_when", "dependencies_changed", False, False),
    ("grype_dependency_ecosystems", "node, python ,go", True, False),
    ("grype_dependency_ecosystems", "node,,python", False, False),
    ("grype_dependency_ecosystems", "npm", False, False),
    ("grype_remediation_window_days", "14", True, False),
    ("grype_remediation_window_days", "-1", False, False),
    ("grype_remediation_window_days", "2w", False, False),
    # Year 0000: GNU date takes it, grype-scan-action's parser does not.
    ("grype_remediation_window_start", "0000-01-01", False, False),
    ("grype_remediation_window_start", "05/11/2026", False, False),
    ("grype_remediation_window_start", "2026-11-05", True, True),
    ("grype_remediation_window_start", "0001-01-01", True, True),
    ("grype_remediation_window_start", "2026-02-31", False, True),
    ("grype_remediation_window_start", "2026-13-01", False, True),
]
PASS_THROUGH = {
    "fail-on": "${{ inputs.grype_fail_on }}",
    "dependency-policy": "${{ inputs.grype_dependency_policy }}",
    "transitive-fail-on": "${{ inputs.grype_transitive_fail_on }}",
    "only-fixed": "${{ inputs.grype_only_fixed }}",
    "bypass-repository": "${{ inputs.grype_bypass_repository }}",
}
VERIFY_PASS_THROUGH = {
    "gate-when": "${{ inputs.grype_gate_when }}",
    "remediation-window-days": (
        "${{ inputs.grype_remediation_window_days }}"
    ),
    "remediation-window-start": (
        "${{ inputs.grype_remediation_window_start }}"
    ),
    "dependencies-changed": (
        "${{ needs.repository-metadata.result == 'success'"
        " && needs.repository-metadata.outputs.dependencies_changed"
        " || '' }}"
    ),
}
DETECTION = {
    "dependency_change": (
        "${{ inputs.grype_enabled"
        " && inputs.grype_gate_when == 'dependencies-changed' }}"
    ),
    "gerrit_refspec": "${{ inputs.gerrit_refspec }}",
    "dependency_ecosystems": "${{ inputs.grype_dependency_ecosystems }}",
    "dependency_patterns": "${{ inputs.grype_dependency_patterns }}",
    "dependency_path_prefix": "${{ inputs.path_prefix }}",
}
VERDICT_OUTPUT = "${{ steps.repo-metadata.outputs.dependencies_changed }}"


def triggers(doc):
    # PyYAML reads a bare 'on' key as the boolean True.
    on = doc.get("on", doc.get(True))
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return dict.fromkeys(on)
    return on if isinstance(on, dict) else {}


def steps_using(doc, action):
    for job_id, job in (doc.get("jobs") or {}).items():
        for index, step in enumerate((job or {}).get("steps") or []):
            uses = str((step or {}).get("uses", ""))
            if uses.split("@", 1)[0] == action:
                yield job_id, f"jobs.{job_id}.steps[{index}]", step, uses


def norm(value):
    return " ".join(str(value).split())


def gnu_date():
    """Return a PATH prefix under which 'date' is GNU date, '' when the
    system date already is, or None when no GNU date exists."""
    try:
        version = subprocess.run(
            ["date", "--version"], capture_output=True, text=True,
            check=False,
        ).stdout
    except OSError:
        version = ""
    if "GNU" in version:
        return ""
    gdate = shutil.which("gdate")
    if not gdate:
        return None
    shim = pathlib.Path(tempfile.mkdtemp(prefix="gnu-date-"))
    (shim / "date").write_text(f'#!/bin/sh\nexec "{gdate}" "$@"\n')
    (shim / "date").chmod(0o755)
    return str(shim)


GNU_DATE = gnu_date()
SKIPPED = set()


@functools.lru_cache(maxsize=None)
def run_validation(script, env_items):
    """Exit status of the step script under the given environment."""
    path = os.environ.get("PATH", "")
    if GNU_DATE:
        path = GNU_DATE + os.pathsep + path
    with tempfile.TemporaryDirectory() as scratch:
        target = pathlib.Path(scratch) / "validate.sh"
        target.write_text(script, encoding="utf-8")
        return subprocess.run(
            ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail",
             str(target)],
            env=dict(env_items, PATH=path), capture_output=True,
            check=False,
        ).returncode


def check_behaviour(doc, inputs, verify):
    """Run the validation step on each case; return the problems."""
    steps = (doc.get("jobs") or {}).get("gerrit-validate", {}).get(
        "steps") or []
    step = next((s for s in steps if s.get("name") == VALIDATION_STEP),
                None)
    if step is None or not isinstance(step.get("run"), str):
        return [f"gerrit-validate has no '{VALIDATION_STEP}' step"]
    reads = {}
    for var, expr in (step.get("env") or {}).items():
        match = re.fullmatch(r"\$\{\{\s*inputs\.(grype_[a-z_]+)\s*\}\}",
                             str(expr).strip())
        if match:
            reads[var] = match.group(1)
    defaults = {name: spec.get("default", "")
                for name, spec in inputs.items() if name.startswith("grype_")}
    problems = []
    cases = [(None, None, True, False)] + COMMON_CASES
    if verify:
        cases += VERIFY_CASES
    for name, value, accepted, needs_date in cases:
        if needs_date and GNU_DATE is None:
            SKIPPED.add((name, value))
            continue
        if name is not None and name not in reads.values():
            problems.append(f"{VALIDATION_STEP} does not read {name}")
            continue
        values = dict(defaults)
        if name is not None:
            values[name] = value
        env = tuple(sorted(
            (var, str(values.get(input_name, "")))
            for var, input_name in reads.items()
        ))
        ok = run_validation(step["run"], env) == 0
        if ok != accepted:
            what = f"{name}={value!r}" if name else "the defaults"
            verb = "rejects" if accepted else "accepts"
            problems.append(f"{VALIDATION_STEP} {verb} {what}")
    return problems


def check_doc(doc):
    """Return the list of problems in one parsed workflow."""
    on = triggers(doc)
    if "workflow_call" not in on:
        return []
    problems = []
    for _, where, _, uses in steps_using(doc, METADATA):
        if uses.partition("@")[2] != METADATA_PIN:
            problems.append(f"{where} does not pin {METADATA}@{METADATA_PIN}")
    scans = list(steps_using(doc, GRYPE))
    if not scans:
        return problems
    for _, where, _, _ in steps_using(doc, LEGACY_DETECTOR):
        problems.append(
            f"{where} calls {LEGACY_DETECTOR}; detection belongs to the"
            " repository-metadata job"
        )
    for _, where, step, _ in scans:
        if "dependency-change-manifest" in (step.get("with") or {}):
            problems.append(f"{where} passes dependency-change-manifest")
    # The parsed document, not the file: comments may name it.
    if LEGACY_SIDECAR in yaml.safe_dump(doc):
        problems.append(f"the workflow wires {LEGACY_SIDECAR}")
    inputs = (on.get("workflow_call") or {}).get("inputs") or {}
    verify = "grype_gate_when" in inputs
    expected = dict(COMMON, **(VERIFY if verify else {}))
    for name, (kind, default) in expected.items():
        spec = inputs.get(name)
        if not isinstance(spec, dict):
            problems.append(f"input {name} is missing")
            continue
        if spec.get("type") != kind:
            problems.append(f"input {name} is not type {kind}")
        value = spec.get("default")
        if value != default or type(value) is not type(default):
            problems.append(f"input {name} default is not {default!r}")
    jobs = doc.get("jobs") or {}
    problems += check_behaviour(doc, inputs, verify)
    for job_id, where, step, _ in scans:
        given = step.get("with") or {}
        wanted = dict(PASS_THROUGH)
        if verify:
            wanted.update(VERIFY_PASS_THROUGH)
        for key, value in wanted.items():
            if norm(given.get(key, "")) != norm(value):
                problems.append(f"{where} passes {key} as {given.get(key)!r}")
        if not verify and given.get("gate-when") != "always":
            problems.append(f"{where} must pass gate-when 'always'")
        if verify:
            job = jobs.get(job_id) or {}
            needs = job.get("needs") or []
            needs = [needs] if isinstance(needs, str) else needs
            if "repository-metadata" not in needs:
                problems.append(f"jobs.{job_id} does not need repository-metadata")
            if "!cancelled()" not in str(job.get("if", "")):
                problems.append(f"jobs.{job_id} if lacks !cancelled()")
    if verify:
        meta = jobs.get("repository-metadata") or {}
        if norm((meta.get("outputs") or {}).get(
                "dependencies_changed", "")) != VERDICT_OUTPUT:
            problems.append(
                "jobs.repository-metadata does not export dependencies_changed"
            )
        found = [s for j, _, s, _ in steps_using(doc, METADATA)
                 if j == "repository-metadata"]
        if not found:
            problems.append("jobs.repository-metadata runs no metadata step")
        for step in found:
            given = step.get("with") or {}
            for key, value in DETECTION.items():
                if norm(given.get(key, "")) != norm(value):
                    problems.append(
                        f"repository-metadata passes {key} as {given.get(key)!r}"
                    )
    return problems


def check_dir(path):
    checked = 0
    failures = 0
    for workflow in sorted(path.glob("*.y*ml")):
        doc = yaml.safe_load(workflow.read_text(encoding="utf-8"))
        if not isinstance(doc, dict):
            continue
        if "workflow_call" in triggers(doc) and list(steps_using(doc, GRYPE)):
            checked += 1
        for problem in check_doc(doc):
            failures += 1
            print(f"::error file={workflow}::{problem}")
    return checked, failures


def mutants(doc):
    """Yield (label, mutated doc) for each drift the check must catch."""
    on_key = "on" if "on" in doc else True

    def inputs(d):
        return d[on_key]["workflow_call"]["inputs"]

    def scan(d):
        for _, _, step, _ in steps_using(d, GRYPE):
            return step.setdefault("with", {})
        raise AssertionError("no grype-scan-action step")

    def detection(d):
        for job, _, step, _ in steps_using(d, METADATA):
            if job == "repository-metadata":
                return step.setdefault("with", {})
        raise AssertionError("no repository-metadata step")

    for name in dict(COMMON, **VERIFY):
        d = copy.deepcopy(doc)
        del inputs(d)[name]
        yield f"drop input {name}", d
    d = copy.deepcopy(doc)
    inputs(d)["grype_only_fixed"]["default"] = False
    yield "only_fixed default false", d
    d = copy.deepcopy(doc)
    inputs(d)["grype_dependency_policy"]["default"] = "all"
    yield "dependency_policy default all", d
    d = copy.deepcopy(doc)
    inputs(d)["grype_gate_when"]["default"] = "dependencies-changed"
    yield "gate_when default flipped", d
    for key in dict(PASS_THROUGH, **VERIFY_PASS_THROUGH):
        d = copy.deepcopy(doc)
        scan(d).pop(key, None)
        yield f"scan drops {key}", d
    d = copy.deepcopy(doc)
    scan(d)["dependencies-changed"] = (
        "${{ needs.repository-metadata.outputs.dependencies_changed }}"
    )
    yield "unguarded dependencies-changed", d
    for key in DETECTION:
        d = copy.deepcopy(doc)
        detection(d).pop(key, None)
        yield f"metadata drops {key}", d
    d = copy.deepcopy(doc)
    d["jobs"]["repository-metadata"].pop("outputs", None)
    yield "no dependencies_changed output", d
    d = copy.deepcopy(doc)
    d["jobs"]["grype"]["needs"] = "sbom"
    yield "grype does not need repository-metadata", d
    d = copy.deepcopy(doc)
    d["jobs"]["grype"]["if"] = "${{ inputs.grype_enabled }}"
    yield "grype if without !cancelled()", d
    d = copy.deepcopy(doc)
    for _, _, step, _ in steps_using(d, METADATA):
        step["uses"] = f"{METADATA}@{'0' * 40}"
        break
    yield "metadata pinned elsewhere", d
    d = copy.deepcopy(doc)
    d["jobs"]["sbom"]["steps"].append({
        "name": "Detect dependency changes",
        "uses": f"{LEGACY_DETECTOR}@{'0' * 40}",
    })
    yield "dependency-change-action step", d
    d = copy.deepcopy(doc)
    scan(d)["dependency-change-manifest"] = LEGACY_SIDECAR
    yield "scan passes dependency-change-manifest", d
    d = copy.deepcopy(doc)
    d["jobs"]["sbom"]["steps"].append({
        "name": "Upload dependency change sidecar",
        "uses": f"actions/upload-artifact@{'0' * 40}",
        "with": {"name": "dependency-change", "path": LEGACY_SIDECAR},
    })
    yield "dependency-change.json sidecar", d

    def validation(d):
        for step in d["jobs"]["gerrit-validate"]["steps"]:
            if step.get("name") == VALIDATION_STEP:
                return step
        raise AssertionError("no validation step")

    d = copy.deepcopy(doc)
    d["jobs"]["gerrit-validate"]["steps"].remove(validation(d))
    yield "validation step removed", d
    d = copy.deepcopy(doc)
    validation(d)["run"] = "exit 0\n"
    yield "no-op validator", d
    # Only GNU date accepts year 0000, so elsewhere the date check
    # rejects it even without the explicit guard and this mutant cannot
    # fail; CI requires GNU date, so it always runs there.
    if GNU_DATE is not None:
        d = copy.deepcopy(doc)
        step = validation(d)
        step["run"] = step["run"].replace(
            "[ \"${start%%-*}\" = '0000' ] ||", "")
        yield "year 0000 accepted", d


def self_test(path):
    """Expect every mutant of the clean verify workflow to fail."""
    for workflow in sorted(path.glob("*.y*ml")):
        doc = yaml.safe_load(workflow.read_text(encoding="utf-8"))
        on = triggers(doc) if isinstance(doc, dict) else {}
        inputs = ((on.get("workflow_call") or {}).get("inputs") or {}) if (
            "workflow_call" in on) else {}
        if "grype_gate_when" in inputs and not check_doc(doc):
            break
    else:
        print("::error::no clean verify workflow to mutate")
        return 1
    escaped = 0
    total = 0
    with tempfile.TemporaryDirectory() as scratch:
        target = pathlib.Path(scratch) / workflow.name
        for label, mutant in mutants(doc):
            total += 1
            target.write_text(yaml.safe_dump(mutant), encoding="utf-8")
            if not check_doc(yaml.safe_load(target.read_text())):
                escaped += 1
                print(f"::error::mutant not caught: {label}")
    print(f"Mutants of {workflow.name} caught: {total - escaped}/{total}")
    return escaped


root = pathlib.Path(sys.argv[1])
checked, failures = check_dir(root)
if not checked:
    print(f"::error::no workflow_call workflow calls {GRYPE} in {root}")
    sys.exit(1)
if failures:
    print(f"{failures} problem(s) across {checked} workflow(s) ❌")
    sys.exit(1)
print(f"{checked} workflow(s) wire the Grype policy ✅")
if SKIPPED:
    if os.environ.get("CI") == "true":
        print("::error::GNU date is unavailable, so the calendar-date"
              " cases cannot run; CI must run them")
        sys.exit(1)
    print(f"::notice::GNU date is unavailable: skipped {len(SKIPPED)}"
          " calendar-date case(s) and the year-0000 mutant; CI runs them")
if self_test(root):
    sys.exit(1)
PYEOF
