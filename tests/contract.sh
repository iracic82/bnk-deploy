#!/usr/bin/env bash
# Contract tests for install.sh. No cluster required, so this runs on a hosted runner.
#
# These assert the things CI depends on: that failures exit non-zero and successes exit zero.
# A script that prints an error and exits 0 is worse than one that crashes, because a workflow
# will call it a success.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1

pass=0; fail=0
expect() {
  local want="$1" desc="$2"; shift 2
  local got
  "$@" >/dev/null 2>&1; got=$?
  if [[ "$got" == "$want" ]]; then
    printf '  \033[0;32mok\033[0m    %-48s exit=%s\n' "$desc" "$got"; pass=$((pass+1))
  else
    printf '  \033[0;31mFAIL\033[0m  %-48s exit=%s want=%s\n' "$desc" "$got" "$want"; fail=$((fail+1))
  fi
}
expect_nonzero() {
  local desc="$1"; shift
  local got
  "$@" >/dev/null 2>&1; got=$?
  if [[ "$got" != "0" ]]; then
    printf '  \033[0;32mok\033[0m    %-48s exit=%s\n' "$desc" "$got"; pass=$((pass+1))
  else
    printf '  \033[0;31mFAIL\033[0m  %-48s exited 0, should not have\n' "$desc"; fail=$((fail+1))
  fi
}

echo "=== argument handling ==="
expect 0 "--list-env"                       ./install.sh --list-env
expect 0 "--list-profile"                   ./install.sh --list-profile
expect 0 "--help"                           ./install.sh --help
expect 2 "no --env"                         ./install.sh
expect 2 "unknown environment"              ./install.sh --env does-not-exist --profile host
expect 2 "unknown profile"                  ./install.sh --env lab --profile does-not-exist
expect 2 "unknown flag"                     ./install.sh --env lab --nonsense

echo "=== listings contain what they should ==="
# Capture once rather than piping into grep -q. With pipefail, grep -q exits on the first match and
# SIGPIPEs the producer, so the pipeline reports failure for anything that is not the last line.
envs_out="$(./install.sh --list-env)"
profiles_out="$(./install.sh --list-profile)"
for e in lab demo staging production; do
  if grep -qx "$e" <<<"$envs_out"; then
    printf '  \033[0;32mok\033[0m    environment %s listed\n' "$e"; pass=$((pass+1))
  else
    printf '  \033[0;31mFAIL\033[0m  environment %s missing\n' "$e"; fail=$((fail+1))
  fi
done
for p in host dpu; do
  if grep -qx "$p" <<<"$profiles_out"; then
    printf '  \033[0;32mok\033[0m    profile %s listed\n' "$p"; pass=$((pass+1))
  else
    printf '  \033[0;31mFAIL\033[0m  profile %s missing\n' "$p"; fail=$((fail+1))
  fi
done
# combination override files must not be offered as environments
if grep -q '\.' <<<"$envs_out"; then
  printf '  \033[0;31mFAIL\033[0m  combination override leaked into --list-env\n'; fail=$((fail+1))
else
  printf '  \033[0;32mok\033[0m    combination overrides excluded from --list-env\n'; pass=$((pass+1))
fi

echo "=== guardrails ==="
expect_nonzero "production refuses --skip-license"  ./install.sh --env production --skip-license --phase 60
expect_nonzero "missing FAR_PULL_JSON is fatal"     env -u FAR_PULL_JSON ./install.sh --env lab --profile host --phase 00
expect_nonzero "unreadable FAR_PULL_JSON is fatal"  env FAR_PULL_JSON=/nonexistent ./install.sh --env lab --profile host --phase 00
expect_nonzero "bad --context is fatal"             env KUBE_CONTEXT=does-not-exist FAR_PULL_JSON=/dev/null ./install.sh --env lab --phase 70
# lab may skip the licence, so this must be allowed
expect 0 "lab allows --skip-license at phase 60"    ./install.sh --env lab --skip-license --phase 60

echo
echo "  $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
