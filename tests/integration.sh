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

sess=$(mktemp -d); trap 'rm -rf "$sess"' EXIT

echo "== Zugang"
expect "Gruppenlink tauscht gegen Sitzung" 303 "$(status -c "$sess/jar" "$BASE/e/$TOKEN")"
loc=$("${CURL[@]}" -c "$sess/jar" -o /dev/null -w '%{redirect_url}' "$BASE/e/$TOKEN" 2>/dev/null)
[ "${loc%%\?*}" = "$BASE/party" ] && pass "Einstieg leitet auf /party" || fail "Einstieg geht nach '$loc'"
expect "Seite mit Sitzung"          200 "$(status -b "$sess/jar" "$BASE/party")"
expect "ohne Sitzung keine Seite"   303 "$(status "$BASE/party")"
expect "falscher Token: Hinweis"    200 "$(status "$BASE/e/dieser-token-ist-falsch")"
expect "/e/ selbst: Hinweis"        200 "$(status "$BASE/e/")"
expect "fremder Pfad bleibt 404"    404 "$(status "$BASE/wp-login.php")"
expect "Landingpage unberuehrt"     200 "$(status "$BASE/")"

echo "== Cookie"
ck=$(headers -c "$sess/jar2" "$BASE/e/$TOKEN" | grep -i '^set-cookie' || true)
[ "$(grep -c . <<<"$ck")" = "1" ] && pass "genau ein Cookie" || fail "unerwartete Anzahl Cookies"
grep -qi 'party_sid=' <<<"$ck"  && pass "Sitzungs-Cookie gesetzt" || fail "Sitzungs-Cookie fehlt"
grep -qi 'httponly'   <<<"$ck"  && pass "HttpOnly" || fail "HttpOnly fehlt"
grep -qi 'samesite=lax' <<<"$ck" && pass "SameSite=Lax" || fail "SameSite fehlt"
case "$BASE" in https://*) grep -qi 'secure' <<<"$ck" && pass "Secure" || fail "Secure fehlt" ;; esac
headers -b "$sess/jar" "$BASE/party" | grep -qi '^set-cookie' \
  && fail "Folgeaufruf setzt erneut ein Cookie" || pass "Folgeaufruf ohne neues Cookie"

echo "== Inhalte"
page=$("${CURL[@]}" -b "$sess/jar" "$BASE/party")
grep -q 'Projekt' <<<"$page"        && pass "Seite zeigt den Codenamen" || fail "Codename fehlt"
grep -q 'Anzeigen als' <<<"$page"   && pass "Feld 'Anzeigen als'" || fail "Feld 'Anzeigen als' fehlt"
grep -q 'name="anzahl"' <<<"$page"  && pass "Feld 'Anzahl'" || fail "Feld 'Anzahl' fehlt"
grep -q 'Personen gesamt' <<<"$page" && pass "Gesamtzahl vorhanden" || fail "Gesamtzahl fehlt"
grep -qi 'Cookie' <<<"$page"        && pass "Seite erklaert das Cookie" || fail "Cookie-Hinweis fehlt"
grep -q 'Link aus der WhatsApp-Gruppe' <<<"$page" && pass "Hinweis zum Gruppenlink" || fail "Hinweis fehlt"
grep -q 'name="csrf"' <<<"$page"    && pass "Formulare tragen ein CSRF-Token" || fail "CSRF-Token fehlt"
grep -q 'id="live" data-stand=' <<<"$page" && pass "veraenderlicher Teil ist abgegrenzt" || fail "Bereich 'live' fehlt"
grep -q 'src="/e/party.js"' <<<"$page" && pass "Seite laedt das Aktualisierungs-Skript" || fail "Skript fehlt"
grep -qi '<title>Einladung</title>' <<<"$page" && pass "neutraler Titel" || fail "Titel verraet etwas"
grep -qi 'og:image' <<<"$page"      && fail "og:image wuerde ein Vorschaubild zeigen" || pass "kein Vorschaubild"
# Erlaubt ist nur <script src="..."> aus eigener Quelle; Inline waere von der CSP blockiert.
grep -qiE '<style|[[:space:]]style=|[[:space:]]on[a-z]+=' <<<"$page" && fail "Inline-Style verstoesst gegen die CSP" || pass "kein Inline-Style"
grep -qE '<script[^>]*>[^<]' <<<"$page" && fail "Inline-Skript verstoesst gegen die CSP" || pass "kein Inline-Skript"
grep -qiE 'PIN|persönlichen Link|/me/' <<<"$page" && fail "PIN oder persoenlicher Link vorhanden" || pass "weder PIN noch persoenlicher Link"
hint=$(body "$BASE/e/irgendwas")
grep -q 'nicht gültig' <<<"$hint"   && pass "Hinweisseite erklaert den ungueltigen Link" || fail "Hinweistext fehlt"
grep -qi 'Projekt\|Feier\|Party'  <<<"$hint" && fail "Hinweisseite verraet den Anlass" || pass "Hinweisseite verraet nichts"

echo "== Dateien"
expect "/e/party.js"                200 "$(status "$BASE/e/party.js")"
case "$(ctype "$BASE/e/party.js")" in *javascript*) pass "/e/party.js ist JavaScript" ;; *) fail "/e/party.js hat falschen Typ" ;; esac

echo "== Stylesheets"
for css in party otelsa-tokens otelsa-components invalid; do
  expect "/e/$css.css"              200 "$(status "$BASE/e/$css.css")"
  expect "/e/$css.css ist CSS"      "text/css" "$(ctype "$BASE/e/$css.css")"
done

echo "== Kopfzeilen"
h=$(headers -b "$sess/jar" "$BASE/party")
for want in \
  "content-security-policy: default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'" \
  "x-robots-tag: noindex" \
  "referrer-policy: no-referrer" \
  "x-content-type-options: nosniff" \
  "x-frame-options: DENY" \
  "cache-control: no-store"; do
  grep -qi "^${want}" <<<"$h" && pass "Kopfzeile ${want%%:*}" || fail "Kopfzeile fehlt: $want"
done
grep -qi '^server: nginx$' <<<"$h" && pass "keine nginx-Version" || fail "Server-Kopfzeile verraet die Version"
grep -qi 'x-robots-tag: noai' <<<"$h" && pass "KI-Crawler ausgeschlossen" || fail "noai fehlt"

echo "== Rate-Limit"
hits=0
for _ in $(seq 1 60); do
  [ "$(status "$BASE/e/party.css")" = "429" ] && hits=$((hits + 1))
done
[ "$hits" -gt 0 ] && pass "Rate-Limit greift ($hits von 60 abgewiesen)" || fail "Rate-Limit greift nicht"
sleep 2

echo "== Logs ohne Token"
if [ -r "$ACCESS_LOG" ]; then
  grep -q "$TOKEN" "$ACCESS_LOG" && fail "Token steht im Hauptlog" || pass "kein Token im Hauptlog"
  # /e/-Zugriffe laufen in party.log; die Maskierung im Hauptlog ist der Fallback fuer
  # Antworten ausserhalb dieser Locations - also nur pruefen, wenn es solche Zeilen gibt.
  if grep -q ' /e/' "$ACCESS_LOG"; then
    grep -q '/e/<token>' "$ACCESS_LOG" && pass "Hauptlog maskiert /e/-Pfade" || fail "Hauptlog maskiert nicht"
  else
    pass "keine /e/-Zeilen im Hauptlog (laufen in party.log)"
  fi
else
  printf 'übersprungen: %s nicht lesbar\n' "$ACCESS_LOG"
fi
if [ -r "$PARTY_LOG" ]; then
  grep -q '/e/<token>' "$PARTY_LOG" && pass "Partylog schreibt /e/<token>" || fail "Partylog ohne maskierten Pfad"
fi
if [ -d /var/log/nginx ]; then
  found=$(grep -rl "$TOKEN" /var/log/nginx/ 2>/dev/null || true)
  [ -z "$found" ] && pass "kein Token in /var/log/nginx" || fail "Token in: $found"
fi

# ---------------------------------------------------------------- Ablauf
# Schreibt echte Eintraege und raeumt sie am Ende wieder weg. Deshalb nur mit FLOW=1
# (die CI setzt es; gegen den Produktivserver nur bewusst starten).
if [ "${FLOW:-0}" = "1" ]; then
  echo "== Ablauf: zwei Geraete"
  jar=$(mktemp -d); trap 'rm -rf "$jar"' EXIT
  csrf_of() { "${CURL[@]}" -b "$1" -c "$1" "$BASE/party" | grep -o 'name="csrf" value="[^"]*"' | head -1 | cut -d'"' -f4; }
  post() { jarfile=$1; shift; "${CURL[@]}" -b "$jarfile" -c "$jarfile" -o /dev/null -w '%{http_code}' "$@"; }

  code=$("${CURL[@]}" -c "$jar/a" -o /dev/null -w '%{http_code}' "$BASE/e/$TOKEN")
  expect "A: Einstieg setzt Sitzung" 303 "$code"
  grep -q 'party_sid' "$jar/a" && pass "A: Cookie gesetzt" || fail "A: kein Cookie"
  ca=$(csrf_of "$jar/a")
  expect "A: anmelden" 303 "$(post "$jar/a" -d "csrf=$ca&status=ja&ankunft=beginn&anzeigename=Test A&anzahl=2" "$BASE/party/eintrag")"
  expect "A: Mitbringsel" 303 "$(post "$jar/a" -d "csrf=$ca&text=Testsalat&kategorie=Essen" "$BASE/party/mitbringsel")"

  "${CURL[@]}" -c "$jar/b" -o /dev/null "$BASE/e/$TOKEN"
  cb=$(csrf_of "$jar/b")
  expect "B: anmelden" 303 "$(post "$jar/b" -d "csrf=$cb&status=vielleicht&ankunft=beginn&anzeigename=Test B&anzahl=1" "$BASE/party/eintrag")"

  seite_a=$("${CURL[@]}" -b "$jar/a" "$BASE/party")
  seite_b=$("${CURL[@]}" -b "$jar/b" "$BASE/party")
  grep -q 'Angemeldet als <strong>Test A' <<<"$seite_a" && pass "A wird wiedererkannt" || fail "A wird nicht wiedererkannt"
  grep -q 'Angemeldet als <strong>Test B' <<<"$seite_b" && pass "B wird als eigener Gast gefuehrt" || fail "B nicht erkannt"
  grep -q 'Test B' <<<"$seite_a" && pass "A sieht den Eintrag von B" || fail "A sieht B nicht"
  [ "$(grep -c 'class="is-own"' <<<"$seite_a")" -ge 2 ] && pass "A sieht eigene Eintraege markiert" || fail "A: eigene Eintraege nicht markiert"
  [ "$(grep -c 'class="is-own"' <<<"$seite_b")" = "1" ] && pass "B sieht nur den eigenen Eintrag markiert" || fail "B: falsche Markierung"
  grep -q 'Testsalat' <<<"$seite_b" && pass "B sieht das Mitbringsel von A" || fail "Mitbringsel fehlt bei B"

  # B darf fremde Eintraege nicht loeschen
  mid=$(grep -oE '/party/mitbringsel/[0-9]+/loeschen' <<<"$seite_a" | head -1 | grep -oE '[0-9]+')
  post "$jar/b" -d "csrf=$cb" "$BASE/party/mitbringsel/$mid/loeschen" >/dev/null
  "${CURL[@]}" -b "$jar/a" "$BASE/party" | grep -q 'Testsalat' \
    && pass "B kann fremdes Mitbringsel nicht loeschen" || fail "fremdes Mitbringsel wurde geloescht"

  # Aendern wirkt nur auf den eigenen Eintrag
  post "$jar/a" -d "csrf=$ca&status=ja&ankunft=beginn&anzeigename=Test A2&anzahl=3" "$BASE/party/eintrag" >/dev/null
  seite_a=$("${CURL[@]}" -b "$jar/a" "$BASE/party")
  grep -q 'Test A2' <<<"$seite_a" && ! grep -q '>Test A<' <<<"$seite_a" \
    && pass "A aendert den eigenen Eintrag" || fail "Aenderung hat nicht gewirkt"
  grep -q 'Test B' <<<"$seite_a" && pass "Eintrag von B unveraendert" || fail "Eintrag von B verschwunden"

  expect "ohne Cookie kein Zugriff" 303 "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE/party")"
  expect "falsches CSRF-Token" 400 "$(post "$jar/a" -d "csrf=falsch&anzeigename=X&anzahl=1" "$BASE/party/eintrag")"

  echo "== Live-Aktualisierung"
  stand1=$("${CURL[@]}" -b "$jar/a" "$BASE/party/stand")
  grep -q '"stand"' <<<"$stand1" && pass "/party/stand liefert JSON" || fail "/party/stand antwortet nicht wie erwartet"
  post "$jar/b" -d "csrf=$cb&text=Testkuchen&kategorie=Essen" "$BASE/party/mitbringsel" >/dev/null
  stand2=$("${CURL[@]}" -b "$jar/a" "$BASE/party/stand")
  [ "$stand1" != "$stand2" ] && pass "Stand aendert sich nach fremder Aenderung" || fail "Stand bleibt gleich"
  teil=$("${CURL[@]}" -b "$jar/a" "$BASE/party/listen")
  grep -q 'Testkuchen' <<<"$teil" && pass "/party/listen zeigt die Aenderung" || fail "/party/listen ohne Aenderung"
  grep -qi '<html' <<<"$teil" && fail "/party/listen liefert eine ganze Seite statt eines Ausschnitts" || pass "/party/listen ist nur der Ausschnitt"
  expect "/party/stand ohne Sitzung" 303 "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE/party/stand")"

  # Aufraeumen
  post "$jar/a" -d "csrf=$ca" "$BASE/party/eintrag/loeschen" >/dev/null
  post "$jar/b" -d "csrf=$cb" "$BASE/party/eintrag/loeschen" >/dev/null
  rest=$("${CURL[@]}" -b "$jar/a" "$BASE/party")
  grep -qE 'Test A2|Test B|Testsalat' <<<"$rest" && fail "Testdaten nicht vollstaendig entfernt" || pass "Testdaten aufgeraeumt"
fi

echo
[ "$fails" -eq 0 ] && echo "alle Tests bestanden" || { echo "$fails Test(s) fehlgeschlagen"; exit 1; }
