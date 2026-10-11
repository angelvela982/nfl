"""Legacy v0.1: verify source schemas and independently audit the original formula.
This Python audit does not execute the v0.2 engine or validate its accuracy.
Usage: python3 scripts/audit_sources.py --season 2026
Use --offline-dir /path/to/csvs to reproduce with previously downloaded files.
"""
import argparse, csv, io, json, hashlib, math, urllib.request
from pathlib import Path
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from collections import defaultdict
p=argparse.ArgumentParser();p.add_argument('--season',type=int,required=True)
p.add_argument('--offline-dir',type=Path);p.add_argument('--output',type=Path,default=Path('docs/archive/AUDITORIA-v0.1-replay.json'))
a=p.parse_args();year=a.season;now=datetime.now(timezone.utc)
base='https://github.com/nflverse/nflverse-data/releases/download/'
sources={
 'games':('https://raw.githubusercontent.com/nflverse/nfldata/master/data/games.csv',['game_id','gametime','gameday','season','week','home_team','away_team']),
 f'stats{year}':(base+f'stats_player/stats_player_week_{year}.csv',['player_id','game_id','team','opponent_team','passing_yards','rushing_yards','receiving_yards','receptions']),
 f'stats{year-1}':(base+f'stats_player/stats_player_week_{year-1}.csv',['player_id','game_id','team','opponent_team','passing_yards','rushing_yards','receiving_yards','receptions']),
 f'roster{year}':(base+f'rosters/roster_{year}.csv',['gsis_id','full_name','team','position','status']),
 f'injuries{year}':(base+f'injuries/injuries_{year}.csv',['gsis_id','team','week','report_status','practice_status'])}
raw={};checks=[]
for key,(url,cols) in sources.items():
 if a.offline_dir: data=(a.offline_dir/(key+'.csv')).read_bytes()
 else:
  with urllib.request.urlopen(url,timeout=60) as response: data=response.read()
 rows=list(csv.DictReader(io.StringIO(data.decode('utf-8-sig'))))
 assert rows and set(cols)<=set(rows[0]),key+' schema incompatible'
 raw[key]=rows
 checks.append({'source':key,'url':url,'rows':len(rows),'sha256':hashlib.sha256(data).hexdigest(),'required_columns_ok':True})
games={}
for r in raw['games']:
 if r['game_type'] not in ['REG','WC','DIV','CON','SB'] or not r['gametime']:continue
 try:r['date']=datetime.strptime(r['gameday']+' '+r['gametime'],'%Y-%m-%d %H:%M').replace(tzinfo=ZoneInfo('America/New_York')).astimezone(timezone.utc)
 except ValueError:continue
 r['completed']=bool(r['home_score'] and r['away_score']);games[r['game_id']]=r
metrics=['passing_yards','rushing_yards','receiving_yards','receptions']
by_player=defaultdict(list);stats=[];defense={m:defaultdict(dict) for m in metrics};ids=set()
for source in [f'stats{year-1}',f'stats{year}']:
 for r in raw[source]:
  if r['position'] not in ['QB','RB','FB','WR','TE']:continue
  key=(r['player_id'],r['game_id']);assert key not in ids;ids.add(key)
  for col in metrics+['attempts','targets','carries']:r[col]=float(r[col]);assert math.isfinite(r[col])
  by_player[r['player_id']].append(r);stats.append(r)
  g=games.get(r['game_id'])
  if g and g['completed']:
   for m in metrics:
    d=defense[m][r['opponent_team']];d[r['game_id']]=d.get(r['game_id'],0)+r[m]
for rows in by_player.values():rows.sort(key=lambda x:games.get(x['game_id'],{}).get('date',datetime.min.replace(tzinfo=timezone.utc)))
def history(row,cutoff):
 return [r for r in by_player[row['player_id']] if r['team']==row['team'] and (g:=games.get(r['game_id'])) and g['completed'] and g['date']+timedelta(hours=8)<cutoff and g['date']>cutoff-timedelta(days=550)]
def mean(values):
 weights=[.85**i for i in range(len(values))]
 return sum(v*w for v,w in zip(reversed(values),weights))/sum(weights) if values else 0
factor_cache={}
def factor(opp,m,cutoff):
 key=(opp,m,cutoff)
 if key in factor_cache:return factor_cache[key]
 valid=lambda gid:games[gid]['date']+timedelta(hours=8)<cutoff and games[gid]['date']>cutoff-timedelta(days=365)
 recent=sorted([(games[gid]['date'],v) for gid,v in defense[m].get(opp,{}).items() if valid(gid)])[-8:]
 league=[v for team in defense[m].values() for gid,v in team.items() if valid(gid)]
 f=1
 if len(recent)>=3 and league and sum(league)>0:
  f=min(1.15,max(.85,1+((sum(v for _,v in recent)/len(recent))/(sum(league)/len(league))-1)*len(recent)/(len(recent)+8)))
 factor_cache[key]=f;return f
def point(rows,m,opp,cutoff):return mean([r[m] for r in rows[-12:]])*factor(opp,m,cutoff)
def quantile(values,p):
 x=(len(values)-1)*p;l=math.floor(x);h=math.ceil(x);return values[l]+(values[h]-values[l])*(x-l)
def interval(rows,m,estimate):
 if len(rows)<10:return None
 residuals=[]
 for i in range(max(4,len(rows)-16),len(rows)):
  g=games[rows[i]['game_id']]
  before=[r for r in rows[:i] if games[r['game_id']]['date']+timedelta(hours=8)<g['date']]
  if len(before)>=4:residuals.append(rows[i][m]-point(before,m,rows[i]['opponent_team'],g['date']))
 if len(residuals)<6:return None
 residuals.sort();lo=estimate+quantile(residuals,.1);hi=estimate+quantile(residuals,.9)
 if m=='receptions':lo=max(0,math.floor(lo));hi=max(lo,math.ceil(hi))
 return lo,hi
reports={}
for m in metrics:
 candidates=[r for r in stats if (g:=games.get(r['game_id'])) and g['completed'] and g['date']+timedelta(hours=8)<now and (m!='passing_yards' or r['position']=='QB')]
 candidates.sort(key=lambda r:(-games[r['game_id']]['date'].timestamp(),r['game_id']+':'+r['player_id']))
 errs=[];simple=[];covered=0;ni=0
 for r in candidates:
  cutoff=games[r['game_id']]['date'];hist=history(r,cutoff)
  if len(hist)<4:continue
  opportunity='attempts' if m=='passing_yards' else 'carries' if m=='rushing_yards' else 'targets'
  if mean([v[opportunity] for v in hist[-12:]])<(5 if m=='passing_yards' else 1):continue
  estimate=point(hist,m,r['opponent_team'],cutoff)
  errs.append(abs(estimate-r[m]));s=hist[-5:];simple.append(abs(sum(x[m] for x in s)/len(s)-r[m]))
  bounds=interval(hist,m,estimate)
  if bounds:ni+=1;covered+=bounds[0]<=r[m]<=bounds[1]
  if len(errs)==400:break
 reports[m]={'n':len(errs),'mae':sum(errs)/len(errs) if errs else None,'simple_last5_mae':sum(simple)/len(simple) if simple else None,'interval_n':ni,'observed_interval_coverage':covered/ni if ni else None}
result={'checked_at':now.isoformat(),'scope':'Independent Python implementation of documented formula; NOT execution of Swift/iOS. Historical files revised after games; conditional on observed stat rows. No accuracy guarantee.','sources':checks,'eligible_stat_rows':len(stats),'retrospective':reports}
a.output.write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
print(json.dumps({'sources_ok':len(checks),'retrospective':reports},indent=2))
