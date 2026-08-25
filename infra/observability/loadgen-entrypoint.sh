#!/bin/sh
# loadgen wrapper. Chowns /runs to the k6 user (uid 12345) so the
# k6 process can write summary files into it, then execs whatever
# the operator asked for.
#
# Used as the entrypoint of the bench-load service. The trial driver
# overrides the command per-invocation; this wrapper only handles
# the /runs permission issue.
set -eu

# Ensure /runs exists and is writable by uid 12345. /runs is a named
# volume; on first creation the volume is root-owned, which k6 (uid
# 12345) cannot write to.
if [ -d /runs ]; then
  chown -R 12345:12345 /runs 2>/dev/null || true
fi

# The compose service sets `entrypoint: [sleep, infinity]`, but when
# the trial driver runs k6 via `docker exec`, the exec'd command
# inherits this entrypoint's environment. We just need the chown
# to happen; everything else is up to the exec'd process.
exec "$@"
