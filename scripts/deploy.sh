#!/bin/bash
# Spielt den Partyseiten-Prototyp aus diesem Repo auf den Server.
#
# - Webinhalte nach /var/www/otelsa/party
# - nginx-Snippets nach /etc/nginx/snippets (Token aus /etc/otelsa-party-token eingesetzt)
# Aufruf: sudo scripts/deploy.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WEB=/var/www/otelsa/party
TOKEN_FILE=/etc/otelsa-party-token

[ -r "$TOKEN_FILE" ] || { echo "fehlt: $TOKEN_FILE (Token hineinschreiben, chmod 600)" >&2; exit 1; }
TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
case "$TOKEN" in
  *[!A-Za-z0-9_-]* | "") echo "Token darf nur A-Z a-z 0-9 _ - enthalten" >&2; exit 1 ;;
esac
[ "${#TOKEN}" -ge 22 ] || { echo "Token zu kurz (mindestens 22 Zeichen)" >&2; exit 1; }

install -d -o root -g root -m 0755 "$WEB" "$WEB/e" "$WEB/invalid"
for f in party.css party.js otelsa-tokens.css otelsa-components.css; do
  install -o root -g root -m 0644 "$REPO/site/e/$f" "$WEB/e/$f"
done

# --- App ---
id -u otelsa-party >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin otelsa-party
install -d -o root -g root -m 0755 /opt/otelsa-party /opt/otelsa-party/templates
install -o root -g root -m 0644 "$REPO/app/party.py" /opt/otelsa-party/party.py
for t in party.html _live.html; do
  install -o root -g root -m 0644 "$REPO/app/templates/$t" "/opt/otelsa-party/templates/$t"
done
# Der Token muss fuer den Dienst lesbar sein, sonst nur fuer root.
chgrp otelsa-party "$TOKEN_FILE" && chmod 0640 "$TOKEN_FILE"
if [ ! -f /etc/otelsa-party.env ]; then
  install -o root -g otelsa-party -m 0640 /dev/null /etc/otelsa-party.env
  printf 'PARTY_CSRF_KEY=%s\n' "$(head -c 32 /dev/urandom | base64 | tr -d '=+/')" >> /etc/otelsa-party.env
fi
install -o root -g root -m 0644 "$REPO/deploy/systemd/otelsa-party.service" /etc/systemd/system/otelsa-party.service
install -o root -g root -m 0644 "$REPO/deploy/nginx/otelsa-party-proxy.conf" /etc/nginx/snippets/otelsa-party-proxy.conf
if [ -z "${OTELSA_NO_RELOAD:-}" ]; then
  systemctl daemon-reload
  systemctl enable --now otelsa-party.service
  systemctl restart otelsa-party.service
fi
for f in index.html invalid.css; do
  install -o root -g root -m 0644 "$REPO/site/invalid/$f" "$WEB/invalid/$f"
done

install -o root -g root -m 0644 "$REPO/deploy/nginx/otelsa-party-headers.conf" \
  /etc/nginx/snippets/otelsa-party-headers.conf
# Log-Formate und Maskierung; die nginx.conf bindet sie im http-Block ein.
install -o root -g root -m 0644 "$REPO/deploy/nginx/log-format.conf" \
  /etc/nginx/snippets/otelsa-party-log.conf
sed "s/@TOKEN@/$TOKEN/g" "$REPO/deploy/nginx/otelsa-party.conf.template" > /tmp/otelsa-party.conf
install -o root -g root -m 0640 /tmp/otelsa-party.conf /etc/nginx/snippets/otelsa-party.conf
rm -f /tmp/otelsa-party.conf

nginx -t -q
if [ -z "${OTELSA_NO_RELOAD:-}" ]; then
  systemctl reload nginx
fi
echo "Deploy ok. Seite: https://otelsa.de/e/$TOKEN"
