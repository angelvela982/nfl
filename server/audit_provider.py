"""Capture actual connectivity/schema evidence without inventing provider responses."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path

from .cache import iso
from .espn_provider import ESPNProvider, provider_url


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("server/provider-audit.json"))
    parser.add_argument("--date", default=datetime.now(timezone.utc).strftime("%Y%m%d"))
    parser.add_argument("--event", help="Verified numeric ESPN event ID to audit summary")
    arguments = parser.parse_args()
    provider = ESPNProvider()
    keys = ["injuries", "news", "scoreboard:" + arguments.date, "roster:CHI"]
    if arguments.event:
        keys.append("summary:" + arguments.event)
    results = []
    for key in keys:
        result = {"key": key, "url": provider_url(key), "checkedAt": iso(datetime.now(timezone.utc))}
        try:
            payload, modified = provider.fetch(key)
            result.update({"success": True, "keys": sorted(payload), "modified": modified})
        except Exception as error:
            result.update({"success": False, "errorType": type(error).__name__, "error": str(error)[:300]})
        results.append(result)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps({"results": results}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"passed": sum(result["success"] for result in results), "total": len(results), "output": str(arguments.output)}))


if __name__ == "__main__":
    main()
