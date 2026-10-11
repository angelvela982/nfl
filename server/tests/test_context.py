from concurrent.futures import wait
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request

from server.__main__ import BoundedHTTPServer, handler_for
from server.cache import SnapshotCache, iso, parse_date
from server.context import (ContextBuilder, ContextQuery, athlete_id, injury_reports,
                            matching_event, news_items, resolve_identity)
from server.espn_provider import ESPNProvider, compact_payload, provider_url, validate_payload
from server.scheduler import RefreshService

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"
NOW = datetime(2026, 10, 11, 6, 20, tzinfo=timezone.utc)


def fixture(name):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def query(**changes):
    values = dict(player_id="00-0039849", espn_id="4432708", name="Marvin Harrison Jr.",
                  team="ARI", game_id="2026_05_DET_ARI", kickoff="2026-10-11T20:25:00Z", season="2026", week="5")
    values.update(changes)
    return ContextQuery.parse({key: [value] for key, value in values.items()})


def real_payloads():
    return {
        "injuries": fixture("espn-injuries-redacted.json"),
        "news": fixture("espn-news-redacted.json"),
        "roster:ARI": fixture("espn-roster-redacted.json"),
        "scoreboard:20261011": fixture("espn-scoreboard-redacted.json"),
        "summary:401872991": fixture("espn-summary-redacted.json"),
    }


class FakeProvider:
    def __init__(self, payloads=None):
        self.payloads = payloads or real_payloads()
        self.calls = []
        self.error = None

    def fetch(self, key):
        self.calls.append(key)
        if self.error:
            raise self.error
        return deepcopy(self.payloads[key]), None


class ServiceCase(unittest.TestCase):
    def setUp(self):
        self.provider = FakeProvider()
        self.cache = SnapshotCache()
        self.current = NOW
        self.service = RefreshService(self.provider, self.cache, clock=lambda: self.current, tick_seconds=0.03)
        self.builder = ContextBuilder(self.service)
        self.addCleanup(self.service.close)

    def seed(self):
        for key, value in real_payloads().items():
            self.cache.record_success(key, value, NOW)

    def test_failed_refresh_preserves_success_time_and_payload(self):
        future = self.service.refresh("injuries", force=True)
        self.assertTrue(future.result(timeout=2))
        original = self.cache.get("injuries")
        self.current += timedelta(minutes=20)
        self.provider.error = urllib.error.URLError("Provider offline")
        self.assertFalse(self.service.refresh("injuries", force=True).result(timeout=2))
        cached = self.cache.get("injuries")
        self.assertEqual(cached["payload"], original["payload"])
        self.assertEqual(cached["fetched_at"], original["fetched_at"])
        self.assertEqual(cached["attempted_at"], iso(self.current))
        self.assertIn("offline", cached["error"])

    def test_failure_does_not_create_fake_source_stamp(self):
        self.provider.error = urllib.error.URLError("offline")
        context = self.builder.build(query())
        self.assertEqual(context["sources"], [])
        self.assertEqual(context["reports"], [])
        self.assertTrue(any("Sin descarga" in warning for warning in context["warnings"]))

    def test_background_scheduler_fetches_without_client_requests(self):
        finished = threading.Event()
        class NotifyingProvider(FakeProvider):
            def fetch(inner, key):
                result = super().fetch(key)
                if len(inner.calls) >= 3:
                    finished.set()
                return result
        provider = NotifyingProvider()
        self.service.provider = provider
        self.service.start()
        self.assertTrue(finished.wait(timeout=2))
        with self.service.lock:
            pending = list(self.service.pending.values())
        wait(pending, timeout=2)
        self.assertEqual(set(provider.calls), {"injuries", "news", "scoreboard:20261011"})
        self.assertEqual(self.builder.health()["status"], "ok")

    def test_cadence_increases_near_game_and_retries_are_bounded(self):
        self.assertEqual(self.service.interval(), 900)
        self.service.watch(["injuries"], "game", NOW + timedelta(hours=1))
        self.assertEqual(self.service.interval(), 120)
        self.service.refresh("injuries").result(timeout=2)
        self.assertIsNone(self.service.refresh("injuries"))
        self.current += timedelta(seconds=121)
        self.service.refresh("injuries").result(timeout=2)
        self.assertEqual(self.provider.calls.count("injuries"), 2)
        self.current += timedelta(hours=8)
        self.assertEqual(self.service.interval(), 900)

    def test_real_league_injury_link_resolves_correct_player_and_game(self):
        self.seed()
        context = self.builder.build(query(), refresh=False)
        self.assertEqual(len(context["reports"]), 1)
        report = context["reports"][0]
        self.assertEqual(report["status"], "out")
        self.assertEqual(report["playerID"], "00-0039849")
        self.assertEqual(report["espnID"], "4432708")
        self.assertEqual(report["gameID"], "2026_05_DET_ARI")
        self.assertEqual(report["checkedAt"], "2026-10-11T06:13:51Z")

    def test_old_report_cannot_be_attached_to_new_game(self):
        self.seed()
        entry = self.cache.get("injuries")
        entry["payload"]["injuries"][0]["injuries"][1]["date"] = "2026-09-01T00:00:00Z"
        reports, warnings = injury_reports(query(), "4432708", entry, True, NOW)
        self.assertEqual(reports[0]["status"], "out")
        self.assertIsNone(reports[0]["gameID"])
        self.assertTrue(warnings)

    def test_recovered_active_injury_status_is_not_game_active_confirmation(self):
        self.seed()
        entry = self.cache.get("injuries")
        entry["payload"]["injuries"][0]["injuries"][1]["status"] = "Active"
        reports, _ = injury_reports(query(), "4432708", entry, True, NOW)
        self.assertEqual(reports[0]["status"], "unknown")

    def test_conflicting_athlete_team_rejects_report(self):
        self.seed()
        entry = self.cache.get("injuries")
        entry["payload"]["injuries"][0]["injuries"][1]["athlete"]["team"] = {"id": "3", "abbreviation": "CHI"}
        reports, warnings = injury_reports(query(), "4432708", entry, True, NOW)
        self.assertEqual(reports, [])
        self.assertTrue(warnings)

    def test_fetching_old_upstream_timestamp_does_not_revive_report(self):
        self.seed()
        entry = self.cache.get("injuries")
        entry["payload"]["timestamp"] = "2026-10-09T00:00:00Z"
        entry["fetched_at"] = iso(NOW)
        reports, warnings = injury_reports(query(), "4432708", entry, True, NOW)
        self.assertEqual(reports, [])
        self.assertTrue(warnings)

    def test_absent_injury_and_generic_roster_active_never_confirm_active(self):
        self.seed()
        roster = self.cache.get("roster:ARI")["payload"]
        roster["athletes"][0]["items"][0]["status"] = {"name": "Active"}
        self.cache.record_success("roster:ARI", roster, NOW)
        context = self.builder.build(query(name="Isaiah Adams", espn_id="5084939", player_id="test-gsis"), refresh=False)
        self.assertEqual(context["reports"][0]["status"], "injuredReserve")
        self.assertFalse(any(report["status"] == "active" for report in context["reports"]))
        injuries = self.cache.get("injuries")["payload"]
        injuries["injuries"] = []
        self.cache.record_success("injuries", injuries, NOW)
        context = self.builder.build(query(), refresh=False)
        self.assertEqual(context["reports"], [])
        self.assertTrue(any("no confirma" in warning for warning in context["warnings"]))

    def test_cached_failure_is_degraded_and_preserves_wire_source_date(self):
        self.seed()
        self.current += timedelta(minutes=30)
        self.cache.record_failure("injuries", self.current, "offline")
        context = self.builder.build(query(), refresh=False)
        source = next(source for source in context["sources"] if source["name"] == "ESPN · injuries")
        self.assertEqual(source["checkedAt"], iso(NOW))
        self.assertEqual(self.builder.health()["status"], "degraded")
        self.assertFalse(self.builder.health()["feeds"]["injuries"]["fresh"])

    def test_stale_roster_and_wrong_season_reject_identity_or_injury(self):
        self.seed()
        self.current += timedelta(days=2)
        context = self.builder.build(query(), refresh=False)
        self.assertEqual(context["reports"], [])
        entry = self.cache.get("injuries")
        entry["payload"]["season"]["year"] = 2025
        self.assertEqual(injury_reports(query(), "4432708", entry, True, NOW)[0], [])


class IdentityAndNewsTests(unittest.TestCase):
    def test_ambiguous_name_rejected_but_explicit_id_disambiguates(self):
        roster = {"team": {"id": "22"}, "athletes": [{"items": [
            {"id": "1", "displayName": "Same Name"}, {"id": "2", "displayName": "Same Name"}]}]}
        self.assertIsNone(resolve_identity(query(name="Same Name", espn_id=""), roster)[0])
        self.assertEqual(resolve_identity(query(name="Same Name", espn_id="2"), roster)[0], "2")
        self.assertIsNone(resolve_identity(query(name="Other Name", espn_id="2"), roster)[0])
        roster["team"]["id"] = "3"
        self.assertIsNone(resolve_identity(query(name="Same Name", espn_id="2"), roster)[0])

    def test_names_do_not_use_substrings(self):
        roster = fixture("espn-roster-redacted.json")
        self.assertIsNone(resolve_identity(query(name="Marvin Harrison", espn_id=""), roster)[0])

    def test_exact_official_player_links_only_and_conflicts_rejected(self):
        self.assertEqual(athlete_id({"links": [{"href": "https://www.espn.com/nfl/player/_/id/4432708/marvin-harrison-jr"}]}), "4432708")
        self.assertIsNone(athlete_id({"links": [{"href": "https://www.espn.com.evil.test/nfl/player/_/id/4432708/player"}]}))
        self.assertIsNone(athlete_id({"links": [{"href": "https://www.espn.com/nba/player/_/id/4432708/player"}]}))
        self.assertIsNone(athlete_id({"id": "1", "links": [{"href": "https://www.espn.com/nfl/player/_/id/2/player"}]}))

    def test_news_uses_entity_id_instead_of_taxonomy_id(self):
        entry = {"payload": fixture("espn-news-redacted.json")}
        items = news_items(query(), "4432708", entry, NOW)
        self.assertTrue(items)
        relevant = [item for item in items if "4432708" in item["playerIDs"]]
        self.assertTrue(relevant)
        self.assertTrue(all("ARI" in item["teams"] or "4432708" in item["playerIDs"] for item in items))
        article = {"id": 1, "headline": "Player ruled OUT", "description": "A synthetic headline test, not an actual announcement",
                   "published": iso(NOW), "categories": [{"type": "athlete", "id": 4432708, "athlete": {"id": 999}}],
                   "links": {"web": {"href": "https://www.espn.com/nfl/story/_/id/1/test"}}}
        self.assertEqual(news_items(query(), "4432708", {"payload": {"articles": [article]}}, NOW), [])

    def test_scoreboard_matching_requires_team_date_season_and_week(self):
        payload = fixture("espn-scoreboard-redacted.json")
        self.assertEqual(matching_event(query(), payload)[0]["id"], "401872991")
        self.assertIsNone(matching_event(query(team="CHI"), payload)[0])
        self.assertIsNone(matching_event(query(week="6"), payload)[0])
        self.assertIsNone(matching_event(query(kickoff="2026-10-11T19:25:00Z"), payload)[0])
        payload["events"].append(deepcopy(payload["events"][0]))
        self.assertIsNone(matching_event(query(), payload)[0])


class PersistenceAndProviderTests(unittest.TestCase):
    def test_atomic_persistence_survives_failed_refresh(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cache.json"
            cache = SnapshotCache(path)
            cache.record_success("injuries", {"injuries": []}, NOW)
            cache.record_failure("injuries", NOW + timedelta(hours=1), "offline")
            restored = SnapshotCache(path).get("injuries")
            self.assertEqual(restored["payload"], {"injuries": []})
            self.assertEqual(restored["fetched_at"], iso(NOW))
            self.assertFalse(path.with_name("cache.json.tmp").exists())

    def test_provider_rejects_client_destinations_and_unknown_schema(self):
        for key in ("https://localhost", "summary:https://evil.test", "roster:evil.test", "scoreboard:../test"):
            with self.assertRaises(ValueError):
                provider_url(key)
        with self.assertRaises(ValueError):
            validate_payload("injuries", {"message": "Provider changed"})
        self.assertGreaterEqual(ESPNProvider().max_bytes, 8_761_015)
        compact = compact_payload("injuries", fixture("espn-injuries-redacted.json"))
        self.assertEqual(compact["timestamp"], "2026-10-11T06:13:51Z")
        self.assertEqual(athlete_id(compact["injuries"][0]["injuries"][1]["athlete"]), "4432708")

    def test_query_rejects_duplicates_bad_dates_and_injected_ids(self):
        valid = dict(player_id=["player"], name=["Name"], team=["CHI"], game_id=["game"],
                     kickoff=["2026-10-11T17:00Z"], season=["2026"], week=["5"])
        for key, value in (("kickoff", ["2026-10-11T17:00"]), ("espn_id", ["../x"]), ("team", ["CHI", "GB"]), ("url", ["https://evil.test"])):
            with self.assertRaises(ValueError):
                ContextQuery.parse(dict(valid, **{key: value}))


class HTTPIntegrationTests(unittest.TestCase):
    setUp = ServiceCase.setUp
    seed = ServiceCase.seed

    def start_server(self):
        self.seed()
        httpd = BoundedHTTPServer(("127.0.0.1", 0), handler_for(self.builder))
        thread = threading.Thread(target=httpd.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        def close():
            httpd.shutdown()
            httpd.server_close()
            thread.join(timeout=2)
        self.addCleanup(close)
        return "http://127.0.0.1:" + str(httpd.server_port)

    def test_http_context_returns_same_swift_wire_fixture(self):
        base = self.start_server()
        args = {"player_id": "00-0039849", "espn_id": "4432708", "name": "Marvin Harrison Jr.",
                "team": "ARI", "game_id": "2026_05_DET_ARI", "kickoff": "2026-10-11T20:25:00Z", "season": 2026, "week": 5}
        with urllib.request.urlopen(base + "/v1/context?" + urllib.parse.urlencode(args), timeout=3) as response:
            self.assertEqual(response.headers["Content-Type"], "application/json; charset=utf-8")
            context = json.load(response)
        self.assertEqual(context, fixture("live-context.json"))
        self.assertEqual(context["reports"][0]["status"], "out")

    def test_http_errors_and_readonly_routes(self):
        base = self.start_server()
        for path, expected in (("/v1/context", 400), ("/missing", 404)):
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(base + path, timeout=3)
            self.assertEqual(error.exception.code, expected)
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(urllib.request.Request(base + "/v1/context", data=b"{}"), timeout=3)
        self.assertEqual(error.exception.code, 405)


if __name__ == "__main__":
    unittest.main()
