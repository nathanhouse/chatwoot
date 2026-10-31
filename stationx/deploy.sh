#!/usr/bin/env bash
# Deploy, smoke-test or roll back OUR Chatwoot image on the server. Run from the Mac, inside this repo.
#   stationx/deploy.sh deploy <commit-sha> <image@sha256:digest> --expect <n> --go "<Nathan's words>" [--from <sha>] [--migrate]
#   stationx/deploy.sh smoke [--since <UTC time>]
#   stationx/deploy.sh rollback [--accept-schema]
#   stationx/deploy.sh status
# Procedure, pre-flight and what to do when it fails: commands/chatwoot/delivery.md (HAL).
#
# How it swaps the image: the compose file runs ghcr.io/nathanhouse/chatwoot:stationx-main. The deploy pulls
# the exact digest, re-points that tag on the box at it, and recreates rails + sidekiq with --pull never, so the
# compose file itself never changes. Every deploy and rollback is a line in $CW_DIR/.stationx-deploy/history.tsv:
# the image that was live before it is the rollback target.
#
# Settings (defaults = production). The local rehearsal overrides them:
#   CW_SSH      how to reach the box ("" = run locally)       CW_DIR      compose directory on the box
#   CW_COMPOSE  compose file name                             CW_PORT     host port rails listens on
#   CW_NGINX    nginx container to reload ("" = none)         CW_PUBLIC   public URL ("" = skip the edge check)
#   CW_DB       Postgres database
set -euo pipefail

REPO=ghcr.io/nathanhouse/chatwoot
CW_SSH=${CW_SSH-ssh -p 2200 root@hal.stationx.net}
CW_DIR=${CW_DIR-/opt/chatwoot}
CW_COMPOSE=${CW_COMPOSE-docker-compose.production.yaml}
CW_PORT=${CW_PORT-3100}
CW_NGINX=${CW_NGINX-nginx-proxy}
CW_PUBLIC=${CW_PUBLIC-https://support.stationx.net}
CW_DB=${CW_DB-chatwoot_production}

die() { echo "deploy: $*" >&2; exit 1; }

# Run a script on the box (or locally when CW_SSH is empty), with the settings passed in as variables.
box() {
  local prelude
  prelude=$(printf 'set -Eeuo pipefail\nREPO=%q CW_DIR=%q CW_COMPOSE=%q CW_PORT=%q CW_NGINX=%q CW_DB=%q\n' \
    "$REPO" "$CW_DIR" "$CW_COMPOSE" "$CW_PORT" "$CW_NGINX" "$CW_DB")
  # The script goes in as an argument, never on stdin: `docker compose exec` reads stdin and would swallow
  # the rest of a piped script, ending it early with exit 0 (caught in the first test run, 2026-10-31).
  if [[ -n $CW_SSH ]]; then
    # shellcheck disable=SC2086 # CW_SSH is a command line on purpose
    $CW_SSH "bash -c $(printf %q "$prelude"$'\n'"$*")" </dev/null
  else
    bash -c "$prelude"$'\n'"$*" </dev/null
  fi
}

# Shared remote functions: compose wrapper, schema read, and the smoke test the deploy and rollback both run.
read -r -d '' REMOTE_LIB <<'LIB' || true
cd "${CW_DIR:?}"
STATE=.stationx-deploy; HIST=$STATE/history.tsv
dc() { docker compose -f "${CW_COMPOSE:?}" "$@" 2> >(grep -v 'attribute `version` is obsolete' >&2 || true); }
fail() { echo "FAIL: $*" >&2; exit 1; }
# Any other command that fails stops the script too (set -e): say which, never stop silently.
trap 'echo "FAIL: line $LINENO: $BASH_COMMAND" >&2' ERR
ok() { echo "  ok  $*"; }
# Highest applied Rails migration. Empty or unreadable is an error, never "no migrations" (fail-safe).
schema_max() {
  local v
  v=$(dc exec -T postgres psql -U postgres -d "${CW_DB:?}" -tAc 'select max(version) from schema_migrations') || fail "cannot read schema_migrations"
  [[ $v =~ ^[0-9]{14}$ ]] || fail "schema_migrations gave '$v'"
  echo "$v"
}
running_image() { docker inspect -f '{{.Image}}' "$(dc ps -q "$1")"; }
smoke() {
  local want=$1 code body i rails_id
  echo "smoke:"
  for i in $(seq 1 60); do
    body=$(curl -s --max-time 5 "http://127.0.0.1:${CW_PORT:?}/api" || true)
    [[ $body == *'"data_services":"ok"'* && $body == *'"queue_services":"ok"'* ]] && break
    [[ $i == 60 ]] && fail "/api not healthy after 180s: ${body:0:200}"
    sleep 3
  done
  ok "/api healthy: $body"
  code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$CW_PORT/api/v1/stationx-smoke-no-such-route")
  [[ $code == 404 ]] || fail "unknown route gave $code, expected 404 (control)"
  ok "unknown route 404 (control)"
  body=$(curl -s --max-time 10 "http://127.0.0.1:$CW_PORT/app/login")
  asset=$(grep -o 'src="/vite/assets/[^"]*\.js"' <<<"$body" | head -1 | cut -d'"' -f2 || true)
  [[ -n $asset ]] || fail "login page has no /vite/assets script"
  code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$CW_PORT$asset")
  [[ $code == 200 ]] || fail "$asset gave $code"
  ok "login page + its script $asset"
  for svc in rails sidekiq; do
    [[ $(running_image "$svc") == "$want" ]] || fail "$svc runs $(running_image "$svc"), expected $want"
    [[ $(docker inspect -f '{{.State.Running}} {{.RestartCount}}' "$(dc ps -q "$svc")") == "true 0" ]] || fail "$svc not running cleanly"
  done
  ok "rails + sidekiq run ${want:0:19} (running, 0 restarts)"
  [[ $(dc exec -T rails bundle exec rails runner 'print Account.count' 2>/dev/null | tail -1) =~ ^[1-9][0-9]*$ ]] || fail "rails runner could not read Account.count"
  ok "real read through the app (Account.count >= 1)"
  if [[ -n $CW_NGINX ]]; then
    # The vhost only admits Cloudflare's IPs, so the smoke cannot send its own request through nginx. Instead:
    # nginx's DNS sees the new container, and nginx logged no failed connection to it since the deploy began
    # (a stale upstream IP shows up there as soon as any open Chatwoot tab reconnects).
    rails_id=$(dc ps -q rails)
    ip=$(docker exec "$CW_NGINX" getent hosts "$(docker inspect -f '{{.Name}}' "$rails_id" | tr -d /)" | awk '{print $1}')
    [[ -n $ip && " $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$rails_id") " == *" $ip "* ]] || fail "nginx resolves rails to '$ip', not the new container"
    ok "nginx resolves rails to its current IP $ip"
    logs=$(docker logs --since "${SMOKE_SINCE:-10m}" "$CW_NGINX" 2>&1) || fail "cannot read the nginx log"
    errs=$(grep 'connect() failed' <<<"$logs" | grep -c ":3000/" || true)
    [[ $errs == 0 ]] || fail "nginx logged $errs failed connection(s) to rails since ${SMOKE_SINCE:-10m ago}: stale upstream? reload nginx"
    ok "no failed nginx connections to rails since ${SMOKE_SINCE:-10m ago}"
  fi
}
# A recreated rails gets a new IP; nginx keeps the old one until reloaded: 502s (2026-07-12). A failed config test
# must stop the deploy, not skip the reload (review 2026-10-31). The smoke counts nginx errors only from here on.
reload_nginx() {
  [[ -n $CW_NGINX ]] || return 0
  docker exec "$CW_NGINX" nginx -t -q || fail "nginx config test failed: NOT reloaded, rails may be unreachable (delivery.md § 14)"
  docker exec "$CW_NGINX" nginx -s reload || fail "nginx reload failed (delivery.md § 14)"
  SMOKE_SINCE=$(date -u +%FT%TZ)
}
LIB

cmd=${1:-}; shift || true
case $cmd in
deploy)
  sha_arg=${1:?usage: deploy <commit-sha> <image@sha256:...> --expect <n> --go <words> [--from <sha>] [--migrate]}
  image=${2:?image reference required}; shift 2
  expect="" from="" migrate=0 go=""
  while (($#)); do
    case $1 in
      --expect) expect=${2:?}; shift 2 ;;
      --from) from=${2:?}; shift 2 ;;
      --migrate) migrate=1; shift ;;
      --go) go=${2:?}; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [[ $expect =~ ^[0-9]+$ ]] || die "--expect <n> is required: the number of commits you named in the go"
  # RULE 0: production needs Nathan's named go. The script cannot check the words are his; it records them.
  [[ -n $go ]] || die "--go \"<Nathan's exact words>\" is required; it is written to the deploy history"
  [[ $go != *$'\t'* && $go != *$'\n'* ]] || die "--go text cannot contain tabs or newlines"
  # Production deploys by digest only, so what was reviewed is exactly what runs.
  [[ -z $CW_SSH || $image == "$REPO@sha256:"* ]] || die "deploy by digest: $REPO@sha256:..."

  git fetch --quiet origin stationx-main
  sha=$(git rev-parse --verify "${sha_arg}^{commit}") || die "unknown commit $sha_arg"
  if [[ ${CW_ALLOW_UNMERGED:-0} != 1 ]]; then
    git merge-base --is-ancestor "$sha" FETCH_HEAD || die "$sha is not on origin/stationx-main"
  fi
  if [[ -z $from ]]; then
    # shellcheck disable=SC2016 # expands on the box
    # The live commit = the commit column of the last line that finished: 'ok' or 'rollback'.
    from=$(box 'cd "$CW_DIR"; [[ -f .stationx-deploy/history.tsv ]] && awk -F"\t" '"'"'$2=="ok"||$2=="rollback"{c=$3} END{print c}'"'"' .stationx-deploy/history.tsv || true')
    [[ -n $from ]] || die "no deploy history on the box yet: pass --from <the commit that is live>"
  fi
  # Stored in history and re-read by the next deploy: a full id, never a name like HEAD~3 (review 2026-10-31).
  from=$(git rev-parse --verify "${from}^{commit}") || die "unknown --from commit $from"
  # Count the range: what ships must be exactly what was named.
  count=$(git rev-list --count "$from..$sha")
  echo "range ${from:0:10}..${sha:0:10}: $count commit(s)"
  git log --oneline "$from..$sha" | sed 's/^/  /'
  [[ $count == "$expect" ]] || die "range has $count commit(s), the go named $expect: stop"

  if ! out=$(box "$REMOTE_LIB"$'\n'"$(printf 'SHA=%q FROM=%q IMAGE=%q MIGRATE=%q GO=%q\n' "$sha" "$from" "$image" "$migrate" "$go")"$'\n'"$(cat <<'REMOTE'
mkdir -p "$STATE"; chmod 700 "$STATE"
# The pull needs room (the image is ~1.5 GB) and so does the dump.
free_kb=$(df -Pk . | awk 'NR==2{print $4}')
(( free_kb > 5 * 1024 * 1024 )) || fail "only $((free_kb / 1024)) MB free under $CW_DIR: need 5 GB before deploying"
mkdir "$STATE/lock" 2>/dev/null || fail "another deploy holds $CW_DIR/$STATE/lock"
trap 'rmdir "$STATE/lock"' EXIT
# A history ending in 'deploy' = the last deploy never passed its smoke. Deploying over it would record the broken
# image as the rollback target (review 2026-10-31): roll back (or settle it by hand) first.
if [[ -s $HIST && $(tail -1 "$HIST" | cut -f2) == deploy ]]; then fail "the last deploy never finished: run 'rollback' or settle it by hand first"; fi
prev_id=$(running_image rails)
prev_ref=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$prev_id" | grep "^$REPO@" | head -1 || true)
prev_ref=${prev_ref:-$prev_id}
before=$(schema_max)
echo "live now: $prev_ref (schema $before)"
[[ $IMAGE == *@sha256:* ]] && docker pull --quiet --platform linux/amd64 "$IMAGE" >/dev/null
new_id=$(docker image inspect -f '{{.Id}}' "$IMAGE")
rev=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$new_id")
[[ $rev == "$SHA" ]] || fail "image was built from '$rev', not $SHA"
[[ $new_id != "$prev_id" ]] || fail "that image is already live"
# From here the tag points at the new image (running containers are unaffected until the recreate). If the deploy
# stops before rails is recreated, put the tag back so a later restart cannot pick up an unshipped image.
trap 'rmdir "$STATE/lock"; [[ $(running_image rails) == "$prev_id" ]] && docker tag "$prev_id" "$REPO:stationx-main"' EXIT
docker tag "$new_id" "$REPO:stationx-main"

# Completion gate: ask the NEW image which migrations it would run against the live database, before anything
# changes. A deploy that needs migrations and skips them 500s; one run on a live app needs the recreate below
# (2026-09-18: ai_assignee_type).
status=$(dc run --rm --no-deps rails bundle exec rails db:migrate:status 2>/dev/null) || fail "the new image could not read migration status"
pending=$(grep -cE '^\s*down\s' <<<"$status" || true)
echo "migrations the new image would run: $pending"
grep -E '^\s*down\s' <<<"$status" | sed 's/^/  /' || true
if [[ $pending != 0 && $MIGRATE != 1 ]]; then fail "$pending pending migration(s): re-run with --migrate (named in the go)"; fi

# Snapshot: a pg_dump before every deploy (the DB is ~150 MB, ~5 s). Confirmed by reading it back, never by name.
dump="$STATE/pre-${SHA:0:12}-$(date -u +%Y%m%dT%H%M%SZ).dump"
dc exec -T postgres pg_dump -U postgres -Fc "$CW_DB" >"$dump"; chmod 600 "$dump"
tables=$(dc exec -T postgres pg_restore --list <"$dump" | grep -c ' TABLE public ' || true)
[[ $tables -ge 50 ]] || fail "pre-deploy dump $dump lists $tables tables (expected >= 50): not deploying"
echo "snapshot: $dump ($(du -h "$dump" | cut -f1), $tables tables)"

# Record the rollback target BEFORE anything changes. Columns: time action commit image image-id
# prev-commit prev-image prev-image-id schema-before dump go-words. 'deploy' = started, 'ok' = smoke passed.
line() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$SHA" "$IMAGE" "$new_id" "$FROM" "$prev_ref" "$prev_id" "$before" "$dump" "$GO" >>"$HIST"; }
line deploy
echo "HISTORY: deploy recorded (from here a failure needs 'rollback')"
if [[ $MIGRATE == 1 ]]; then
  echo "migrations (db:chatwoot_prepare):"
  dc run --rm rails bundle exec rails db:chatwoot_prepare
fi
# Recreating rails + sidekiq also clears the column cache a migration leaves stale (2026-09-18).
dc up -d --no-deps --pull never rails sidekiq
reload_nginx
smoke "$new_id"
after=$(schema_max)
line ok
echo "DEPLOYED ${SHA:0:12} (schema $before -> $after). Rollback target: $prev_ref"
REMOTE
)" | tee /dev/stderr); then
    # Only a deploy that wrote its history line can have changed anything; before that, rollback would undo the
    # PREVIOUS good deploy (review 2026-10-31).
    [[ $out == *"HISTORY: deploy recorded"* ]] || die "this deploy was refused before changing anything, so rollback would NOT be undoing it: follow the FAIL line above"
    die "deploy did not finish: the box may be part-way. Run 'stationx/deploy.sh status', then 'rollback' (commands/chatwoot/delivery.md § 11)"
  fi

  # Registry writes only for the real server: a rehearsal must never move the production tag.
  if [[ -n $CW_SSH && $image == "$REPO@sha256:"* ]]; then
    # Keep the registry tag on what is live, so a plain 'compose pull' cannot bring back an older image.
    docker buildx imagetools create --tag "$REPO:stationx-main" "$image" >/dev/null
    echo "  ok  $REPO:stationx-main now points at the deployed digest"
  fi
  if [[ -n $CW_PUBLIC ]]; then
    code=$(curl -s --max-time 15 -o /dev/null -w '%{http_code} %{redirect_url}' "$CW_PUBLIC/api")
    [[ $code == "302 https://"*".cloudflareaccess.com/"* ]] || die "public URL gave '$code', expected the Cloudflare Access login"
    echo "  ok  public URL answers through Cloudflare Access"
  fi
  ;;

smoke)
  # --since <UTC time>: only count nginx errors after it (e.g. after fixing a stale upstream by hand).
  since=""; [[ ${1:-} == --since ]] && since=${2:?--since needs a time like 2026-10-31T08:00:00Z}
  # shellcheck disable=SC2016 # expands on the box
  box "$REMOTE_LIB"$'\n'"SMOKE_SINCE=$(printf %q "${since:-10m}")"$'\n''smoke "$(running_image rails)"'
  ;;

rollback)
  accept=0; [[ ${1:-} == --accept-schema ]] && accept=1
  ref=$(box "$REMOTE_LIB"$'\n'"ACCEPT=$accept"$'\n'"$(cat <<'REMOTE'
[[ -s $HIST ]] || fail "no deploy history: nothing recorded to roll back to"
mkdir "$STATE/lock" 2>/dev/null || fail "another deploy holds $CW_DIR/$STATE/lock"
trap 'rmdir "$STATE/lock"' EXIT
# The last line is the deploy to undo: 'deploy' (it failed part-way) or 'ok' (it finished). Its prev-* columns
# are what ran before it. A deploy that failed before recreating anything leaves the old image running: fine.
IFS=$'\t' read -r _ action sha ref new_id prev_sha prev_ref prev_id before dump _go < <(tail -1 "$HIST")
[[ $action == deploy || $action == ok ]] || fail "last history line is '$action', not a deploy: check by hand"
live=$(running_image rails)
[[ $live == "$new_id" || $live == "$prev_id" ]] || fail "rails runs $live, which no recorded deploy knows: check by hand"
now=$(schema_max)
# The old image may not understand a schema migrated forward. Restoring the DB is a separate, data-losing step.
if [[ $now != "$before" && $ACCEPT != 1 ]]; then
  fail "schema moved $before -> $now since the previous image ran (pre-deploy dump: $dump). See delivery.md § 11 before --accept-schema"
fi
docker image inspect "$prev_id" >/dev/null 2>&1 || docker pull --quiet --platform linux/amd64 "$prev_ref" >/dev/null
docker tag "$prev_id" "$REPO:stationx-main"
dc up -d --no-deps --pull never rails sidekiq
reload_nginx
smoke "$prev_id"
printf '%s\trollback\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$prev_sha" "$prev_ref" "$prev_id" "$sha" "$ref" "$new_id" "$now" "-" >>"$HIST"
echo "ROLLED BACK to $prev_ref (was ${sha:0:12})"
echo "ROLLBACK_REF=$prev_ref"
REMOTE
)" | tee /dev/stderr | sed -n "s/^ROLLBACK_REF=//p")
  if [[ -n $CW_SSH && $ref == "$REPO@sha256:"* ]]; then
    # Same as after a deploy: the registry tag follows what is live.
    docker buildx imagetools create --tag "$REPO:stationx-main" "$ref" >/dev/null
    echo "  ok  $REPO:stationx-main now points at $ref"
  fi
  ;;

status)
  box "$REMOTE_LIB"$'\n'"$(cat <<'REMOTE'
echo "rails runs:   $(running_image rails)"
echo "sidekiq runs: $(running_image sidekiq)"
echo "schema max:   $(schema_max)"
[[ -d $STATE/lock ]] && echo "LOCK HELD: $CW_DIR/$STATE/lock (a deploy is running or died part-way)"
echo "history (time, action, commit, image, image id, previous commit, previous image, previous id, schema before, dump, go):"
tail -5 "$HIST" 2>/dev/null || echo "  (none yet)"
REMOTE
)"
  ;;

*) sed -n '2,6p' "$0"; exit 2 ;;
esac
