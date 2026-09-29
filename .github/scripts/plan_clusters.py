#!/usr/bin/env python3
"""Turn clusters/*.yaml into a GitHub Actions matrix.

Reads the cluster inventory, applies a selector, and emits the matrix the dispatcher fans out
over. Keeping this in one place means the inventory is declarative and reviewable, and the
workflow does not grow a pile of conditionals.

Selector, from the SELECT env var:
  all                     every enabled cluster
  env:production          every enabled cluster in one environment
  profile:dpu             every enabled cluster running one profile
  name:tokyo-dpu          one cluster by name, enabled or not
  runner:hub              every enabled cluster driven from a hub runner
"""
import json
import os
import pathlib
import sys

import yaml

REQUIRED = ("name", "runner", "runner_label", "environment", "profile")
VALID_RUNNER = {"beside", "hub"}
VALID_PROFILE = {"host", "dpu"}


def load():
    out = []
    for f in sorted(pathlib.Path("clusters").glob("*.yaml")):
        d = yaml.safe_load(f.read_text()) or {}
        missing = [k for k in REQUIRED if not d.get(k)]
        if missing:
            sys.exit(f"{f}: missing required key(s): {', '.join(missing)}")
        if d["runner"] not in VALID_RUNNER:
            sys.exit(f"{f}: runner must be one of {sorted(VALID_RUNNER)}")
        if d["profile"] not in VALID_PROFILE:
            sys.exit(f"{f}: profile must be one of {sorted(VALID_PROFILE)}")
        if d["runner"] == "hub" and not d.get("kube_context"):
            sys.exit(f"{f}: runner is hub, so kube_context is required to pick it out of "
                     f"the merged kubeconfig")
        d["_file"] = f.as_posix()
        out.append(d)
    if not out:
        sys.exit("no cluster files found under clusters/")
    return out


def select(clusters, sel):
    sel = (sel or "all").strip()
    if sel == "all":
        return [c for c in clusters if c.get("enabled")]
    if ":" not in sel:
        sys.exit(f"unrecognised selector {sel!r}, see the docstring")
    key, val = sel.split(":", 1)
    if key == "name":
        # an explicit name wins over enabled, so a disabled cluster can still be targeted on purpose
        hit = [c for c in clusters if c["name"] == val]
        if not hit:
            sys.exit(f"no cluster named {val!r}")
        return hit
    field = {"env": "environment", "profile": "profile", "runner": "runner"}.get(key)
    if not field:
        sys.exit(f"unrecognised selector key {key!r}")
    return [c for c in clusters if c.get("enabled") and c.get(field) == val]


def main():
    clusters = load()
    chosen = select(clusters, os.environ.get("SELECT", "all"))
    matrix = [
        {
            "name": c["name"],
            "runner": c["runner"],
            "runner_label": c["runner_label"],
            "environment": c["environment"],
            "profile": c["profile"],
            "kube_context": c.get("kube_context", "") or "",
            "storage_class": c.get("storage_class", "") or "",
            "pod_cidr": c.get("pod_cidr", "") or "",
        }
        for c in chosen
    ]

    print(f"{len(clusters)} cluster(s) in inventory, {len(matrix)} selected", file=sys.stderr)
    for m in matrix:
        print(f"  {m['name']:24} {m['environment']:11} {m['profile']:5} "
              f"runner={m['runner']}:{m['runner_label']}", file=sys.stderr)

    gh_out = os.environ.get("GITHUB_OUTPUT")
    payload = json.dumps(matrix)
    if gh_out:
        with open(gh_out, "a") as fh:
            fh.write(f"matrix={payload}\n")
            fh.write(f"count={len(matrix)}\n")
    else:
        print(payload)


if __name__ == "__main__":
    main()
