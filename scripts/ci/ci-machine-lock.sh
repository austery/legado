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
# - The lock is a symbolic link at $CI_MACHINE_LOCK_PATH whose target text is the
#   owner record ("pid=...;repository=...;..."). `ln -s` creates the link and its
#   owner record in one atomic step, so a lock never exists without an owner.
# - The holder is the job's Runner.Worker process, which lives for the whole job.
#   A lock is stale when its holder pid is gone or no longer runs a command that
#   matches $CI_MACHINE_LOCK_HOLDER_PATTERN (guards against pid reuse).
# - A stale lock is first renamed away with `mv`; only one waiter can win that
#   rename, and it removes the link only if it still holds the stale record.
# - acquire waits up to $CI_MACHINE_LOCK_WAIT_SECONDS, then fails the job. It is
#   mutual exclusion, not a fair queue.
# - release removes the lock only when this job's worker holds it.
set -euo pipefail

lock_path="${CI_MACHINE_LOCK_PATH:-$HOME/GitHubRunners/.heavy-ci.link}"
wait_seconds="${CI_MACHINE_LOCK_WAIT_SECONDS:-2700}"
poll_seconds="${CI_MACHINE_LOCK_POLL_SECONDS:-15}"
holder_pattern="${CI_MACHINE_LOCK_HOLDER_PATTERN:-Runner\.Worker}"

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

record() { readlink "$lock_path" 2>/dev/null || true; }
record_pid() { printf '%s\n' "$1" | sed -n 's/^pid=\([0-9]*\);.*/\1/p'; }

holder_alive() {
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null &&
    ps -o command= -p "$1" 2>/dev/null | grep -q -- "$holder_pattern"
}

remove_stale() {
  local seen="$1" moved="$lock_path.stale.$$"
  mv "$lock_path" "$moved" 2>/dev/null || return 0
  if [ "$(readlink "$moved" 2>/dev/null || true)" = "$seen" ]; then
    rm -f "$moved"
    echo "ci-machine-lock: removed stale lock: $seen"
  else
    # Another job acquired between our read and the rename; give its lock back.
    mv -n "$moved" "$lock_path" 2>/dev/null || rm -f "$moved"
  fi
}

acquire() {
  local me waited=0 current
  me=$(owner_pid)
  mkdir -p "$(dirname "$lock_path")"
  # `ln -s` onto an existing directory would create the link inside it and "succeed".
  if [ -d "$lock_path" ] && [ ! -L "$lock_path" ]; then
    echo "ci-machine-lock: $lock_path is a directory, not a lock link; remove it by hand" >&2
    exit 2
  fi
  local mine
  mine="pid=$me;repository=${GITHUB_REPOSITORY:-local};run=${GITHUB_RUN_ID:-};job=${GITHUB_JOB:-};since=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  while ! ln -s "$mine" "$lock_path" 2>/dev/null; do
    current=$(record)
    if [ -n "$current" ] && ! holder_alive "$(record_pid "$current")"; then
      remove_stale "$current"
      continue
    fi
    if [ "$waited" -ge "$wait_seconds" ]; then
      echo "ci-machine-lock: gave up after ${waited}s; holder: ${current:-unknown}" >&2
      exit 1
    fi
    if [ "$waited" -eq 0 ]; then
      echo "ci-machine-lock: waiting; holder: ${current:-unknown}"
    fi
    sleep "$poll_seconds"
    waited=$((waited + poll_seconds))
  done
  echo "ci-machine-lock: acquired after ${waited}s: $mine"
}

release() {
  local me current
  me=$(owner_pid)
  current=$(record)
  if [ -n "$current" ] && [ "$(record_pid "$current")" = "$me" ]; then
    rm -f "$lock_path"
    echo "ci-machine-lock: released (pid $me)"
  else
    echo "ci-machine-lock: not held by this job (holder: ${current:-none}); nothing to release"
  fi
}

case "${1:-}" in
  acquire) acquire ;;
  release) release ;;
  *) echo "usage: $0 acquire|release" >&2; exit 2 ;;
esac
