#!/usr/bin/env python3
"""Run a workflow job's plain `run:` steps locally, in order, from the workflow file itself.

The degraded-mode replica (`.claude/ci-replica.json`) uses this for jobs whose steps
are inline scripts, so the replica measures the text CI runs instead of a second copy
that can drift from it.

    bin/run-workflow-job.py .github/workflows/validate.yml config-drift
    bin/run-workflow-job.py .github/workflows/validate.yml validate --drop-line '^\\s*sudo apt-get'

Only steps with a `run:` execute. `uses:` steps (checkout, setup-node) are the runner's
own plumbing and are skipped, and a step whose `if:` or `working-directory:` is set is
refused (exit 2) rather than guessed at. `--drop-line REGEX` replaces each matching line
with `true` (for a step that installs a tool the box already has). Each step runs under
`bash -eo pipefail`, as the runner's `shell: bash` does; the first failure stops the job.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

import yaml


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("workflow")
    p.add_argument("job")
    p.add_argument("--drop-line", action="append", default=[], metavar="REGEX")
    a = p.parse_args()

    with open(a.workflow) as f:
        spec = yaml.safe_load(f)
    job = (spec.get("jobs") or {}).get(a.job)
    if job is None:
        print(f"run-workflow-job: no job {a.job!r} in {a.workflow}", file=sys.stderr)
        return 2
    drops = [re.compile(r) for r in a.drop_line]

    steps = job.get("steps") or []
    for step in steps:
        label = step.get("name") or step.get("uses") or "unnamed step"
        if "run" in step and ("if" in step or "working-directory" in step):
            print(f"run-workflow-job: {label}: `if:`/`working-directory:` is not handled locally", file=sys.stderr)
            return 2

    ran = 0
    for step in steps:
        if "run" not in step:
            continue
        label = step.get("name") or "unnamed step"
        script = "\n".join(
            "true" if any(d.search(line) for d in drops) else line
            for line in str(step["run"]).splitlines()
        )
        env = dict(os.environ)
        for k, v in (step.get("env") or {}).items():
            env[k] = str(v)
        print(f"--- {a.job}: {label}", flush=True)
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as sf:
            sf.write(script + "\n")
        rc = subprocess.call(["bash", "--noprofile", "--norc", "-eo", "pipefail", sf.name], env=env)
        os.unlink(sf.name)
        ran += 1
        if rc != 0:
            print(f"run-workflow-job: step {label!r} failed (exit {rc})", file=sys.stderr)
            return rc
    if ran == 0:
        print(f"run-workflow-job: job {a.job!r} has no `run:` steps", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
