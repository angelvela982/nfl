"""Exercise the local service with a CURRENT published player and future game.
Run from any directory: python3 scripts/smoke-service.py [http://127.0.0.1:8765]
This is an internal development request, not a user-facing preview or deployment.
"""
import csv
from datetime import datetime, timezone
import io
import json
import sys
from urllib.parse import urlencode
from urllib.request import urlopen
from zoneinfo import ZoneInfo

base = (sys.argv[1] if len(sys.argv) > 1 else 'http://127.0.0.1:8765').rstrip('/')
now = datetime.now(timezone.utc)

def get(url):
    with urlopen(url, timeout=40) as response:
        return response.read()

def rows(url):
    return list(csv.DictReader(io.StringIO(get(url).decode('utf-8-sig'))))

health = json.loads(get(base + '/health'))
assert health['status'] == 'ok' and health['schedulerRunning'], health
schedule = rows('https://raw.githubusercontent.com/nflverse/nfldata/master/data/games.csv')
future = []
for game in schedule:
    if game['game_type'] not in ['REG', 'WC', 'DIV', 'CON', 'SB']:
        continue
    try:
        date = datetime.strptime(game['gameday'] + ' ' + game['gametime'], '%Y-%m-%d %H:%M').replace(tzinfo=ZoneInfo('America/New_York')).astimezone(timezone.utc)
    except ValueError:
        continue
    if now < date and (date - now).total_seconds() < 16 * 86400:
        future.append((date, game))
assert future, 'No published game within 16 days; this functional check needs a scheduled game.'
kickoff, game = min(future, key=lambda pair: pair[0])
roster = rows(f"https://github.com/nflverse/nflverse-data/releases/download/rosters/roster_{game['season']}.csv")
players = [r for r in roster if r.get('team') == game['home_team'] and r.get('gsis_id') and r.get('status') == 'ACT' and r.get('position') in ['QB', 'RB', 'WR', 'TE', 'K'] and r.get('espn_id') not in [None, '', 'NA']]
assert players, 'No active player with a provider ID for this team.'
player = max(players, key=lambda r: int(r.get('week') or 0))
query = {'player_id': player['gsis_id'], 'espn_id': str(int(float(player['espn_id']))), 'name': player['full_name'], 'team': player['team'], 'game_id': game['game_id'], 'kickoff': kickoff.isoformat(), 'season': game['season'], 'week': game['week']}
context = json.loads(get(base + '/v1/context?' + urlencode(query)))
assert {'fetchedAt', 'reports', 'news', 'sources', 'warnings'} <= context.keys(), context
assert len(context['sources']) >= 4, context['warnings']
assert all(report['playerID'] == player['gsis_id'] for report in context['reports']), context['reports']
print(json.dumps({'health': health['status'], 'player': player['full_name'], 'game': game['game_id'], 'reports': len(context['reports']), 'news': len(context['news']), 'sources': len(context['sources']), 'warnings': context['warnings']}, ensure_ascii=False))
