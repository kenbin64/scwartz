#!/usr/bin/env bash
# ============================================================================
# Schwarz Diamond → schwartzdiamond.com (static site on the shared VPS)
# ----------------------------------------------------------------------------
# schwartzdiamond.com is a PUBLIC static landing (the Schwarz Diamond principle
# + the four runnable demos), served straight from nginx — no Node service.
# DNS A records for schwartzdiamond.com + www already point at this VPS, so
# certbot can issue TLS. The docroot is butterfly-owned, so once --setup has
# created the vhost + cert, ordinary deploys need no sudo.
#
# Usage:
#   ./deploy-schwartz.sh --setup   # one-time: create vhost + issue SSL, then sync
#   ./deploy-schwartz.sh           # sync the site files (default)
#   ./deploy-schwartz.sh --reload  # reload nginx
# ============================================================================
set -euo pipefail

REMOTE="butterfly@172.81.62.217"
SSH_PORT="2222"                                  # this VPS uses SSH port 2222
DOMAIN="schwartzdiamond.com"
DOCROOT="/var/www/${DOMAIN}/public"
EMAIL="ken.bingham64@gmail.com"                  # certbot registration / renewal notices
FILES=(index.html)

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$SELF_DIR"
say() { printf '\033[36m▶ %s\033[0m\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
SSH=(ssh -p "$SSH_PORT" -o BatchMode=yes "$REMOTE")
command -v ssh >/dev/null || die "ssh not found"

sync_files() {
  for f in "${FILES[@]}"; do [ -f "$f" ] || die "missing $f"; done
  say "Syncing ${#FILES[@]} file(s) → ${REMOTE}:${DOCROOT}"
  "${SSH[@]}" "mkdir -p '$DOCROOT'"
  tar czf - "${FILES[@]}" | "${SSH[@]}" "tar xzf - -C '$DOCROOT'"
  say "Synced: $("${SSH[@]}" "ls -1 '$DOCROOT' | wc -l") file(s) in docroot"
}

case "${1:-deploy}" in
  --reload) "${SSH[@]}" "sudo nginx -t && sudo systemctl reload nginx && echo reloaded"; exit 0 ;;
  --setup)
    say "Provisioning docroot (butterfly-owned, so syncs need no sudo)"
    "${SSH[@]}" "sudo mkdir -p '$DOCROOT' && sudo chown -R butterfly:butterfly '/var/www/${DOMAIN}'"

    say "Writing nginx vhost for ${DOMAIN} (HTTP; certbot will add HTTPS)"
    VHOST_B64="$(cat <<NGINX | base64 | tr -d '\n'
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${DOCROOT};
    index index.html;
    location / { try_files \$uri \$uri.html \$uri/ =404; }
    location = /healthz { return 200 "ok"; add_header Content-Type text/plain; }
}
NGINX
)"
    "${SSH[@]}" "echo '$VHOST_B64' | base64 -d | sudo tee /etc/nginx/sites-available/${DOMAIN} >/dev/null \
      && sudo ln -sf /etc/nginx/sites-available/${DOMAIN} /etc/nginx/sites-enabled/${DOMAIN} \
      && sudo nginx -t && sudo systemctl reload nginx" || die "nginx config failed"

    sync_files

    say "Issuing TLS certificate via certbot (--nginx, with HTTP→HTTPS redirect)"
    "${SSH[@]}" "sudo certbot --nginx -d ${DOMAIN} -d www.${DOMAIN} --non-interactive --agree-tos -m ${EMAIL} --redirect" \
      || die "certbot failed — check that DNS for ${DOMAIN} resolves to this server and port 80 is open"

    say "Verifying"
    "${SSH[@]}" "curl -sf -o /dev/null -w 'https://${DOMAIN} -> %{http_code}\n' https://${DOMAIN}/ || true"
    printf '\033[32m✓ %s is live over HTTPS\033[0m\n' "$DOMAIN"
    exit 0 ;;
  --no-tests|deploy|"") : ;;
  *) die "unknown arg: $1" ;;
esac

# default: just sync + verify
sync_files
"${SSH[@]}" "curl -sf -o /dev/null -w 'https://${DOMAIN} -> %{http_code}\n' https://${DOMAIN}/ || curl -s -o /dev/null -w 'http://${DOMAIN} -> %{http_code}\n' http://${DOMAIN}/ || true"
printf '\033[32m✓ deployed → https://%s\033[0m\n' "$DOMAIN"
