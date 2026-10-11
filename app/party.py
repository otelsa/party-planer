#!/usr/bin/env python3
"""Partyseite: kleine Flask-App hinter nginx.

Zugang: ein Gruppentoken aus der WhatsApp-Gruppe. /e/<token> tauscht den Token gegen
ein Sitzungs-Cookie und leitet auf /party um; danach steht der Token nicht mehr in der
Adresszeile. Das Geraet ist der Nutzer: Was unter dieser Sitzung angelegt wurde, kann
auch nur sie aendern. Kein Konto, keine PIN, keine persoenlichen Links.

Konfiguration ueber Umgebungsvariablen:
  PARTY_TOKEN_FILE   Datei mit dem Gruppentoken (Vorgabe /etc/otelsa-party-token)
  PARTY_DB           SQLite-Datei (Vorgabe /var/lib/otelsa-party/party.sqlite3)
  PARTY_COOKIE_SECURE  0 schaltet das Secure-Flag ab (nur fuer Tests ohne TLS)
"""
import os
import secrets
import sqlite3
from datetime import datetime, timezone
from functools import wraps

from flask import Flask, abort, g, make_response, redirect, render_template, request

TOKEN_FILE = os.environ.get("PARTY_TOKEN_FILE", "/etc/otelsa-party-token")
DB_PATH = os.environ.get("PARTY_DB", "/var/lib/otelsa-party/party.sqlite3")
COOKIE = "party_sid"
COOKIE_MAX_AGE = 60 * 60 * 24 * 60  # 60 Tage
NAME_MAX = 40
TEXT_MAX = 80
COUNT_MAX = 6
MAX_PARTICIPANTS = 150

app = Flask(__name__)


def group_token():
    with open(TOKEN_FILE) as fh:
        return fh.read().strip()


SCHEMA = """
CREATE TABLE IF NOT EXISTS session (
  id TEXT PRIMARY KEY,                 -- SHA-256 des Cookie-Werts, nie der Wert selbst
  erstellt TEXT NOT NULL,
  gesehen  TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS teilnehmer (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  anzeigename TEXT NOT NULL,
  anzahl INTEGER NOT NULL,
  status TEXT NOT NULL,                -- ja | vielleicht | nein
  ankunft TEXT NOT NULL,               -- beginn | spaeter
  ankunft_zeit TEXT,
  erstellt TEXT NOT NULL,
  geaendert TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS teilnehmer_session ON teilnehmer(session_id);
CREATE TABLE IF NOT EXISTS mitbringsel (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  teilnehmer_id INTEGER NOT NULL REFERENCES teilnehmer(id) ON DELETE CASCADE,
  kategorie TEXT NOT NULL,
  text TEXT NOT NULL,
  erstellt TEXT NOT NULL
);
"""


def db():
    if "db" not in g:
        os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
        g.db = sqlite3.connect(DB_PATH)
        g.db.row_factory = sqlite3.Row
        g.db.execute("PRAGMA foreign_keys = ON")
        g.db.executescript(SCHEMA)
    return g.db


@app.teardown_appcontext
def close_db(_exc):
    con = g.pop("db", None)
    if con is not None:
        con.close()


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def sid_hash(value):
    import hashlib
    return hashlib.sha256(value.encode()).hexdigest()


def current_session():
    """Die Sitzung dieses Geraets, oder None."""
    raw = request.cookies.get(COOKIE)
    if not raw:
        return None
    row = db().execute("SELECT * FROM session WHERE id = ?", (sid_hash(raw),)).fetchone()
    return row


def require_session(view):
    @wraps(view)
    def wrapper(*a, **kw):
        session = current_session()
        if session is None:
            # Ohne gueltige Sitzung sieht niemand etwas: zurueck zur neutralen Hinweisseite.
            return redirect("/e/abgelaufen", code=303)
        db().execute("UPDATE session SET gesehen = ? WHERE id = ?", (now(), session["id"]))
        db().commit()
        g.session = session
        return view(*a, **kw)
    return wrapper


def me():
    return db().execute(
        "SELECT * FROM teilnehmer WHERE session_id = ?", (g.session["id"],)
    ).fetchone()


def csrf_ok():
    sent = request.form.get("csrf", "")
    expected = csrf_token()
    return secrets.compare_digest(sent, expected)


def csrf_token():
    """An die Sitzung gebunden, ohne zweites Cookie."""
    import hmac, hashlib
    key = app.config["CSRF_KEY"]
    return hmac.new(key, g.session["id"].encode(), hashlib.sha256).hexdigest()[:32]


def clean(text, limit):
    return " ".join((text or "").split())[:limit]


# ---------------------------------------------------------------- Routen

@app.get("/e/<token>")
def entry(token):
    """Token gegen Cookie tauschen; danach ist er aus der Adresszeile verschwunden."""
    if not secrets.compare_digest(token, group_token()):
        abort(404)
    raw = request.cookies.get(COOKIE)
    if not raw or not db().execute("SELECT 1 FROM session WHERE id = ?", (sid_hash(raw),)).fetchone():
        raw = secrets.token_urlsafe(32)
        db().execute("INSERT INTO session (id, erstellt, gesehen) VALUES (?, ?, ?)",
                     (sid_hash(raw), now(), now()))
        db().commit()
    resp = make_response(redirect("/party", code=303))
    resp.set_cookie(
        COOKIE, raw,
        max_age=COOKIE_MAX_AGE,
        httponly=True,
        secure=os.environ.get("PARTY_COOKIE_SECURE", "1") == "1",
        samesite="Lax",
        path="/",
    )
    return resp


@app.get("/party")
@require_session
def party():
    gaeste, mit, zahlen = listen_daten()
    return render_template(
        "party.html", me=me(), gaeste=gaeste, mitbringsel=mit, zahlen=zahlen,
        csrf=csrf_token(), sid=g.session["id"], stand=stand_wert(),
    )


@app.post("/party/eintrag")
@require_session
def eintrag():
    if not csrf_ok():
        abort(400)
    name = clean(request.form.get("anzeigename"), NAME_MAX)
    try:
        anzahl = max(1, min(COUNT_MAX, int(request.form.get("anzahl", "1"))))
    except ValueError:
        anzahl = 1
    status = request.form.get("status") if request.form.get("status") in ("ja", "vielleicht", "nein") else "ja"
    ankunft = "spaeter" if request.form.get("ankunft") == "spaeter" else "beginn"
    zeit = clean(request.form.get("ankunft_zeit"), 5) if ankunft == "spaeter" else None
    if not name:
        return redirect("/party?fehler=name", code=303)

    con = db()
    eigen = me()
    if eigen:
        con.execute(
            "UPDATE teilnehmer SET anzeigename=?, anzahl=?, status=?, ankunft=?, ankunft_zeit=?, geaendert=? WHERE id=?",
            (name, anzahl, status, ankunft, zeit, now(), eigen["id"]),
        )
    else:
        if con.execute("SELECT COUNT(*) c FROM teilnehmer").fetchone()["c"] >= MAX_PARTICIPANTS:
            abort(429)
        con.execute(
            "INSERT INTO teilnehmer (session_id, anzeigename, anzahl, status, ankunft, ankunft_zeit, erstellt, geaendert)"
            " VALUES (?,?,?,?,?,?,?,?)",
            (g.session["id"], name, anzahl, status, ankunft, zeit, now(), now()),
        )
    con.commit()
    return redirect("/party", code=303)


@app.post("/party/eintrag/loeschen")
@require_session
def eintrag_loeschen():
    if not csrf_ok():
        abort(400)
    eigen = me()
    if eigen:
        db().execute("DELETE FROM teilnehmer WHERE id = ?", (eigen["id"],))
        db().commit()
    return redirect("/party", code=303)


@app.post("/party/mitbringsel")
@require_session
def mitbringsel():
    if not csrf_ok():
        abort(400)
    eigen = me()
    if not eigen:
        return redirect("/party?fehler=erst-anmelden", code=303)
    text = clean(request.form.get("text"), TEXT_MAX)
    kategorie = request.form.get("kategorie")
    if kategorie not in ("Essen", "Getränke", "Sonstiges"):
        kategorie = "Sonstiges"
    if text:
        db().execute(
            "INSERT INTO mitbringsel (teilnehmer_id, kategorie, text, erstellt) VALUES (?,?,?,?)",
            (eigen["id"], kategorie, text, now()),
        )
        db().commit()
    return redirect("/party", code=303)


@app.post("/party/mitbringsel/<int:eintrag_id>/loeschen")
@require_session
def mitbringsel_loeschen(eintrag_id):
    if not csrf_ok():
        abort(400)
    # Nur was zu dieser Sitzung gehoert: die Pruefung passiert in der Abfrage selbst.
    db().execute(
        "DELETE FROM mitbringsel WHERE id = ? AND teilnehmer_id IN"
        " (SELECT id FROM teilnehmer WHERE session_id = ?)",
        (eintrag_id, g.session["id"]),
    )
    db().commit()
    return redirect("/party", code=303)


def stand_wert():
    """Billiger Fingerabdruck des veraenderlichen Teils: aendert sich bei jeder
    Anmeldung, Aenderung, Loeschung und jedem Mitbringsel."""
    con = db()
    t = con.execute("SELECT COUNT(*) c, COALESCE(MAX(geaendert), '') m FROM teilnehmer").fetchone()
    mi = con.execute("SELECT COUNT(*) c, COALESCE(MAX(erstellt), '') m FROM mitbringsel").fetchone()
    return f"{t['c']}-{t['m']}-{mi['c']}-{mi['m']}"


def listen_daten():
    con = db()
    gaeste = con.execute(
        "SELECT * FROM teilnehmer ORDER BY CASE status WHEN 'ja' THEN 0 WHEN 'vielleicht' THEN 1 ELSE 2 END, erstellt"
    ).fetchall()
    mit = con.execute(
        "SELECT m.*, t.anzeigename, t.session_id FROM mitbringsel m "
        "JOIN teilnehmer t ON t.id = m.teilnehmer_id ORDER BY m.erstellt"
    ).fetchall()
    zahlen = {
        "personen": sum(r["anzahl"] for r in gaeste if r["status"] == "ja"),
        "anmeldungen": sum(1 for r in gaeste if r["status"] == "ja"),
        "vielleicht": sum(1 for r in gaeste if r["status"] == "vielleicht"),
        "absagen": sum(1 for r in gaeste if r["status"] == "nein"),
    }
    return gaeste, mit, zahlen


@app.get("/party/stand")
@require_session
def stand():
    """Wird im Sekundentakt abgefragt - deshalb so klein wie moeglich."""
    resp = make_response({"stand": stand_wert()})
    resp.headers["Cache-Control"] = "no-store"
    return resp


@app.get("/party/listen")
@require_session
def listen():
    """Nur der veraenderliche Teil der Seite, zum Austauschen im Browser."""
    gaeste, mit, zahlen = listen_daten()
    return render_template("_live.html", gaeste=gaeste, mitbringsel=mit, zahlen=zahlen,
                           me=me(), csrf=csrf_token(), sid=g.session["id"])


@app.get("/party/gesundheit")
def gesundheit():
    db().execute("SELECT 1")
    return {"status": "ok"}


app.config["CSRF_KEY"] = os.environ.get("PARTY_CSRF_KEY", secrets.token_hex(32)).encode()

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=int(os.environ.get("PARTY_PORT", "8081")))
