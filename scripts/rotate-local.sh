#!/usr/bin/env bash
#
# Simulates one credential rotation against the local Compose stack.
#
# This performs exactly the same steps as the Kubernetes CronJob (rotator/src/rotate.py):
# rotate the INACTIVE user, verify the new credential authenticates, and only then
# publish it where the application will pick it up. In-cluster "publish" means patching a
# Secret; here it means writing the mounted files.
#
# Use it to watch the hot swap happen without needing a cluster.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
creds_dir="${repo_root}/local/mongo-credentials"
database="lumana"

# shellcheck disable=SC1091
source "${repo_root}/.env"

current="$(cat "${creds_dir}/username")"
if [[ "${current}" == "app_a" ]]; then target="app_b"; else target="app_a"; fi

new_password="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
echo "==> active user is ${current}, rotating ${target}"

docker compose exec -T mongodb mongosh --quiet \
  -u root -p "${MONGO_ROOT_PASSWORD}" --authenticationDatabase admin \
  "${database}" --eval "db.updateUser('${target}', { pwd: '${new_password}' })" >/dev/null
echo "==> password updated in mongodb"

# Verify before publishing. If this fails the script aborts and the application keeps
# using the previous credential, which is still valid.
docker compose exec -T mongodb mongosh --quiet \
  -u "${target}" -p "${new_password}" --authenticationDatabase "${database}" \
  "${database}" --eval "db.adminCommand('ping').ok" >/dev/null
echo "==> verified ${target} authenticates"

printf '%s' "${target}" > "${creds_dir}/username"
printf '%s' "${new_password}" > "${creds_dir}/password"
echo "==> published new credential; the app should swap within ~5s"
