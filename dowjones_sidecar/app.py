"""
Quote sidecar for the Elixir delivery-system server.

STOPGAP: this serves a small roster of invented companies instead of a live
market feed. The upstream it used to front (a cookie + crumb handshake over
curl_cffi, which is why this is a separate Python process at all) broke often
enough to take the Dow Jones app down with it, and an exhibit cannot depend on
somebody else's undocumented auth dance.

Everything below is fiction. When a real feed arrives, this file is the only
thing that has to change: the endpoint contract, the JSON shape and the Elixir
decoder all stay exactly as they are.

Endpoint contract, unchanged: GET /quote/<symbol> returns the shape the
caller's decoder consumes, or 404 for a symbol we do not carry. The 404 is
deliberate - the client renders XXME47F4, which names the symbols we do have,
rather than us inventing a quote for a ticker a guest half-remembers.
"""
import hashlib
import logging
import math
from datetime import date, timedelta

from fastapi import FastAPI, HTTPException

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("dowjones-sidecar")

app = FastAPI(title="dowjones-sidecar")

# The roster. Twelve, which is what the Quote Track default list used to hold -
# enough to fill three picker pages, so paging is exercised by what a guest sees
# rather than only by the tests.
#
# Every name is invented and every one predates the service, so nothing on
# screen post-dates 1990. No real company appears anywhere in this file: a guest
# should never see fabricated news or an invented price attached to a business
# that exists. That is also why an unknown symbol 404s instead of falling back
# to one of these.
# `base` is the price the company oscillates around, in a range that looked
# ordinary on a 1990 ticker - two and three figures, not four.
COMPANIES = {
    "ACME": {"short": "ACME CORPORATION", "long": "Acme Corporation", "base": 42.50},
    "CYBR": {"short": "CYBERDYNE", "long": "Cyberdyne Systems Corp", "base": 88.25},
    "WEYU": {"short": "WEYLAND-YUTANI", "long": "Weyland-Yutani Corp", "base": 124.75},
    "TYRL": {"short": "TYRELL CORP", "long": "Tyrell Corporation", "base": 67.00},
    "OCPI": {"short": "OMNI CONSUMER", "long": "Omni Consumer Products", "base": 31.375},
    "SOYL": {"short": "SOYLENT CORP", "long": "Soylent Corporation", "base": 19.875},
    "SPSP": {"short": "SPACELY SPROCKETS", "long": "Spacely Space Sprockets", "base": 54.125},
    "COGS": {"short": "COGSWELL COGS", "long": "Cogswell Cogs Inc", "base": 48.75},
    "WONK": {"short": "WONKA INDS", "long": "Wonka Industries", "base": 73.25},
    "NAKT": {"short": "NAKATOMI TRADING", "long": "Nakatomi Trading Corp", "base": 156.50},
    "GENC": {"short": "GENCO OLIVE OIL", "long": "Genco Pura Olive Oil Co", "base": 12.625},
    "YOYO": {"short": "YOYODYNE", "long": "Yoyodyne Propulsion Systems", "base": 96.00},
}


def _rand(*parts):
    """A deterministic 0.0-1.0 draw from the given parts.

    Seeded rather than random so a quote is stable: the same symbol on the same
    day gives the same number in every process, across restarts, and on every
    machine. Quote Track saves symbols, so a portfolio that reshuffled itself
    on each load would be worse than no portfolio at all.
    """
    h = hashlib.sha256("|".join(str(p) for p in parts).encode()).digest()
    return int.from_bytes(h[:8], "big") / float(1 << 64)


def _close(symbol, base, day):
    """Closing price for `day`.

    Two movements combined: a slow swing over about a quarter, so a guest who
    looks twice in a week sees a trend, and a daily jitter of a couple of
    percent on top so consecutive days are never identical. Derived from the
    date rather than accumulated, so any day can be priced on its own.
    """
    swing = 1.0 + 0.12 * math.sin(day.toordinal() / 37.0)
    jitter = 1.0 + (_rand(symbol, day.isoformat(), "close") - 0.5) * 0.04
    return round(base * swing * jitter, 3)


def _quote(symbol, today=None):
    c = COMPANIES[symbol]
    today = today or date.today()

    close = _close(symbol, c["base"], today)
    prev = _close(symbol, c["base"], today - timedelta(days=1))

    # The day's open sits near the previous close - a market does not gap
    # without a reason, and our fiction has none.
    open_ = round(prev * (1.0 + (_rand(symbol, today.isoformat(), "open") - 0.5) * 0.015), 3)

    # High and low must actually contain the day's trading, or the quote screen
    # shows a low above its close and the illusion dies on the first read.
    hi_pad = _rand(symbol, today.isoformat(), "high") * 0.012
    lo_pad = _rand(symbol, today.isoformat(), "low") * 0.012
    high = round(max(open_, close) * (1.0 + hi_pad), 3)
    low = round(min(open_, close) * (1.0 - lo_pad), 3)

    # Round lots, as a 1990 tape would carry them.
    volume = int(_rand(symbol, today.isoformat(), "vol") * 2_400_000 + 120_000) // 100 * 100

    return {
        "shortName": c["short"],
        "longName": c["long"],
        "regularMarketPrice": close,
        "regularMarketOpen": open_,
        "regularMarketDayHigh": high,
        "regularMarketDayLow": low,
        "regularMarketChange": round(close - prev, 3),
        "regularMarketVolume": float(volume),
    }


@app.get("/health")
def health():
    return {"ok": True, "mode": "fixture", "symbols": sorted(COMPANIES)}


@app.get("/symbols")
def symbols():
    """The roster, for anything that wants to list or check it."""
    return {s: {"shortName": c["short"], "longName": c["long"]} for s, c in COMPANIES.items()}


@app.get("/quote/{symbol}")
def get_quote(symbol: str):
    sym = symbol.strip().upper()

    if sym not in COMPANIES:
        logger.info("quote request: %s -> not carried", sym)
        raise HTTPException(status_code=404, detail=f"no quote for {sym}")

    logger.info("quote request: %s", sym)
    return {"quoteResponse": {"result": [_quote(sym)]}}
