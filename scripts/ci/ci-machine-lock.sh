#!/usr/bin/env bash
# Machine-wide lock for heavy CI jobs on the shared self-hosted Mac.
#
# austery/legado and insight-engine-personal each register their own runner on
# the same Mac. GitHub `concurrency` groups and runner labels are per repository,
# so they cannot stop both repositories' heavy jobs from running at once. Both
# repositories call this script with the same lock path to queue those jobs.
# Keep the protocol identical in both copies (insight-engine-personal:
# tools/quality/ci-machine-lock.sh).
#
# Usage:
#   ci-machine-lock.sh acquire   # first step of a heavy job
#   ci-machine-lock.sh release   # last step, with `if: always()`
#
# Protocol:
# - The lock is the directory $CI_MACHINE_LOCK_DIR; `mkdir` is atomic.
# - The holder is the job's Runner.Worker process, which lives for the whole
#   job. A lock whose holder process is gone is stale and is removed, so a
#   crashed or killed job cannot block the machine.
# - acquire waits up to $CI_MACHINE_LOCK_WAIT_SECONDS, then fails the job.
# - release removes the lock only when this job's worker holds it.
set -euo pipefail

lock_dir="${CI_MACHINE_LOCK_DIR:-$HOME/GitHubRunners/.heavy-ci.lock}"
wait_seconds="${CI_MACHINE_LOCK_WAIT_SECONDS:-2700}"
poll_seconds="${CI_MACHINE_LOCK_POLL_SECONDS:-15}"

# The job's Runner.Worker ancestor; CI_MACHINE_LOCK_OWNER_PID overrides it for tests.
owner_pid() {
  if [ -n "${CI_MACHINE_LOCK_OWNER_PID:-}" ]; then
    echo "$CI_MACHINE_LOCK_OWNER_PID"
    return
  fi
  local pid=$$
  while [ "$pid" -gt 1 ]; do
    if ps -o command= -p "$pid" | grep -q 'Runner\.Worker'; then
      echo "$pid"
      return
    fi
    pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
  done
  echo "ci-machine-lock: no Runner.Worker ancestor; set CI_MACHINE_LOCK_OWNER_PID" >&2
  exit 2
}

holder_pid() {
  sed -n 's/^pid=//p' "$lock_dir/owner" 2>/dev/null || true
}

acquire() {
  local me waited=0 holder
  me=$(owner_pid)
  mkdir -p "$(dirname "$lock_dir")"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    holder=$(holder_pid)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      echo "ci-machine-lock: removing stale lock of exited pid $holder"
      rm -rf "$lock_dir"
      continue
    fi
    if [ "$waited" -ge "$wait_seconds" ]; then
      echo "ci-machine-lock: gave up after ${waited}s; holder:" >&2
      cat "$lock_dir/owner" >&2 2>/dev/null || true
      exit 1
    fi
    [ "$waited" -eq 0 ] && { echo "ci-machine-lock: waiting; holder:"; cat "$lock_dir/owner" 2>/dev/null || echo "(owner not written yet)"; }
    sleep "$poll_seconds"
    waited=$((waited + poll_seconds))
  done
  printf 'pid=%s\nrepository=%s\nrun=%s\njob=%s\nsince=%s\n' \
    "$me" "${GITHUB_REPOSITORY:-local}" "${GITHUB_RUN_ID:-}" "${GITHUB_JOB:-}" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock_dir/owner"
  echo "ci-machine-lock: acquired after ${waited}s (pid $me)"
}

release() {
  local me holder
  me=$(owner_pid)
  holder=$(holder_pid)
  if [ "$holder" = "$me" ]; then
    rm -rf "$lock_dir"
    echo "ci-machine-lock: released (pid $me)"
  else
    echo "ci-machine-lock: not held by this job (holder: ${holder:-none}); nothing to release"
  fi
}

case "${1:-}" in
  acquire) acquire ;;
  release) release ;;
  *) echo "usage: $0 acquire|release" >&2; exit 2 ;;
esac
