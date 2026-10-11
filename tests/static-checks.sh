#!/bin/bash
# Quellchecks fuer die Partyseite (ohne Webserver).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fails=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

for f in site/e/index.html site/invalid/index.html; do
  # Die CSP ist default-src 'none'; style-src 'self': alles Inline waere blockiert.
  grep -qiE '<script|<style|[[:space:]]style=|[[:space:]]on[a-z]+=' "$f" \
    && fail "$f: Inline-Skript/-Style wuerde von der CSP blockiert" \
    || pass "$f: kein Inline-Skript/-Style"
  grep -qi 'name="robots" content="noindex' "$f" && pass "$f: noindex gesetzt" || fail "$f: noindex fehlt"
  ext=$(grep -oiE '(src|href)="(https?:)?//[^"]+"' "$f" || true)
  [ -z "$ext" ] && pass "$f: keine fremden Quellen" || fail "$f: fremde Quelle(n): $ext"
  # Vorschau darf nichts verraten
  grep -qi 'og:image' "$f" && fail "$f: og:image wuerde ein Bild in der Vorschau zeigen" || pass "$f: kein Vorschaubild"
  title=$(grep -oiP '(?<=<title>)[^<]+' "$f")
  [ "$title" = "Einladung" ] && pass "$f: neutraler Titel" || fail "$f: Titel verraet etwas: $title"
done

# Jede referenzierte Datei muss auch ausgeliefert werden
while read -r href; do
  case "$href" in
    otelsa-tokens.css|otelsa-components.css|party.css) [ -f "site/e/$href" ] && pass "vorhanden: site/e/$href" || fail "fehlt: site/e/$href" ;;
    /e/otelsa-tokens.css|/e/otelsa-components.css|/e/invalid.css)
      base=${href#/e/}; { [ -f "site/e/$base" ] || [ -f "site/invalid/$base" ]; } && pass "vorhanden: $href" || fail "fehlt: $href" ;;
    *) fail "unbekannte Stylesheet-Referenz: $href" ;;
  esac
  grep -q "location = $href" deploy/nginx/otelsa-party.conf.template 2>/dev/null || case "$href" in /e/*)
    grep -q "location = $href" deploy/nginx/otelsa-party.conf.template || fail "nginx liefert $href nicht aus" ;; esac
done < <(grep -ohE 'href="[^"]+\.css"' site/e/index.html site/invalid/index.html | cut -d'"' -f2 | sort -u)

# Keine echten Daten im Prototyp
grep -qiE 'projekt.nordstern|TT\.MM\.JJJJ' site/e/index.html && pass "Platzhalter statt echter Daten" || fail "Platzhalter fehlen"
# Zugang ohne Cookie: die Seite darf keines setzen oder lesen wollen.
# Das Cookie setzt spaeter der Server; die Seite selbst braucht keinen Skriptzugriff darauf.
grep -qi 'document.cookie\|localStorage\|sessionStorage' site/e/index.html \
  && fail "Seite greift per Skript auf Browser-Speicher zu" || pass "kein Skriptzugriff auf Browser-Speicher"
# Das Geheimnis darf nicht im Repo liegen: die Vorlage traegt nur den Platzhalter,
# und nirgends steht eine Zeichenkette, die wie ein Token aussieht (>=22 Zeichen Base64url).
grep -q '@TOKEN@' deploy/nginx/otelsa-party.conf.template \
  && pass "Vorlage nutzt den Platzhalter @TOKEN@" || fail "Platzhalter @TOKEN@ fehlt in der Vorlage"
# Nur ausgelieferte Dateien und Konfiguration; tests/ enthaelt absichtlich Dummy-Token.
leak=$(grep -rhoE '/e/[A-Za-z0-9_-]{22,}' deploy site 2>/dev/null | grep -v '@TOKEN@' || true)
[ -z "$leak" ] && pass "kein Token im Repo" || fail "sieht nach einem Token aus: $leak"

[ "$fails" -eq 0 ] && echo "alle Checks bestanden" || { echo "$fails Check(s) fehlgeschlagen"; exit 1; }
