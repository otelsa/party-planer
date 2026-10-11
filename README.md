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

## Wie der Zugang funktioniert

| Pfad | Antwort |
|---|---|
| `/e/<token>` | die Seite |
| `/e/<token>/` | 301 auf die Variante ohne Schrägstrich |
| `/e/*.css` | Stylesheets, ohne Token im Pfad (sonst stünden sie im Referer) |
| `/e/<alles andere>` | neutrale Hinweisseite mit Status 200 |

Die Hinweisseite antwortet bewusst mit 200 statt 404: Tippfehler lösen so keine
fail2ban-Sperre aus. Preis dafür ist, dass `/e/` als existierender Bereich erkennbar ist.

Tokens stehen in keinem Log: `/e/`-Pfade werden im Hauptlog maskiert, die Partyseite
schreibt zusätzlich nach `/var/log/nginx/party.log` mit `/e/<token>` statt dem Wert.

## Noch offen

- Echte Daten: Datum, Uhrzeit, Ort, Ablauf, Codename
- Entscheidung Pfad → eigene Subdomain `party.otelsa.de` für den echten Betrieb
- Backend (Python + SQLite, systemd) laut Doc, falls aus dem Prototyp eine App wird
- Datenschutzhinweis und Löschfrist
