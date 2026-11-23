#!/usr/bin/env bash
# Prints the UDID of the newest available iPhone simulator.
set -euo pipefail
xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]
phones = [(rt, d) for rt, ds in data.items() if "iOS" in rt for d in ds if d["name"].startswith("iPhone")]
if not phones:
    sys.exit("No iPhone simulator available")
phones.sort(key=lambda p: (p[0], p[1]["name"]))
print(phones[-1][1]["udid"])
'
