#!/usr/bin/env bash
#
# Generates the gitignored secret files that the dev overlay's secretGenerator reads.
#
# Dev only. Staging and production get these values from GCP Secret Manager via External
# Secrets Operator, so nothing equivalent is needed there.
#
# Safe to re-run: existing files are left alone. That matters more than it looks —
# regenerating the MongoDB admin password after the database has initialised would lock
# the rotator out, because MONGO_INITDB_ROOT_PASSWORD only applies on first startup.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
overlay="${repo_root}/k8s/overlays/dev"

# shellcheck disable=SC1091
[[ -f "${repo_root}/.env" ]] && source "${repo_root}/.env"

if [[ -f "${overlay}/mongodb-admin.env" ]]; then
  echo "==> ${overlay}/mongodb-admin.env exists, leaving it alone"
else
  echo "==> writing ${overlay}/mongodb-admin.env"
  cat > "${overlay}/mongodb-admin.env" <<EOF
username=root
password=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
EOF
  chmod 600 "${overlay}/mongodb-admin.env"
fi

if [[ -f "${overlay}/upstream-api.env" ]]; then
  echo "==> ${overlay}/upstream-api.env exists, leaving it alone"
else
  if [[ -z "${TMDB_API_KEY:-}" ]]; then
    echo "!! TMDB_API_KEY is not set in ${repo_root}/.env"
    echo "   Writing an empty key; /search will return 502 until you fill it in."
  fi
  echo "==> writing ${overlay}/upstream-api.env"
  printf 'api-key=%s\n' "${TMDB_API_KEY:-}" > "${overlay}/upstream-api.env"
  chmod 600 "${overlay}/upstream-api.env"
fi

echo "==> overlay secrets ready"
