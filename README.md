# party (Prototyp)

Testseite für die Überraschungsfeier, erreichbar über einen geheimen Link
`https://otelsa.de/e/<token>`. Grundlage ist das Doc „Partyseite otelsa.de –
Architektur & Security-Review“.

**Stand: lauffähige Anmeldung.** Flask + SQLite hinter nginx, als systemd-Dienst.
Anmelden, ändern, löschen und Mitbringliste funktionieren; Inhalte des Plans sind Platzhalter.
Die offene Seite aktualisiert sich selbst, wenn jemand anderes etwas ändert.
Noch nicht gebaut: Wunschliste, Einzel-Einladungen, Admin-Bereich, automatische Löschung.

## Aufbau

```
app/              Flask-App (party.py) und Template (templates/party.html)
site/e/           Stylesheets: party.css + die OTELSA-Tokens aus pilarale/brand
site/invalid/     neutrale Hinweisseite für ungültige oder abgelaufene Links
deploy/nginx/     Snippets: Token-Routen (Vorlage), Kopfzeilen, Proxy, Log-Format
deploy/systemd/   gehärteter Dienst otelsa-party.service
scripts/deploy.sh ausrollen nach /var/www/otelsa/party und /etc/nginx/snippets
tests/            Quellchecks (CSP-Tauglichkeit, neutrale Vorschau, kein Token im Repo)
```

## Ausrollen

Der Token steht nur auf dem Server in `/etc/otelsa-party-token` (0600, root).
Im Repo liegt nur der Platzhalter `@TOKEN@`.

```bash
bash tests/static-checks.sh
sudo scripts/deploy.sh
```

## Wie Teilnehmer erkannt werden

**Ein Gruppenlink für alle. Das Gerät ist der Nutzer.** Fast alle öffnen den Link vom Handy
aus der WhatsApp-Gruppe. Beim ersten Speichern setzt der Server ein technisch notwendiges
Cookie (HttpOnly, Secure, SameSite=Lax, 60 Tage), das nur sagt, welcher Eintrag zu diesem
Gerät gehört. Danach erkennt die Seite den Gast wieder und zeigt an seinen Einträgen
Bearbeiten und Löschen. Keine PIN, keine persönlichen Links, kein Konto, kein Banner
(für technisch notwendige Cookies nicht nötig).

Das Formular hat zwei Angaben: **Anzeigen als** und **Anzahl** (Personen insgesamt,
die Person selbst mitgezählt).

| Fall | Was passiert |
|---|---|
| Gleiches Gerät, Link erneut geöffnet | Eintrag wird wiedererkannt |
| Anderer Browser oder PC | Neuer Gast; die Seite weist vorher darauf hin, immer den Link aus der Gruppe zu nehmen |
| Doppelter Eintrag entstanden | Organisator führt zusammen oder löscht |
| Browserdaten gelöscht | Wie ein neues Gerät |
| Externe ohne Gruppenzugang | Einzel-Einladungslink `/i/<token>`, einmal nutzbar, 14 Tage gültig |

Bewusst verworfen: PIN je Eintrag (eine Hürde für alle, nur gegen Jux unter Gästen),
persönliche Links (jeder müsste einen Link verwahren), Geräte-Fingerprints (unzuverlässig,
datenschutzrechtlich schlechter), `localStorage` (bräuchte JavaScript, rechtlich dasselbe
wie das Cookie).

## Wie der Zugang funktioniert

| Pfad | Antwort |
|---|---|
| `/e/<token>` | tauscht den Token gegen das Sitzungs-Cookie, 303 auf `/party` |
| `/party` | die Seite; ohne Sitzung 303 zur Hinweisseite |
| `/party/...` | Formulare (POST, mit CSRF-Token) |
| `/party/stand` | winziges JSON mit dem Änderungsstand, vom Browser im Takt abgefragt |
| `/party/listen` | nur der veränderliche Ausschnitt (Zahlen und Listen) zum Austauschen |
| `/e/<token>/` | 301 auf die Variante ohne Schrägstrich |
| `/e/*.css` | Stylesheets, ohne Token im Pfad (sonst stünden sie im Referer) |
| `/e/<alles andere>` | neutrale Hinweisseite mit Status 200 |

Die Hinweisseite antwortet bewusst mit 200 statt 404: Tippfehler lösen so keine
fail2ban-Sperre aus. Preis dafür ist, dass `/e/` als existierender Bereich erkennbar ist.

Tokens stehen in keinem Log:

- Hauptlog: `/e/`-Pfade werden maskiert (`map` in `deploy/nginx/log-format.conf`), auch bei
  Antworten, die auf Serverebene entstehen (etwa 405 bei POST).
- Zugriffe der Partyseite: `/var/log/nginx/party.log`, Pfad immer als `/e/<token>`.
- Fehlerlog: eigenes `party-error.log` ab Stufe `crit`. nginx schreibt Rate-Limit-Treffer
  sonst mit vollständiger URL ins Fehlerlog — das wäre der Token im Klartext.
  `limit_req_log_level info` hält diese Meldungen aus dem Log, das Limit selbst wirkt weiter.

## Tests

```bash
bash tests/static-checks.sh                      # Quellen (CSP, neutrale Vorschau, kein Token im Repo)
sudo env BASE=https://otelsa.de RESOLVE=127.0.0.1 \
  TOKEN="$(sudo cat /etc/otelsa-party-token)" bash tests/integration.sh
# FLOW=1 testet zusätzlich den echten Ablauf mit zwei Geräten und räumt danach auf
```

Der Ablauf-Test legt zwei Teilnehmer an, prüft Wiedererkennung, Markierung eigener
Einträge, dass fremde Einträge unantastbar sind, Ändern, fehlende Sitzung und ein
falsches CSRF-Token — und löscht seine Testdaten am Ende wieder.

Die CI (`.github/workflows/ci.yml`) baut in einem Debian-trixie-Container denselben
nginx-Aufbau mit einem Testtoken auf und prüft das komplette Verhalten: Zugang nur mit
Token, neutrale Hinweisseite statt 404, Stylesheets, Weiterleitung, abgewiesene Methoden,
Sicherheits-Kopfzeilen, nichts Verräterisches in der Vorschau, Rate-Limit und dass in
keinem Log ein Token steht.

## Aktualisierung bei offener Seite

`site/e/party.js` fragt alle 8 Sekunden `/party/stand` ab — ein JSON mit einem
Fingerabdruck aus Anzahl und jüngster Änderungszeit. Ändert er sich, holt das Skript
`/party/listen` und tauscht nur den Bereich `#live` aus; kurz erscheint „Liste aktualisiert“.

- **Das Formular wird nie angefasst**, damit niemandem die Eingabe verschwindet.
- Im Hintergrund-Tab wird auf 60 Sekunden gedrosselt, beim Zurückwechseln sofort geprüft.
- **Ohne JavaScript** bleibt alles benutzbar, die Seite aktualisiert sich dann nur beim Neuladen.
- Die CSP erlaubt dafür `script-src 'self'` und `connect-src 'self'` — nichts Fremdes, nichts Inline.
- Bewusst kein Server-Sent-Events oder WebSocket: Die App läuft mit zwei Gunicorn-Workern,
  die Dauerverbindungen blockieren würden. Bei 40 Gästen ist Nachfragen sparsamer.

## Noch offen

- Echte Daten: Datum, Uhrzeit, Ort, Ablauf, Codename
- Entscheidung Pfad → eigene Subdomain `party.otelsa.de` für den echten Betrieb
- Backend (Python + SQLite, systemd) laut Doc, falls aus dem Prototyp eine App wird
- Datenschutzhinweis und Löschfrist
