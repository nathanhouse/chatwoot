#!/usr/bin/env bash
# The rehearsal room: production's compose file + the live image + FAKE data, on the Mac.
#   stationx/rehearse.sh up <dir>     build it (fetches the compose file and the live image digest from the server, read-only)
#   stationx/rehearse.sh env <dir>    print the settings that point stationx/deploy.sh at it
#   stationx/rehearse.sh down <dir>   remove its containers, volumes and network (the directory stays)
# Ports: rails 127.0.0.1:3101, a stand-in nginx on 127.0.0.1:3102 (no Cloudflare lock, so a request can go through it).
# Procedure: commands/chatwoot/delivery.md § 2 (HAL).
# shellcheck disable=SC2016 # the single-quoted strings expand on the server or in nginx, on purpose
set -euo pipefail

SRV=${CW_SRV:-ssh -p 2200 root@hal.stationx.net}
PROJECT=cwreh

cmd=${1:-}; dir=${2:?usage: stationx/rehearse.sh up|env|down <dir>}
dc() { docker compose -p "$PROJECT" --project-directory "$dir" -f "$dir/docker-compose.production.yaml" "$@" 2> >(grep -v 'attribute `version` is obsolete' >&2 || true); }

case $cmd in
up)
  mkdir -p "$dir/brand-assets"
  [[ -e $dir/.env ]] && { echo "rehearse: $dir already has a .env: run 'down' and use a fresh dir" >&2; exit 1; }
  # Production's own compose file, only the host port changed so it cannot collide with anything local.
  $SRV 'cat /opt/chatwoot/docker-compose.production.yaml' </dev/null | sed "s/'127.0.0.1:3100:3000'/'127.0.0.1:3101:3000'/" >"$dir/docker-compose.production.yaml"
  grep -q "127.0.0.1:3101:3000" "$dir/docker-compose.production.yaml" || { echo "rehearse: port line not found in the server's compose file" >&2; exit 1; }
  live=$($SRV 'docker image inspect -f "{{index .RepoDigests 0}}" "$(docker inspect -f "{{.Image}}" chatwoot-rails-1)"' </dev/null)
  umask 077
  cat >"$dir/.env" <<EOF
# FAKE secrets for the rehearsal room, generated $(date -u +%FT%TZ). Never used anywhere else.
SECRET_KEY_BASE=$(openssl rand -hex 64)
FRONTEND_URL=http://localhost:3101
FORCE_SSL=false
ENABLE_ACCOUNT_SIGNUP=false
REDIS_URL=redis://redis:6379
REDIS_PASSWORD=$(openssl rand -hex 16)
POSTGRES_HOST=postgres
POSTGRES_USERNAME=postgres
POSTGRES_PASSWORD=$(openssl rand -hex 16)
RAILS_ENV=production
RAILS_LOG_TO_STDOUT=true
ACTIVE_STORAGE_SERVICE=local
DISABLE_ENTERPRISE=true
EOF
  printf 'server {\n  listen 80;\n  location / { proxy_pass http://%s-rails-1:3000; proxy_set_header Host $host; }\n}\n' "$PROJECT" >"$dir/nginx.conf"
  docker pull --quiet --platform linux/amd64 "$live" >/dev/null
  docker tag "$live" ghcr.io/nathanhouse/chatwoot:stationx-main
  echo "live image: $live"
  dc up -d postgres redis
  until dc exec -T postgres pg_isready -U postgres >/dev/null 2>&1; do sleep 2; done
  dc run --rm rails bundle exec rails db:chatwoot_prepare >/dev/null
  # Fake data: one account, and onboarding marked done so /app/login renders like production.
  dc run --rm rails bundle exec rails runner \
    'Account.create!(name: "Rehearsal (fake data)"); Redis::Alfred.delete(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)' >/dev/null
  dc up -d --pull never rails sidekiq
  docker run -d --name "$PROJECT-nginx" --network "${PROJECT}_default" -p 127.0.0.1:3102:80 \
    -v "$dir/nginx.conf:/etc/nginx/conf.d/default.conf:ro" nginx:1.30.6-alpine >/dev/null
  until curl -sf -o /dev/null http://127.0.0.1:3101/api; do sleep 3; done
  echo "up: rails http://127.0.0.1:3101 · nginx http://127.0.0.1:3102 · schema $(dc exec -T postgres psql -U postgres -d chatwoot_production -tAc 'select max(version) from schema_migrations')"
  ;;
env)
  printf 'export CW_SSH="" CW_DIR=%q CW_PORT=3101 CW_NGINX=%s-nginx CW_PUBLIC="" COMPOSE_PROJECT_NAME=%s\n' "$dir" "$PROJECT" "$PROJECT"
  ;;
down)
  docker rm -f "$PROJECT-nginx" >/dev/null 2>&1 || true
  dc down -v --remove-orphans
  ;;
*) sed -n '2,5p' "$0"; exit 2 ;;
esac
