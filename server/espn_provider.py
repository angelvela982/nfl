"""Read-only ESPN adapter. Unknown schemas fail closed, without manufacturing status."""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

BASE = "https://site.api.espn.com/apis/site/v2/sports/football/nfl"
TEAM_IDS = {
    "ARI": "22", "ATL": "1", "BAL": "33", "BUF": "2", "CAR": "29",
    "CHI": "3", "CIN": "4", "CLE": "5", "DAL": "6", "DEN": "7",
    "DET": "8", "GB": "9", "HOU": "34", "IND": "11", "JAX": "30",
    "KC": "12", "LAC": "24", "LAR": "14", "LV": "13", "MIA": "15",
    "MIN": "16", "NE": "17", "NO": "18", "NYG": "19", "NYJ": "20",
    "PHI": "21", "PIT": "23", "SEA": "26", "SF": "25", "TB": "27",
    "TEN": "10", "WAS": "28",
}
TEAM_ALIASES = {"WSH": "WAS", "LA": "LAR", "SD": "LAC", "OAK": "LV"}


def normalize_team(value: str) -> str:
    value = value.strip().upper()
    return TEAM_ALIASES.get(value, value)


def provider_url(key: str) -> str:
    """Clients can select only known data, never supply a destination URL."""
    if key == "injuries":
        return BASE + "/injuries"
    if key == "news":
        return BASE + "/news?limit=50"
    if key.startswith("scoreboard:"):
        date = key.split(":", 1)[1]
        if re.fullmatch(r"\d{8}", date):
            return BASE + "/scoreboard?" + urllib.parse.urlencode({"dates": date, "limit": 100})
    if key.startswith("roster:"):
        team = key.split(":", 1)[1]
        if team in TEAM_IDS:
            return BASE + "/teams/" + TEAM_IDS[team] + "/roster"
    if key.startswith("summary:"):
        event_id = key.split(":", 1)[1]
        if re.fullmatch(r"\d{1,15}", event_id):
            return BASE + "/summary?" + urllib.parse.urlencode({"event": event_id})
    raise ValueError("Unsupported provider key")


def validate_payload(key: str, payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ValueError("Provider response is not a JSON object")
    field = "injuries" if key == "injuries" else "articles" if key == "news" else (
        "events" if key.startswith("scoreboard:") else "athletes" if key.startswith("roster:") else None
    )
    if field and not isinstance(payload.get(field), list):
        raise ValueError(f"Unrecognized ESPN schema: missing {field} array")
    if key.startswith("summary:") and not isinstance(payload.get("header"), dict):
        raise ValueError("Unrecognized ESPN summary schema: missing header")
    return payload


def _select(data: dict, keys: tuple[str, ...]) -> dict:
    return {key: data[key] for key in keys if key in data}


def compact_injuries(groups: list) -> list[dict]:
    result = []
    for group in groups:
        if not isinstance(group, dict):
            continue
        compact = _select(group, ("id", "displayName"))
        if isinstance(group.get("team"), dict):
            compact["team"] = _select(group["team"], ("id", "abbreviation", "displayName"))
        compact["injuries"] = []
        for injury in group.get("injuries", []):
            if not isinstance(injury, dict):
                continue
            item = _select(injury, ("id", "status", "date", "type", "details", "shortComment", "longComment"))
            athlete = injury.get("athlete", {})
            if isinstance(athlete, dict):
                item["athlete"] = _select(athlete, ("id", "displayName", "fullName"))
                if isinstance(athlete.get("team"), dict):
                    item["athlete"]["team"] = _select(athlete["team"], ("id", "abbreviation"))
                item["athlete"]["links"] = [_select(link, ("href", "rel")) for link in athlete.get("links", []) if isinstance(link, dict)]
            compact["injuries"].append(item)
        result.append(compact)
    return result


def compact_articles(articles: list) -> list[dict]:
    return [_select(article, ("id", "headline", "description", "published", "lastModified", "categories", "links"))
            for article in articles if isinstance(article, dict)]


def compact_payload(key: str, payload: dict) -> dict:
    """Persist required evidence without each athlete's multi-megabyte biography/media."""
    if key == "injuries":
        data = _select(payload, ("timestamp", "season", "status"))
        data["injuries"] = compact_injuries(payload["injuries"])
        return data
    if key == "news":
        return {"articles": compact_articles(payload["articles"])}
    if key.startswith("roster:"):
        data = _select(payload, ("timestamp", "season", "status", "team"))
        if isinstance(data.get("team"), dict):
            data["team"] = _select(data["team"], ("id", "abbreviation", "displayName"))
        data["athletes"] = []
        for group in payload["athletes"]:
            if not isinstance(group, dict):
                continue
            if isinstance(group.get("items"), list):
                data["athletes"].append({"position": group.get("position"), "items": [
                    _select(athlete, ("id", "displayName", "fullName")) for athlete in group["items"] if isinstance(athlete, dict)]})
            elif group.get("id"):
                data["athletes"].append(_select(group, ("id", "displayName", "fullName")))
        return data
    if key.startswith("scoreboard:"):
        data = _select(payload, ("season", "week"))
        data["events"] = []
        for event in payload["events"]:
            if not isinstance(event, dict):
                continue
            item = _select(event, ("id", "date", "season", "week", "status", "name"))
            item["competitions"] = [{"competitors": [{"team": _select(competitor.get("team", {}), ("id", "abbreviation"))}
                for competitor in competition.get("competitors", []) if isinstance(competitor, dict) and isinstance(competitor.get("team"), dict)]}
                for competition in event.get("competitions", []) if isinstance(competition, dict)]
            data["events"].append(item)
        return data
    if key.startswith("summary:"):
        data = {"header": payload["header"]}
        data["injuries"] = compact_injuries(payload.get("injuries", []))
        news = payload.get("news", {})
        data["news"] = {"articles": compact_articles(news.get("articles", []))} if isinstance(news, dict) else {"articles": []}
        article = payload.get("article")
        if isinstance(article, dict):
            data["article"] = compact_articles([article])[0]
        return data
    return payload


class FixedRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlparse(newurl)
        if parsed.scheme != "https" or parsed.hostname != "site.api.espn.com" or parsed.port not in (None, 443):
            raise urllib.error.URLError("Provider redirect outside allowed HTTPS host")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class ESPNProvider:
    def __init__(self, timeout: float = 10.0, max_bytes: int = 16 * 1024 * 1024):
        self.timeout = timeout
        self.max_bytes = max_bytes
        self.opener = urllib.request.build_opener(FixedRedirectHandler())

    def fetch(self, key: str) -> tuple[dict[str, Any], str | None]:
        request = urllib.request.Request(provider_url(key), headers={
            "User-Agent": "NFLPulse/0.2 (public-data-context)", "Accept": "application/json",
        })
        with self.opener.open(request, timeout=self.timeout) as response:
            raw = response.read(self.max_bytes + 1)
            if len(raw) > self.max_bytes:
                raise ValueError("Provider response exceeds size limit")
            payload = json.loads(raw)
            modified = response.headers.get("Last-Modified")
        return compact_payload(key, validate_payload(key, payload)), modified
