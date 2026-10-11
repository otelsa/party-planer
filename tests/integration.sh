#!/bin/bash
# Verhaltenstests der Partyseite gegen einen laufenden nginx.
#
# Lokal gegen den Server:  BASE=https://otelsa.de TOKEN=$(sudo cat /etc/otelsa-party-token) \
#                          RESOLVE=127.0.0.1 tests/integration.sh
# In der CI:               BASE=http://127.0.0.1:8080 TOKEN=… tests/integration.sh
#
# Prueft: Zugang nur mit Token, neutrale Hinweisseite statt 404, Stylesheets,
# Weiterleitung, Methoden, Kopfzeilen, nichts Verraeterisches in der Vorschau,
# Rate-Limit und dass kein Token in den Logs landet.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BASE="${BASE:-http://127.0.0.1:8080}"
TOKEN="${TOKEN:?TOKEN fehlt}"
ACCESS_LOG="${ACCESS_LOG:-/var/log/nginx/access.log}"
PARTY_LOG="${PARTY_LOG:-/var/log/nginx/party.log}"

CURL=(curl -sS --max-time 10 -H 'Connection: close')
host=${BASE#*://}; host=${host%%/*}; host=${host%%:*}
[ -n "${RESOLVE:-}" ] && CURL+=(--resolve "$host:443:$RESOLVE" --resolve "$host:80:$RESOLVE")
[ -n "${INSECURE:-}" ] && CURL+=(-k)

fails=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

status() { "${CURL[@]}" -o /dev/null -w '%{http_code}' "$@" 2>/dev/null; }
ctype()  { "${CURL[@]}" -o /dev/null -w '%{content_type}' "$@" 2>/dev/null; }
body()   { "${CURL[@]}" "$@" 2>/dev/null; }
headers() { "${CURL[@]}" -o /dev/null -D - "$@" 2>/dev/null | tr -d '\r'; }

expect() { # expect NAME WANT GOT
  [ "$2" = "$3" ] && pass "$1 ($3)" || fail "$1: erwartet $2, bekommen $3"
}

echo "== Zugang"
expect "Seite mit Token"            200 "$(status "$BASE/e/$TOKEN")"
expect "Seite ist HTML"             "text/html; charset=utf-8" "$(ctype "$BASE/e/$TOKEN")"
expect "HEAD erlaubt"               200 "$(status -I "$BASE/e/$TOKEN")"
expect "Schraegstrich leitet um"    301 "$(status "$BASE/e/$TOKEN/")"
loc=$("${CURL[@]}" -o /dev/null -w '%{redirect_url}' "$BASE/e/$TOKEN/" 2>/dev/null)
[ "${loc##*/e/}" = "$TOKEN" ] && pass "Weiterleitung zeigt auf die Seite" || fail "Weiterleitung geht nach '$loc'"
expect "POST wird abgewiesen"       405 "$(status -X POST "$BASE/e/$TOKEN")"
expect "falscher Token: Hinweis"    200 "$(status "$BASE/e/dieser-token-ist-falsch")"
expect "/e/ selbst: Hinweis"        200 "$(status "$BASE/e/")"
expect "fremder Pfad bleibt 404"    404 "$(status "$BASE/wp-login.php")"

echo "== Inhalte"
page=$(body "$BASE/e/$TOKEN")
grep -q 'Projekt' <<<"$page"        && pass "Seite zeigt den Codenamen" || fail "Codename fehlt"
grep -q 'Gesamt\|gesamt' <<<"$page" && pass "Gesamtzahl vorhanden" || fail "Gesamtzahl fehlt"
grep -q 'ohne Namen' <<<"$page"     && pass "Gaeste ohne Namen werden mitgezaehlt" || fail "Option ohne Namen fehlt"
grep -qi '<title>Einladung</title>' <<<"$page" && pass "neutraler Titel" || fail "Titel verraet etwas"
grep -qi 'og:image' <<<"$page"      && fail "og:image wuerde ein Vorschaubild zeigen" || pass "kein Vorschaubild"
grep -qiE '<script|<style|[[:space:]]style=' <<<"$page" && fail "Inline-Skript/-Style verstoesst gegen die CSP" || pass "kein Inline-Skript/-Style"
hint=$(body "$BASE/e/irgendwas")
grep -q 'nicht gültig' <<<"$hint"   && pass "Hinweisseite erklaert den ungueltigen Link" || fail "Hinweistext fehlt"
grep -qi 'Projekt\|Feier\|Party'  <<<"$hint" && fail "Hinweisseite verraet den Anlass" || pass "Hinweisseite verraet nichts"

echo "== Stylesheets"
for css in party otelsa-tokens otelsa-components invalid; do
  expect "/e/$css.css"              200 "$(status "$BASE/e/$css.css")"
  expect "/e/$css.css ist CSS"      "text/css" "$(ctype "$BASE/e/$css.css")"
done
grep -q 'href="party.css"' <<<"$page" && pass "Seite laedt ihr Stylesheet ohne Token im Pfad" || fail "Stylesheet-Referenz unerwartet"

echo "== Kopfzeilen"
h=$(headers "$BASE/e/$TOKEN")
for want in \
  "content-security-policy: default-src 'none'; style-src 'self'" \
  "x-robots-tag: noindex" \
  "referrer-policy: no-referrer" \
  "x-content-type-options: nosniff" \
  "x-frame-options: DENY" \
  "cache-control: no-store" \
  "strict-transport-security: max-age=31536000"; do
  grep -qi "^${want}" <<<"$h" && pass "Kopfzeile ${want%%:*}" || fail "Kopfzeile fehlt: $want"
done
grep -qi '^server: nginx$' <<<"$h" && pass "keine nginx-Version" || fail "Server-Kopfzeile verraet die Version"

echo "== Rate-Limit"
hits=0
for _ in $(seq 1 60); do
  [ "$(status "$BASE/e/$TOKEN")" = "429" ] && hits=$((hits + 1))
done
[ "$hits" -gt 0 ] && pass "Rate-Limit greift ($hits von 60 abgewiesen)" || fail "Rate-Limit greift nicht"
sleep 2

echo "== Logs ohne Token"
if [ -r "$ACCESS_LOG" ]; then
  grep -q "$TOKEN" "$ACCESS_LOG" && fail "Token steht im Hauptlog" || pass "kein Token im Hauptlog"
  grep -q '/e/<token>' "$ACCESS_LOG" && pass "Hauptlog maskiert /e/-Pfade" || fail "Hauptlog maskiert nicht"
else
  printf 'übersprungen: %s nicht lesbar\n' "$ACCESS_LOG"
fi
if [ -r "$PARTY_LOG" ]; then
  grep -q "$TOKEN" "$PARTY_LOG" && fail "Token steht im Partylog" || pass "kein Token im Partylog"
else
  printf 'übersprungen: %s nicht lesbar\n' "$PARTY_LOG"
fi

echo
[ "$fails" -eq 0 ] && echo "alle Tests bestanden" || { echo "$fails Test(s) fehlgeschlagen"; exit 1; }
