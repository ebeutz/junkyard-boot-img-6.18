#!/bin/bash
# Refresh the project's snapshot.debian.org pin: the Debian archive timestamp
# in rootfs/debian_snapshot (read by the Makefile's SNAPSHOT/MIRROR; it is what
# makes the package set reproducible).
#
# snapshot.debian.org redirects any timestamp to the canonical nearest snapshot
# (302 + Location), so we don't enumerate snapshots — we request a target instant,
# follow the redirect to the real ID, and verify the suite's Release resolves
# there before writing.
#
# Usage:
#   update-snapshot.sh                 # newest snapshot
#   update-snapshot.sh --latest
#   update-snapshot.sh --date 2026-05-01   # nearest snapshot to that day
#   update-snapshot.sh 20260501T083000Z    # canonicalize/verify an exact stamp
#   update-snapshot.sh --suite sid --latest
#   update-snapshot.sh --dry-run --date 2026-05-01   # resolve + print, don't write
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN_FILE="$ROOT/rootfs/debian_snapshot"
BASE_URL="https://snapshot.debian.org/archive/debian"

SUITE="trixie"
DRY_RUN=0
TARGET=""          # YYYYMMDDTHHMMSSZ instant to ask snapshot.d.o about; empty => now

die() { echo "update-snapshot: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl not found"

while [ $# -gt 0 ]; do
  case "$1" in
    --latest)        TARGET="" ;;
    --date)
      shift; [ $# -gt 0 ] || die "--date needs an argument (YYYY-MM-DD)"
      echo "$1" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
        || die "--date must be YYYY-MM-DD, got: $1"
      TARGET="$(echo "$1" | tr -d '-')T000000Z"
      ;;
    --suite)         shift; [ $# -gt 0 ] || die "--suite needs an argument"; SUITE="$1" ;;
    --dry-run)       DRY_RUN=1 ;;
    -h|--help)       sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    [0-9]*T[0-9]*Z)
      echo "$1" | grep -qE '^[0-9]{8}T[0-9]{6}Z$' \
        || die "explicit timestamp must be YYYYMMDDTHHMMSSZ, got: $1"
      TARGET="$1"
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

resolve_snapshot() {
  # Default target is "now" -> snapshot.d.o redirects to the most recent snapshot.
  local target="$TARGET"
  [ -n "$target" ] || target="$(date -u +%Y%m%dT%H%M%SZ)"

  echo "Resolving snapshot near $target ..." >&2
  local location new_ts code old_ts
  location="$(curl -fsS -o /dev/null -D - --max-time 60 "$BASE_URL/$target/" \
              | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r' | tail -n1)"
  [ -n "$location" ] || die "no redirect from snapshot.debian.org for $target (service down?)"

  new_ts="$(basename "$location")"
  echo "$new_ts" | grep -qE '^[0-9]{8}T[0-9]{6}Z$' \
    || die "could not parse canonical timestamp from redirect: $location"

  # Confirm the suite exists at that snapshot (follow the content-store redirect).
  code="$(curl -sL -o /dev/null -w '%{http_code}' --max-time 60 \
          "$BASE_URL/$new_ts/dists/$SUITE/Release" || true)"
  [ "$code" = "200" ] || die "suite '$SUITE' not found at snapshot $new_ts (HTTP $code)"

  old_ts="$(cat "$PIN_FILE" 2>/dev/null || true)"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "snapshot: $new_ts  (suite=$SUITE)  [dry-run, not written]"
    return 0
  fi

  printf '%s\n' "$new_ts" > "$PIN_FILE"
  if [ -n "$old_ts" ] && [ "$old_ts" != "$new_ts" ]; then
    echo "snapshot pin: $old_ts -> $new_ts"
  elif [ "$old_ts" = "$new_ts" ]; then
    echo "snapshot pin unchanged: $new_ts"
  else
    echo "snapshot pin set: $new_ts"
  fi
  echo "wrote $PIN_FILE  (suite=$SUITE)"
}

resolve_snapshot

if [ "$DRY_RUN" -eq 0 ]; then
  echo "Rebuild the rootfs (just clean_rootfs && just all) to pick up the new pin."
fi
