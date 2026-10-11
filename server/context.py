"""Normalize cached public data to the version 0.2 iPhone wire contract."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
import hashlib
import re
import unicodedata
from typing import Any
from urllib.parse import urlparse

from .cache import SnapshotCache, entry_is_fresh, iso, parse_date
from .espn_provider import TEAM_IDS, normalize_team, provider_url
from .scheduler import RefreshService


def public_team(value: str) -> str:
    value = normalize_team(value)
    return "LA" if value == "LAR" else value


def normalized_name(value: str) -> str:
    folded = unicodedata.normalize("NFKD", value).casefold()
    return "".join(c for c in folded if c.isalnum() and not unicodedata.combining(c))


def text(value: Any, limit: int = 2000) -> str:
    return value[:limit] if isinstance(value, str) else ""


def team_matches(data: dict, team: str) -> bool:
    return str(data.get("id", "")) == TEAM_IDS.get(team) or normalize_team(text(data.get("abbreviation"))) == team


def safe_article_url(value: Any) -> str | None:
    if isinstance(value, str):
        parsed = urlparse(value)
        if parsed.scheme == "https" and parsed.hostname and (
            parsed.hostname == "espn.com" or parsed.hostname.endswith(".espn.com")
        ) and not parsed.username and not parsed.password and parsed.port in (None, 443):
            return value
    return None


def athlete_id(athlete: dict) -> str | None:
    """League injuries omit athlete.id; use only official NFL player-card links."""
    ids = set()
    supplied = str(athlete.get("id", ""))
    if re.fullmatch(r"\d{1,15}", supplied):
        ids.add(supplied)
    for link in athlete.get("links", []):
        if not isinstance(link, dict) or not isinstance(link.get("href"), str):
            continue
        parsed = urlparse(link["href"])
        if parsed.scheme != "https" or parsed.hostname not in ("www.espn.com", "espn.com") or parsed.username or parsed.password:
            continue
        match = re.fullmatch(r"/nfl/player/(?:[^/]+/)?_/id/(\d{1,15})(?:/[^/]+)?/?", parsed.path)
        if match:
            ids.add(match.group(1))
    return ids.pop() if len(ids) == 1 else None


@dataclass(frozen=True)
class ContextQuery:
    player_id: str
    espn_id: str
    name: str
    team: str
    game_id: str
    kickoff: datetime
    season: int
    week: int

    @classmethod
    def parse(cls, arguments: dict[str, list[str]]) -> "ContextQuery":
        allowed = {"player_id", "espn_id", "name", "team", "game_id", "kickoff", "season", "week"}
        if set(arguments) - allowed or any(len(values) != 1 for values in arguments.values()):
            raise ValueError("Unknown or repeated query parameter")
        values = {key: value[0].strip() for key, value in arguments.items()}
        required = ("player_id", "name", "team", "game_id", "kickoff", "season", "week")
        if any(not values.get(key) for key in required):
            raise ValueError("Required: player_id, name, team, game_id, kickoff, season, week")
        if any(len(value) > 160 for value in values.values()):
            raise ValueError("Query value exceeds length limit")
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", values["player_id"]) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", values["game_id"]):
            raise ValueError("Invalid player_id or game_id")
        espn_id = values.get("espn_id", "")
        if espn_id and not re.fullmatch(r"\d{1,15}", espn_id):
            raise ValueError("Invalid espn_id")
        team = normalize_team(values["team"])
        if team not in TEAM_IDS:
            raise ValueError("Unknown NFL team")
        kickoff = parse_date(values["kickoff"])
        if kickoff is None:
            raise ValueError("kickoff requires an ISO8601 timestamp with timezone")
        try:
            season, week = int(values["season"]), int(values["week"])
        except ValueError as error:
            raise ValueError("season/week must be integers") from error
        if not 2000 <= season <= 2100 or not 1 <= week <= 30:
            raise ValueError("season/week out of range")
        if kickoff.year not in (season, season + 1):
            raise ValueError("kickoff does not belong to season")
        return cls(values["player_id"], espn_id, values["name"], team,
                   values["game_id"], kickoff, season, week)

    @property
    def scoreboard_key(self) -> str:
        return "scoreboard:" + self.kickoff.strftime("%Y%m%d")


def roster_athletes(payload: dict[str, Any] | None) -> list[dict]:
    result = []
    for group in (payload or {}).get("athletes", []):
        if not isinstance(group, dict):
            continue
        if isinstance(group.get("items"), list):
            result.extend(athlete for athlete in group["items"] if isinstance(athlete, dict))
        elif group.get("id") is not None:
            result.append(group)
    return result


def resolve_identity(query: ContextQuery, payload: dict | None) -> tuple[str | None, str | None]:
    # IDs come from a team-scoped roster; no fuzzy names, substring matches or news-name guesses.
    if not payload:
        return None, "No se pudo verificar la identidad del jugador con la plantilla ESPN."
    if isinstance(payload.get("team"), dict) and not team_matches(payload["team"], query.team):
        return None, "La plantilla recibida corresponde a otro equipo; se descartó."
    matches = [athlete for athlete in roster_athletes(payload)
               if normalized_name(text(athlete.get("displayName") or athlete.get("fullName"))) == normalized_name(query.name)]
    if query.espn_id:
        matches = [athlete for athlete in matches if str(athlete.get("id", "")) == query.espn_id]
    ids = {str(athlete["id"]) for athlete in matches if re.fullmatch(r"\d{1,15}", str(athlete.get("id", "")))}
    if len(ids) == 1:
        return ids.pop(), None
    if len(ids) > 1:
        return None, "La identidad es ambigua: existen varios jugadores con el mismo nombre en el equipo."
    return None, "El nombre, equipo e identificador ESPN no coinciden de forma verificable."


def matching_event(query: ContextQuery, payload: dict | None) -> tuple[dict | None, str | None]:
    matches = []
    for event in (payload or {}).get("events", []):
        if not isinstance(event, dict):
            continue
        date = parse_date(event.get("date"))
        event_season = event.get("season", (payload or {}).get("season", {}))
        event_week = event.get("week", (payload or {}).get("week", {}))
        if not isinstance(event_season, dict) or not isinstance(event_week, dict):
            continue
        competitions = event.get("competitions", [])
        event_teams = [competitor.get("team", {}) for competition in competitions if isinstance(competition, dict)
                       for competitor in competition.get("competitors", []) if isinstance(competitor, dict)]
        if (date and abs((date - query.kickoff).total_seconds()) <= 300
                and event_season.get("year") == query.season and event_week.get("number") == query.week
                and any(isinstance(team, dict) and team_matches(team, query.team) for team in event_teams)
                and re.fullmatch(r"\d{1,15}", str(event.get("id", "")))):
            matches.append(event)
    if len(matches) == 1:
        return matches[0], None
    if len(matches) > 1:
        return None, "Hay varios eventos compatibles; no se asignaron reportes a un partido."
    return None, "ESPN no corroboró equipo, horario, temporada y semana del partido seleccionado."


STATUS_MAP = {
    "out": "out", "o": "out", "questionable": "questionable", "q": "questionable",
    "doubtful": "doubtful", "d": "doubtful", "injured reserve": "injuredReserve",
    "ir": "injuredReserve", "reserve/injured": "injuredReserve", "inactive": "inactive",
}


def injury_reports(query: ContextQuery, espn_id: str | None, entry: dict | None,
                   event_verified: bool, now: datetime) -> tuple[list[dict], list[str]]:
    if not espn_id or not entry or not entry.get("payload"):
        return [], []
    payload = entry["payload"]
    season = payload.get("season", {})
    if not isinstance(season, dict) or season.get("year") != query.season:
        return [], ["El reporte de lesiones no corresponde a la temporada solicitada; se descartó."]
    stamp = parse_date(payload.get("timestamp"))
    checked_at = parse_date(entry.get("fetched_at"))
    if checked_at is None:
        return [], []
    if stamp is None or stamp > now + timedelta(minutes=5) or now - stamp > timedelta(hours=6):
        return [], ["El proveedor no entrega una marca de actualización reciente y válida de lesiones."]
    result, warnings = [], []
    for group in payload.get("injuries", []):
        if not isinstance(group, dict):
            continue
        team = group.get("team", group)
        if not isinstance(team, dict) or not team_matches(team, query.team):
            continue
        for injury in group.get("injuries", []):
            if not isinstance(injury, dict) or not isinstance(injury.get("athlete"), dict):
                continue
            athlete = injury["athlete"]
            if athlete_id(athlete) != espn_id:
                continue
            if isinstance(athlete.get("team"), dict) and not team_matches(athlete["team"], query.team):
                warnings.append("El equipo del atleta contradice el grupo de lesiones; se descartó ese reporte.")
                continue
            status_value = injury.get("status")
            raw_status = text(status_value).strip().lower()
            status = STATUS_MAP.get(raw_status, "unknown")
            # An Active roster classification is not an active game roster.
            reported_at = parse_date(injury.get("date"))
            current_window = bool(reported_at and query.kickoff - timedelta(days=7) <= reported_at <= now
                                  and query.kickoff >= now - timedelta(hours=4))
            game_id = query.game_id if event_verified and current_window and status != "injuredReserve" else None
            if status in ("out", "inactive", "doubtful") and game_id is None:
                warnings.append("El estado de lesión no puede vincularse de forma reciente al partido seleccionado.")
            if status == "injuredReserve" and (reported_at is None or reported_at > now):
                warnings.append("La reserva de lesionados no tiene una fecha de reporte verificable.")
                status = "unknown"
            details = injury.get("details", {})
            injury_type = injury.get("type", {})
            detail_parts = [text(status_value)]
            if isinstance(injury_type, dict):
                detail_parts.append(text(injury_type.get("description") or injury_type.get("name")))
            if isinstance(details, dict):
                detail_parts.extend(text(details.get(key)) for key in ("type", "location", "detail", "returnDate"))
            detail_parts.extend(text(injury.get(key)) for key in ("shortComment", "longComment"))
            detail = ". ".join(dict.fromkeys(part for part in detail_parts if part))
            identity = str(injury.get("id") or hashlib.sha256((espn_id + detail).encode()).hexdigest()[:16])
            result.append({
                "id": "espn-injury-" + identity, "playerID": query.player_id,
                "espnID": espn_id, "name": text(athlete.get("displayName")) or query.name,
                "team": public_team(query.team), "status": status,
                "detail": detail or "Estado explícito sin detalle adicional.",
                "reportedAt": iso(reported_at) if reported_at else None,
                # Feed timestamp is evidence age; a fresh HTTP download cannot revive old evidence.
                "checkedAt": iso(min(checked_at, stamp)), "gameID": game_id,
                "source": "ESPN · reporte de lesiones", "sourceURL": provider_url("injuries"),
            })
    return result, list(dict.fromkeys(warnings))


def news_items(query: ContextQuery, espn_id: str | None, entry: dict | None, now: datetime) -> list[dict]:
    result = []
    for article in ((entry or {}).get("payload") or {}).get("articles", []):
        if not isinstance(article, dict):
            continue
        published = parse_date(article.get("published"))
        if published is None or published > now + timedelta(minutes=5) or now - published > timedelta(days=7):
            continue
        athlete_ids, teams = set(), set()
        for category in article.get("categories", []):
            if not isinstance(category, dict):
                continue
            category_type = category.get("type")
            data = category.get(category_type, {}) if isinstance(category_type, str) else {}
            # category.id is ESPN taxonomy, not the athlete/team identifier.
            fallback_id = category.get("athleteId" if category_type == "athlete" else "teamId", "")
            entity_id = str(data.get("id", fallback_id)) if isinstance(data, dict) else str(fallback_id)
            if category_type == "athlete" and re.fullmatch(r"\d{1,15}", entity_id):
                athlete_ids.add(entity_id)
            if category_type == "team":
                for team, team_id in TEAM_IDS.items():
                    if team_id == entity_id:
                        teams.add(public_team(team))
        relevant_player = espn_id is not None and espn_id in athlete_ids
        if not relevant_player and public_team(query.team) not in teams:
            continue
        links = article.get("links", {})
        web = links.get("web", {}) if isinstance(links, dict) else {}
        url = safe_article_url(web.get("href")) if isinstance(web, dict) else None
        if not url:
            continue
        title = text(article.get("headline"), 500)
        if not title:
            continue
        identity = str(article.get("id") or hashlib.sha256(url.encode()).hexdigest()[:16])
        result.append({"id": "espn-news-" + identity, "title": title,
                       "summary": text(article.get("description")), "url": url,
                       "publishedAt": iso(published), "source": "ESPN",
                       "playerIDs": sorted(athlete_ids), "teams": sorted(teams)})
    return sorted(result, key=lambda item: item["publishedAt"], reverse=True)[:25]


class ContextBuilder:
    def __init__(self, service: RefreshService):
        self.service = service
        self.cache: SnapshotCache = service.cache

    def build(self, query: ContextQuery, refresh: bool = True) -> dict:
        now = self.service.clock()
        keys = ["injuries", "news", "roster:" + query.team, query.scoreboard_key]
        self.service.watch(keys, query.game_id, query.kickoff)
        if refresh:
            self.service.ensure(keys)
        now = self.service.clock()
        warnings = []
        roster = self.cache.get("roster:" + query.team)
        if entry_is_fresh(roster, now, 24 * 3600):
            espn_id, warning = resolve_identity(query, roster["payload"])
        else:
            espn_id, warning = None, "La plantilla ESPN falta o está desactualizada; no se asociaron lesiones por nombre."
        if warning:
            warnings.append(warning)
        scoreboard = self.cache.get(query.scoreboard_key)
        event, warning = matching_event(query, scoreboard.get("payload") if scoreboard else None)
        if warning:
            warnings.append(warning)
        summary = None
        if event:
            summary_key = "summary:" + str(event["id"])
            self.service.watch([summary_key], query.game_id, query.kickoff)
            if refresh:
                self.service.ensure([summary_key], budget_seconds=3)
            keys.append(summary_key)
            summary = self.cache.get(summary_key)
        injuries = self.cache.get("injuries")
        event_verified = bool(event and entry_is_fresh(scoreboard, now, self.service.interval(now) + 30))
        reports, injury_warnings = injury_reports(query, espn_id, injuries, event_verified, now)
        warnings.extend(injury_warnings)
        news = news_items(query, espn_id, self.cache.get("news"), now)
        if summary and isinstance(summary.get("payload"), dict):
            summary_payload = summary["payload"]
            summary_articles = summary_payload.get("news", {}).get("articles", [])
            if isinstance(summary_payload.get("article"), dict):
                summary_articles = summary_articles + [summary_payload["article"]]
            game_news = news_items(query, espn_id, {"payload": {"articles": summary_articles}}, now)
            news = sorted({item["id"]: item for item in news + game_news}.values(), key=lambda item: item["publishedAt"], reverse=True)[:25]
        sources = []
        for key in keys:
            entry = self.cache.get(key)
            if not entry or entry.get("fetched_at") is None:
                warnings.append(f"Sin descarga verificada de {key}; el proveedor está pendiente o inaccesible.")
                continue
            payload = entry.get("payload") or {}
            rows = (len(payload.get("injuries", [])) if key == "injuries" else
                    len(payload.get("articles", [])) if key == "news" else
                    len(payload.get("events", [])) if key.startswith("scoreboard:") else
                    len(roster_athletes(payload)) if key.startswith("roster:") else 1)
            sources.append({"name": "ESPN · " + key, "url": provider_url(key),
                            "checkedAt": entry["fetched_at"], "modified": entry.get("modified"), "rows": rows})
            if entry.get("error"):
                warnings.append(f"Falló la actualización de {key}; se conserva la última descarga y su fecha original.")
            if not entry_is_fresh(entry, now, self.service.interval(now) + 30):
                warnings.append(f"La descarga de {key} está desactualizada.")
        if not reports:
            warnings.append("La ausencia de reportes de lesión no confirma que el jugador esté activo.")
        warnings.append("ESPN no garantiza una lista completa de inactivos antes del partido; confirma los anuncios oficiales.")
        return {"fetchedAt": iso(now), "reports": reports, "news": news,
                "sources": sources, "warnings": list(dict.fromkeys(warnings))}

    def health(self) -> dict:
        now = self.service.clock()
        entries = self.cache.all()
        feeds = {}
        for key in ("injuries", "news", "scoreboard:" + now.strftime("%Y%m%d")):
            entry = entries.get(key)
            feeds[key] = {"available": bool(entry and entry.get("payload") is not None),
                          "fresh": entry_is_fresh(entry, now, self.service.interval(now) + 30),
                          "checkedAt": entry.get("fetched_at") if entry else None,
                          "attemptedAt": entry.get("attempted_at") if entry else None,
                          "lastRefreshSucceeded": bool(entry and not entry.get("error")),
                          "error": entry.get("error") if entry else "Waiting for first refresh"}
        scheduler_running = bool(self.service.thread and self.service.thread.is_alive())
        ready = scheduler_running and all(feed["fresh"] and feed["lastRefreshSucceeded"] for feed in feeds.values())
        starting = all(feed["attemptedAt"] is None for feed in feeds.values())
        return {"status": "ok" if ready else "starting" if starting else "degraded", "checkedAt": iso(now),
                "schedulerRunning": scheduler_running,
                "refreshIntervalSeconds": self.service.interval(now), "feeds": feeds}
