#!/usr/bin/env bash
#
# Move production Foxxers to a pushed commit and restart it.
#
#   ./scripts/deploy.sh --check         # preflight only: changes nothing anywhere
#   ./scripts/deploy.sh                 # deploy HEAD (must be pushed)
#   ./scripts/deploy.sh <commit>        # deploy that commit (also how you roll back)
#
# Production is `foxxers.service` on Proxmox: plain systemd, User=fenris,
# `node /opt/fenris/foxxers/server/index.js` on 127.0.0.1:8120, database and
# .session-key in /opt/fenris/foxxers/data. The tree there is a git clone of
# GitHub. There is no Docker in this picture; an earlier version of this script
# rsynced the Mac's working tree over the live source and then tried to start a
# container, which would have overwritten a production-only fix and left the
# host half-swapped. Audit: Plane CHG-5, 2026-11-05.
#
# What it does, in order:
#   1. Resolve the commit and insist it is on GitHub (the server pulls from there,
#      so an unpushed commit cannot be deployed and a dirty Mac tree cannot leak).
#   2. Run the test suite against THAT commit, in a throwaway worktree, not
#      against whatever happens to be in this folder.
#   3. On the server, as fenris: fetch, and refuse if the live tree has edits or
#      untracked files that the target commit does not already contain. Edits
#      that ARE already in the target are stashed (kept, not discarded).
#   4. Check out the commit, restart the unit, and wait for it to be healthy.
#   5. If it is not healthy, put the previous commit (and any stash) back,
#      restart, and exit non-zero.
#
# data/ is gitignored, so checkout never touches the database or session key.
#
# The test suite binds localhost ports, so run this outside any sandbox.
set -euo pipefail

SSH_HOST="${FOXXERS_HOST_SSH:-root@100.102.227.73}"
# An array, so a key path with a space in it still works.
read -r -a SSH_OPTS <<<"${FOXXERS_SSH_OPTS:--i $HOME/.ssh/proxmox -o ConnectTimeout=10}"
REMOTE_DIR="${FOXXERS_REMOTE_DIR:-/opt/fenris/foxxers}"
SERVICE="${FOXXERS_SERVICE:-foxxers.service}"
RUN_AS="${FOXXERS_RUN_AS:-fenris}"
HOST_PORT="${FOXXERS_HOST_PORT:-8120}"
PUBLIC_URL="${FOXXERS_PUBLIC_URL:-https://foxxers.com}"

mode=deploy
ref=HEAD
for arg in "$@"; do
  case "$arg" in
    --check) mode=check ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) ref="$arg" ;;
  esac
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

echo "==> resolve $ref"
sha="$(git rev-parse --verify --quiet "$ref^{commit}")" || { echo "Not a commit: $ref" >&2; exit 1; }
git fetch --quiet origin
if [ -z "$(git branch -r --contains "$sha" 2>/dev/null)" ]; then
  echo "$sha is not on origin. Push it first: the server deploys from GitHub." >&2
  exit 1
fi
echo "    $(git log -1 --format='%h %s' "$sha")"
if [ "$ref" = HEAD ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "    note: this folder has uncommitted edits; they are NOT deployed, only $sha is."
fi

echo "==> tests at ${sha:0:7}"
wt="$(mktemp -d "${TMPDIR:-/tmp}/foxxers-deploy.XXXXXX")"
log="$wt.log"
cleanup() { git worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"; rm -f "$log"; }
trap cleanup EXIT
git worktree add --quiet --detach "$wt" "$sha"
failed=0
for t in "$wt"/tests/*.test.js; do
  name="tests/$(basename "$t")"
  if (cd "$wt" && node "$t") >"$log" 2>&1; then
    printf '    ok   %s\n' "$name"
  else
    printf '    FAIL %s\n' "$name"
    tail -20 "$log"
    failed=1
  fi
done
[ "$failed" -eq 0 ] || { echo "Tests failed at ${sha:0:7}; not deploying."; exit 1; }

echo "==> server ($mode)"
# Quoted heredoc: nothing below expands on the Mac. Values go in as arguments.
ssh "${SSH_OPTS[@]}" "$SSH_HOST" bash -s -- \
  "$mode" "$sha" "$REMOTE_DIR" "$SERVICE" "$RUN_AS" "$HOST_PORT" <<'REMOTE'
set -euo pipefail
mode=$1 sha=$2 dir=$3 service=$4 run_as=$5 port=$6
cd "$dir"
g() { sudo -u "$run_as" -H git -C "$dir" "$@"; }

health() {
  # Up, answering, and still up a few seconds later (not a crash loop).
  local i
  for i in $(seq 1 20); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$port/api/v1/health" >/dev/null 2>&1; then
      sleep 3
      systemctl is-active --quiet "$service" &&
        curl -fsS --max-time 2 "http://127.0.0.1:$port/api/v1/health" >/dev/null 2>&1 && return 0
      return 1
    fi
    sleep 1
  done
  return 1
}

systemctl cat "$service" >/dev/null || { echo "    no unit $service on this host" >&2; exit 1; }
cur=$(g rev-parse HEAD)
g fetch --quiet origin
g cat-file -e "$sha^{commit}" 2>/dev/null || { echo "    $sha not found on the server after fetch" >&2; exit 1; }

if [ "$cur" = "$sha" ] && [ -z "$(g status --porcelain)" ]; then
  echo "    already at ${sha:0:7}, clean"
  [ "$mode" = check ] && exit 0
fi

if g merge-base --is-ancestor "$cur" "$sha"; then
  echo "    ${cur:0:7} -> ${sha:0:7}: $(g rev-list --count "$cur..$sha") commit(s) forward"
elif g merge-base --is-ancestor "$sha" "$cur"; then
  echo "    ${cur:0:7} -> ${sha:0:7}: $(g rev-list --count "$sha..$cur") commit(s) BACK (rollback)"
else
  echo "    ${cur:0:7} -> ${sha:0:7}: unrelated lines of history"
fi

# Anything on the server that is not in git must already be in the target,
# or it would be lost. Untracked files are refused outright (data/ is ignored,
# so it never shows here).
blocked=0
untracked=$(g ls-files --others --exclude-standard)
if [ -n "$untracked" ]; then
  echo "    REFUSING: untracked files in $dir:"; printf '      %s\n' $untracked; blocked=1
fi
changed=$(g diff --name-only HEAD)
for f in $changed; do
  if g diff --quiet "$sha" -- "$f"; then
    echo "    local edit to $f is already in ${sha:0:7} (will be stashed, not lost)"
  else
    echo "    REFUSING: $f is edited on the server and differs from ${sha:0:7}:"
    g diff --stat "$sha" -- "$f" | sed 's/^/      /'
    blocked=1
  fi
done
[ "$blocked" -eq 0 ] || { echo "    Commit those changes to the repo (or remove them) first."; exit 1; }

if [ "$mode" = check ]; then
  echo "    preflight OK; nothing changed."
  systemctl is-active --quiet "$service" && echo "    $service is active" || echo "    WARNING: $service is not active right now"
  exit 0
fi

stashed=
if [ -n "$changed" ]; then
  g stash push --quiet -m "deploy.sh $(date -u +%FT%TZ) before ${sha:0:7}"
  stashed=1
fi
g -c advice.detachedHead=false checkout --quiet --detach "$sha"
echo "    checked out ${sha:0:7}; restarting $service"
systemctl restart "$service"

if health; then
  echo "    healthy at ${sha:0:7} (was ${cur:0:7}; roll back with: ./scripts/deploy.sh ${cur:0:12})"
  [ -n "$stashed" ] && echo "    the old local edit is kept in: git -C $dir stash list"
  exit 0
fi

echo "    UNHEALTHY at ${sha:0:7}; rolling back to ${cur:0:7}" >&2
journalctl -u "$service" -n 20 --no-pager >&2 || true
g -c advice.detachedHead=false checkout --quiet --force "$cur"
[ -n "$stashed" ] && g stash pop --quiet
systemctl restart "$service"
if health; then echo "    rolled back; ${cur:0:7} is healthy again" >&2
else echo "    ROLLBACK ALSO UNHEALTHY. Look at: journalctl -u $service" >&2; fi
exit 1
REMOTE

if [ "$mode" = deploy ]; then
  echo "==> public"
  if curl -fsS --max-time 10 "$PUBLIC_URL/api/v1/health"; then echo
  else echo "    $PUBLIC_URL did not answer; the app is healthy locally, so check the tunnel."; fi
fi
