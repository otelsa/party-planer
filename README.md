# party (Prototyp)

Testseite für die Überraschungsfeier, erreichbar über einen geheimen Link
`https://otelsa.de/e/<token>`. Grundlage ist das Doc „Partyseite otelsa.de –
Architektur & Security-Review“.

**Stand: statischer Prototyp.** Kein Backend, keine Datenbank, nichts wird gespeichert.
Alle Formularfelder sind gesperrt, alle Inhalte sind Platzhalter.

## Aufbau

```
site/e/           die Seite (HTML + party.css + die OTELSA-Tokens aus pilarale/brand)
site/invalid/     neutrale Hinweisseite für ungültige oder abgelaufene Links
deploy/nginx/     Snippets: Token-Routen (Vorlage), Kopfzeilen, Log-Format
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

**Ohne Cookie, ohne Geräte-ID.** Die Identität ist der persönliche Link `/me/<token>`
(128 Bit Zufall). Wer ihn hat, sieht und ändert genau seine eigenen Einträge; alles andere
ist nur lesbar. Jeder eigene Eintrag trägt in den Listen ein Bearbeiten- und ein Löschsymbol.

- **Wiederkommen:** Der Link wird nach dem Anmelden angezeigt, mit „an mich selbst schicken“.
- **Verloren:** Ein Admin erzeugt einen neuen, der alte verfällt.
- **Bewusst nicht benutzt:** Cookies, `localStorage` (rechtlich wie ein Cookie und bräuchte
  JavaScript) und Geräte-Fingerprints (unzuverlässig und datenschutzrechtlich schlechter).
- **Preis:** Der Token steht in der Adresszeile und damit im Browserverlauf des Geräts.

Im Anmeldeformular gibt es nur **„Anzeigen als“** und **„Anzahl“** (Personen insgesamt,
die Person selbst mitgezählt). Die Gesamtzahl auf der Seite summiert diese Angaben.

## Wie der Zugang funktioniert

| Pfad | Antwort |
|---|---|
| `/e/<token>` | die Seite |
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
```

Die CI (`.github/workflows/ci.yml`) baut in einem Debian-trixie-Container denselben
nginx-Aufbau mit einem Testtoken auf und prüft das komplette Verhalten: Zugang nur mit
Token, neutrale Hinweisseite statt 404, Stylesheets, Weiterleitung, abgewiesene Methoden,
Sicherheits-Kopfzeilen, nichts Verräterisches in der Vorschau, Rate-Limit und dass in
keinem Log ein Token steht.

## Noch offen

- Echte Daten: Datum, Uhrzeit, Ort, Ablauf, Codename
- Entscheidung Pfad → eigene Subdomain `party.otelsa.de` für den echten Betrieb
- Backend (Python + SQLite, systemd) laut Doc, falls aus dem Prototyp eine App wird
- Datenschutzhinweis und Löschfrist
