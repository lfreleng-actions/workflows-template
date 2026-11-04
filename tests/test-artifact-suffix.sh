#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Checks that the build-test and build-test-release skeletons name
# their per-call artefacts with the artifact_suffix input, so a caller
# that runs a workflow more than once in one run (a matrix) gets
# distinct names, and that each grype job downloads the SBOM its own
# sbom job uploaded, by artefact ID, so no call scans another call's
# SBOM even when the suffix is omitted and the names collide.
#
# Static, from the parsed YAML:
#   - both workflows take artifact_suffix (string, default empty) and
#     derive the workflow-level ARTIFACT_SUFFIX env from it, empty when
#     the input is unset so existing names stay unchanged;
#   - every upload-artifact step, every download-artifact step that
#     selects by name, and every grype-scan-action step's
#     artifact-name ends with ${{ env.ARTIFACT_SUFFIX }}, and the
#     expected sites are all present;
#   - the sbom job exports its upload step's artifact-id output as
#     sbom_artifact_id, and every download-artifact step in the grype
#     job passes it as artifact-ids, with no name or pattern;
#   - every job in testing.yaml that calls build-test.yaml passes a
#     valid artifact_suffix, and no two calls share one.
#
# Dynamic: the 'Validate artifact_suffix input' step of gerrit-validate
# is extracted from each workflow and run under bash with valid and
# invalid values.
#
# It then mutates copies of the workflows in each way the check must
# catch and expects every mutant to fail.
#
# Usage: bash tests/test-artifact-suffix.sh [<workflows-dir>]
#
# Needs python3 with PyYAML.

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
import os
import pathlib
import re
import subprocess
import sys

import yaml

INPUT = "artifact_suffix"
ENV_NAME = "ARTIFACT_SUFFIX"
ENV_VALUE = (
    "${{ inputs.artifact_suffix != '' && "
    "format('-{0}', inputs.artifact_suffix) || '' }}"
)
SUFFIX = "${{ env.ARTIFACT_SUFFIX }}"
VALIDATE_JOB = "gerrit-validate"
VALIDATE_STEP = "Validate artifact_suffix input"
UPLOAD = "actions/upload-artifact"
DOWNLOAD = "actions/download-artifact"
GRYPE = "lfreleng-actions/grype-scan-action"
BUILD_NAME = "${{ steps.build.outputs.artefact_name }}"
SBOM_JOB = "sbom"
GRYPE_JOB = "grype"
SBOM_OUTPUT = "sbom_artifact_id"
SBOM_ID = "${{ needs.%s.outputs.%s }}" % (SBOM_JOB, SBOM_OUTPUT)
# download-artifact selects by exactly one of these; a grype job may
# use only artifact-ids.
SELECTORS = ("name", "pattern", "artifact-ids")
VALID = re.compile(r"[A-Za-z0-9._-]+")

# workflow -> [(job, action, with-key, expected value)]
SITES = {
    "build-test.yaml": [
        ("build", UPLOAD, "name", BUILD_NAME + SUFFIX),
        ("sbom", UPLOAD, "name", "sbom-files" + SUFFIX),
        ("grype", GRYPE, "artifact-name", "grype-scan-results" + SUFFIX),
    ],
    "build-test-release.yaml": [
        ("build", UPLOAD, "name", BUILD_NAME + SUFFIX),
        ("sbom", UPLOAD, "name", "sbom-files" + SUFFIX),
        ("grype", GRYPE, "artifact-name", "grype-scan-results" + SUFFIX),
        ("attach-artefacts", DOWNLOAD, "name",
         "${{ needs.build.outputs.artefact_name }}" + SUFFIX),
    ],
}
CALLER = "testing.yaml"
CALLED = "build-test.yaml"

ACCEPTED = [
    "", "a", "test-go-project", "allowlist", "v1.2_3", "A.B-c_d",
]
REJECTED = [
    "a/b", "a b", "a:b", "../x", "a*", "$(id)", "a\nb", "ä", "a;b",
    "a\"b", "a\\b",
]


def triggers(doc):
    # PyYAML reads a bare 'on' key as the boolean True.
    on = doc.get("on", doc.get(True))
    return on if isinstance(on, dict) else {}


def inputs_of(doc):
    return (triggers(doc).get("workflow_call") or {}).get("inputs") or {}


def jobs_of(doc):
    return doc.get("jobs") or {}


def steps_of(job):
    return (job or {}).get("steps") or []


def action_of(step):
    return str((step or {}).get("uses", "")).split("@", 1)[0]


def validate_step(doc):
    for step in steps_of(jobs_of(doc).get(VALIDATE_JOB)):
        if (step or {}).get("name") == VALIDATE_STEP:
            return step
    return None


def sbom_upload(doc):
    """Return the sbom job's upload step for the SBOM artefact."""
    for step in steps_of(jobs_of(doc).get(SBOM_JOB)):
        if action_of(step) == UPLOAD and \
                ((step or {}).get("with") or {}).get("name") == \
                "sbom-files" + SUFFIX:
            return step
    return None


def check_names(doc, problems):
    """Every per-call artefact name carries the suffix."""
    found = set()
    for job_id, job in jobs_of(doc).items():
        for index, step in enumerate(steps_of(job)):
            action = action_of(step)
            given = (step or {}).get("with") or {}
            where = f"jobs.{job_id}.steps[{index}].with"
            if action == UPLOAD or (action == DOWNLOAD and "name" in given):
                key = "name"
            elif action == GRYPE:
                key = "artifact-name"
            else:
                continue
            value = given.get(key)
            if not isinstance(value, str) or not value.endswith(SUFFIX):
                problems.append(f"{where}.{key} lacks {SUFFIX}: {value!r}")
                continue
            found.add((job_id, action, key, value))
    return found


def check_binding(doc, problems):
    """The grype job must download the SBOM its sbom job uploaded."""
    upload = sbom_upload(doc)
    if upload is None:
        return  # SITES already reports the missing upload
    step_id = upload.get("id")
    wanted = "${{ steps.%s.outputs.artifact-id }}" % step_id
    outputs = (jobs_of(doc).get(SBOM_JOB) or {}).get("outputs") or {}
    if not step_id or outputs.get(SBOM_OUTPUT) != wanted:
        problems.append(
            f"jobs.{SBOM_JOB}.outputs.{SBOM_OUTPUT} is not the upload"
            " step's artifact-id"
        )
    job = jobs_of(doc).get(GRYPE_JOB) or {}
    needs = job.get("needs") or []
    if SBOM_JOB not in ([needs] if isinstance(needs, str) else needs):
        problems.append(f"jobs.{GRYPE_JOB} does not need {SBOM_JOB}")
    downloads = 0
    for index, step in enumerate(steps_of(job)):
        if action_of(step) != DOWNLOAD:
            continue
        downloads += 1
        where = f"jobs.{GRYPE_JOB}.steps[{index}].with"
        given = (step or {}).get("with") or {}
        for key in SELECTORS:
            if key != "artifact-ids" and key in given:
                problems.append(f"{where}.{key} selects by {key}, not by ID")
        if given.get("artifact-ids") != SBOM_ID:
            problems.append(f"{where}.artifact-ids is not {SBOM_ID}")
    if not downloads:
        problems.append(f"jobs.{GRYPE_JOB} has no {DOWNLOAD} step")


def check_doc(name, doc):
    """Return the list of problems in one reusable workflow."""
    problems = []
    spec = inputs_of(doc).get(INPUT)
    if not isinstance(spec, dict):
        problems.append(f"input {INPUT} is missing")
    else:
        if spec.get("type") != "string":
            problems.append(f"input {INPUT} is not type string")
        if spec.get("default") != "":
            problems.append(f"input {INPUT} default is not ''")
    if (doc.get("env") or {}).get(ENV_NAME) != ENV_VALUE:
        problems.append(f"workflow env {ENV_NAME} is not {ENV_VALUE}")

    found = check_names(doc, problems)
    for site in SITES[name]:
        if site not in found:
            job_id, action, key, value = site
            problems.append(
                f"jobs.{job_id} has no {action} step with {key}: {value!r}"
            )
    check_binding(doc, problems)

    step = validate_step(doc)
    if step is None:
        problems.append(f"jobs.{VALIDATE_JOB} has no '{VALIDATE_STEP}' step")
    else:
        if "if" in step:
            problems.append(f"'{VALIDATE_STEP}' must run unconditionally")
        env = step.get("env") or {}
        if "${{ inputs.%s }}" % INPUT not in env.values():
            problems.append(f"'{VALIDATE_STEP}' does not read {INPUT}")
        if not isinstance(step.get("run"), str) or not step["run"].strip():
            problems.append(f"'{VALIDATE_STEP}' has no run script")
    return problems


def calls(doc):
    """Yield (job id, job) for each job calling the build-test skeleton."""
    for job_id, job in jobs_of(doc).items():
        uses = str((job or {}).get("uses", ""))
        if uses.split("@", 1)[0].endswith("/.github/workflows/" + CALLED):
            yield job_id, job


def check_caller(doc):
    """Return the list of problems in the testing.yaml caller."""
    problems = []
    seen = {}
    count = 0
    for job_id, job in calls(doc):
        count += 1
        value = (job.get("with") or {}).get(INPUT)
        if value is None or value == "":
            problems.append(f"jobs.{job_id} does not pass {INPUT}")
            continue
        if value == "${{ matrix.name }}":
            legs = ((job.get("strategy") or {}).get("matrix") or {}) \
                .get("include") or []
            suffixes = [str((leg or {}).get("name", "")) for leg in legs]
            if not suffixes:
                problems.append(f"jobs.{job_id} matrix has no named legs")
        elif (job.get("strategy") or {}).get("matrix"):
            # A fixed value would hand every leg the same suffix.
            problems.append(
                f"jobs.{job_id} runs a matrix but passes {INPUT}"
                f" {value!r}, not ${{{{ matrix.name }}}}"
            )
            continue
        elif "${{" in str(value):
            problems.append(
                f"jobs.{job_id} passes {INPUT} as an expression other"
                f" than matrix.name: {value!r}"
            )
            continue
        else:
            suffixes = [str(value)]
        for suffix in suffixes:
            if not VALID.fullmatch(suffix):
                problems.append(
                    f"jobs.{job_id} suffix {suffix!r} is not a valid suffix"
                )
            if suffix in seen:
                problems.append(
                    f"jobs.{job_id} reuses suffix {suffix!r} of"
                    f" jobs.{seen[suffix]}"
                )
            seen[suffix] = job_id
    if not count:
        problems.append(f"no job in {CALLER} calls {CALLED}")
    return problems


def run_validate(doc, value):
    step = validate_step(doc)
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin")}
    for var, ref in (step.get("env") or {}).items():
        if ref == "${{ inputs.%s }}" % INPUT:
            env[var] = value
    result = subprocess.run(
        ["bash", "-c", step["run"]],
        env=env, capture_output=True, text=True, check=False,
    )
    return result.returncode, result.stdout + result.stderr


def exercise_validation(name, doc):
    wrong = 0
    for value in ACCEPTED:
        code, output = run_validate(doc, value)
        if code != 0:
            wrong += 1
            print(f"::error file={name}::{value!r} rejected: {output.strip()}")
    for value in REJECTED:
        code, output = run_validate(doc, value)
        if code == 0:
            wrong += 1
            print(f"::error file={name}::{value!r} accepted")
        elif f"Invalid {INPUT} input" not in output:
            wrong += 1
            print(
                f"::error file={name}::{value!r} rejected without naming"
                f" the input: {output.strip()}"
            )
    total = len(ACCEPTED) + len(REJECTED)
    print(f"{name}: validate step right on {total - wrong}/{total} values")
    return wrong


def mutants(name, doc):
    """Yield (label, mutated doc) for each drift the check must catch."""
    on_key = "on" if "on" in doc else True

    def find(d, job_id, action, key, value):
        for step in d["jobs"][job_id]["steps"]:
            if action_of(step) == action and \
                    (step.get("with") or {}).get(key) == value:
                return step
        raise LookupError((job_id, action, key, value))

    def download(d):
        for step in d["jobs"][GRYPE_JOB]["steps"]:
            if action_of(step) == DOWNLOAD:
                return step
        raise LookupError((GRYPE_JOB, DOWNLOAD))

    d = copy.deepcopy(doc)
    del d[on_key]["workflow_call"]["inputs"][INPUT]
    yield "drop the input", d
    d = copy.deepcopy(doc)
    d[on_key]["workflow_call"]["inputs"][INPUT]["default"] = "x"
    yield "non-empty default", d
    d = copy.deepcopy(doc)
    d[on_key]["workflow_call"]["inputs"][INPUT]["type"] = "boolean"
    yield "input not a string", d
    d = copy.deepcopy(doc)
    del d["env"][ENV_NAME]
    yield "drop the env", d
    d = copy.deepcopy(doc)
    d["env"][ENV_NAME] = "-${{ inputs.artifact_suffix }}"
    yield "env adds a hyphen when unset", d
    for job_id, action, key, value in SITES[name]:
        d = copy.deepcopy(doc)
        step = find(d, job_id, action, key, value)
        step["with"][key] = value[: -len(SUFFIX)]
        yield f"{job_id} {key} without the suffix", d
        d = copy.deepcopy(doc)
        d["jobs"][job_id]["steps"].remove(find(d, job_id, action, key, value))
        yield f"{job_id} {key} site removed", d
    d = copy.deepcopy(doc)
    del find(d, "grype", GRYPE, "artifact-name",
             "grype-scan-results" + SUFFIX)["with"]["artifact-name"]
    yield "grype falls back to the action's default name", d
    d = copy.deepcopy(doc)
    d["jobs"][SBOM_JOB]["steps"].append({
        "name": "Upload extra",
        "uses": UPLOAD + "@0000000000000000000000000000000000000000",
        "with": {"name": "extra-files", "path": "x"},
    })
    yield "new upload without the suffix", d

    d = copy.deepcopy(doc)
    del d["jobs"][SBOM_JOB]["outputs"][SBOM_OUTPUT]
    yield "sbom job drops the artefact ID output", d
    d = copy.deepcopy(doc)
    d["jobs"][SBOM_JOB]["outputs"][SBOM_OUTPUT] = \
        "${{ steps.sbom.outputs.artifact-id }}"
    yield "sbom job reads the ID from another step", d
    d = copy.deepcopy(doc)
    del sbom_upload(d)["id"]
    yield "sbom upload step loses its id", d
    d = copy.deepcopy(doc)
    d["jobs"][GRYPE_JOB]["needs"] = "build"
    yield "grype job no longer needs sbom", d
    d = copy.deepcopy(doc)
    download(d)["with"] = {"name": "sbom-files" + SUFFIX}
    yield "grype downloads by name", d
    d = copy.deepcopy(doc)
    download(d)["with"]["name"] = "sbom-files" + SUFFIX
    yield "grype downloads by name and ID", d
    d = copy.deepcopy(doc)
    download(d)["with"] = {"pattern": "sbom-files*"}
    yield "grype downloads by pattern", d
    d = copy.deepcopy(doc)
    download(d)["with"]["artifact-ids"] = "${{ needs.sbom.outputs.id }}"
    yield "grype downloads another output", d
    d = copy.deepcopy(doc)
    del download(d)["with"]["artifact-ids"]
    yield "grype downloads every artefact", d
    d = copy.deepcopy(doc)
    d["jobs"][GRYPE_JOB]["steps"].remove(download(d))
    yield "grype download removed", d
    d = copy.deepcopy(doc)
    validate_step(d)["if"] = "inputs.artifact_suffix != ''"
    yield "validate step conditional", d
    d = copy.deepcopy(doc)
    d["jobs"][VALIDATE_JOB]["steps"].remove(validate_step(d))
    yield "validate step missing", d


def caller_mutants(doc):
    jobs = [job_id for job_id, _ in calls(doc)]
    matrix_job = next(
        job_id for job_id in jobs
        if doc["jobs"][job_id]["with"].get(INPUT) == "${{ matrix.name }}"
    )
    literal_job = next(
        job_id for job_id in jobs
        if doc["jobs"][job_id]["with"].get(INPUT) != "${{ matrix.name }}"
    )
    for job_id in jobs:
        d = copy.deepcopy(doc)
        del d["jobs"][job_id]["with"][INPUT]
        yield f"{job_id} drops the suffix", d
    d = copy.deepcopy(doc)
    d["jobs"][matrix_job]["with"][INPUT] = "fixed"
    yield "matrix passes one suffix to every leg", d
    d = copy.deepcopy(doc)
    d["jobs"][matrix_job]["with"][INPUT] = "${{ matrix.repository }}"
    yield "matrix passes the repository as the suffix", d
    d = copy.deepcopy(doc)
    legs = d["jobs"][matrix_job]["strategy"]["matrix"]["include"]
    legs[1]["name"] = legs[0]["name"]
    yield "matrix legs share a name", d
    d = copy.deepcopy(doc)
    legs = d["jobs"][matrix_job]["strategy"]["matrix"]["include"]
    legs[0]["name"] = "a/b"
    yield "matrix leg name is not a valid suffix", d
    d = copy.deepcopy(doc)
    first = d["jobs"][matrix_job]["strategy"]["matrix"]["include"][0]
    d["jobs"][literal_job]["with"][INPUT] = first["name"]
    yield "literal suffix repeats a matrix leg", d


def self_test(name, doc, check):
    escaped = 0
    total = 0
    generator = caller_mutants(doc) if name == CALLER else mutants(name, doc)
    for label, mutant in generator:
        total += 1
        if not check(yaml.safe_load(yaml.safe_dump(mutant))):
            escaped += 1
            print(f"::error::mutant of {name} not caught: {label}")
    print(f"Mutants of {name} caught: {total - escaped}/{total}")
    return escaped


root = pathlib.Path(sys.argv[1])
failures = 0
docs = {}
for name in sorted(list(SITES) + [CALLER]):
    path = root / name
    if not path.is_file():
        print(f"::error::workflow not found: {path}")
        failures += 1
        continue
    doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    docs[name] = doc
    problems = check_caller(doc) if name == CALLER else check_doc(name, doc)
    for problem in problems:
        failures += 1
        print(f"::error file={path}::{problem}")
if failures:
    print(f"{failures} problem(s) in the artefact suffix wiring ❌")
    sys.exit(1)
print(f"{len(docs)} workflow(s) wire the artefact suffix ✅")
for name in SITES:
    failures += exercise_validation(name, docs[name])
for name in SITES:
    failures += self_test(
        name, docs[name], lambda d, n=name: check_doc(n, d),
    )
failures += self_test(CALLER, docs[CALLER], check_caller)
if failures:
    sys.exit(1)
PYEOF
