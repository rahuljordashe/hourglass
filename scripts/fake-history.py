#!/usr/bin/env python3
"""Writes a made-up usage history into a sandbox home, for screenshots and trying the History
window without real readings. Nothing in it comes from a real account.

    scripts/fake-history.py /tmp/notch-sandbox [support-folder-name]
    HOURGLASS_HOME=/tmp/notch-sandbox .build/debug/Hourglass --render-previews /tmp/previews
"""
import json, os, random, sys
from datetime import datetime, timedelta, timezone

home = sys.argv[1]
folder = sys.argv[2] if len(sys.argv) > 2 else "Hourglass"
support = os.path.join(home, "Library/Application Support", folder)
history = os.path.join(support, "history")
os.makedirs(history, exist_ok=True)
for name in os.listdir(history):
    os.remove(os.path.join(history, name))

random.seed(7)
now = datetime.now().astimezone().replace(second=0, microsecond=0)
days = int(os.environ.get("FAKE_DAYS", "24"))
start = (now - timedelta(days=days)).replace(hour=0, minute=0)
# The week resets on Thursdays at 18:00 local time.
reset = start.replace(hour=18)
while reset.weekday() != 3:
    reset += timedelta(days=1)
week_reset = reset
iso = lambda d: d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

lines, weekly, five, five_reset, credits = [], 0.0, 0.0, None, 0.0
last_read, last_written = None, None
skip_day = (now - timedelta(days=9)).date()        # Mac off all day
phone_night = (now - timedelta(days=4)).date()     # used on the phone overnight

t = start
while t <= now:
    if t >= week_reset:
        weekly, week_reset = 0.0, week_reset + timedelta(days=7)
    if five_reset and t >= five_reset:
        five, five_reset = 0.0, None
    local = t.hour + t.minute / 60
    weekend = t.weekday() >= 5
    active = (9 <= local < 12.5 or 14 <= local < 18.5 or (not weekend and 20 <= local < 21.5)) and t.date() != skip_day
    if weekend and random.random() < 0.6:
        active = active and 10 <= local < 13
    if active:
        burst = random.random()
        rise = 0.0 if burst < 0.35 else random.uniform(0.2, 1.4 if not weekend else 0.6)
        if t.date() == (now - timedelta(days=2)).date() and 14 <= local < 17:
            rise *= 3                                # one heavy afternoon
        if rise and five_reset is None:
            five_reset = t + timedelta(hours=5)
        weekly = min(100.0, weekly + rise)
        five = min(100.0, five + rise * 6.5)
        if t.date() == phone_night and local == 9:
            weekly += 6.0                            # shows up after the overnight gap
        credits += 0.4 if five >= 100 and random.random() < 0.5 else 0
        line = {
            "time": iso(t),
            "fiveHour": {"percent": round(five), **({"resetsAt": iso(five_reset)} if five_reset else {})},
            "weekly": {"percent": round(weekly), "resetsAt": iso(week_reset)},
            "models": [{"name": "Fable", "percent": round(weekly * 0.6), "resetsAt": iso(week_reset)}],
            "creditsUsed": round(credits, 2), "creditsLimit": 50, "currency": "USD",
            "plan": "max", "source": "get_usage",
        }
        if last_read:
            line["prev"] = iso(last_read)
        same = last_written and {k: v for k, v in last_written.items() if k not in ("time", "prev", "unchanged")} == \
            {k: v for k, v in line.items() if k not in ("time", "prev", "unchanged")}
        if not same or (t - datetime.fromisoformat(last_written["time"].replace("Z", "+00:00"))).total_seconds() >= 3600:
            if same:
                line["unchanged"] = True
            lines.append(line)
            last_written = line
        last_read = t
    t += timedelta(minutes=15)

for line in lines:
    month = line["time"][:7]
    with open(os.path.join(history, f"readings-{month}.jsonl"), "a") as f:
        f.write(json.dumps(line, sort_keys=True, separators=(",", ":")) + "\n")

# Made-up Claude Code totals per hour, for the optional log layer.
hourly = {}
for line in lines:
    t = datetime.fromisoformat(line["time"].replace("Z", "+00:00"))
    if t.astimezone().date() < (now - timedelta(days=21)).date():
        continue
    hour = t.replace(minute=0, second=0)
    project = random.choices(["hourglass", "website", "notes"], [5, 3, 1])[0]
    model = "Fable" if random.random() < 0.7 else "Opus"
    if t.astimezone().date() == (now - timedelta(days=2)).date():
        project, model = "hourglass", "Fable"
    row = hourly.setdefault((hour, project, model), {"hour": iso(hour), "project": project, "model": model,
                                                     "input": 0, "output": 0, "cacheCreation": 0, "cacheRead": 0, "messages": 0})
    row["input"] += random.randint(2000, 9000)
    row["output"] += random.randint(800, 4000)
    row["cacheCreation"] += random.randint(1000, 20000)
    row["cacheRead"] += random.randint(50000, 400000)
    row["messages"] += random.randint(2, 12)
with open(os.path.join(history, "claude-code-hourly.jsonl"), "w") as f:
    for row in sorted(hourly.values(), key=lambda r: (r["hour"], r["project"], r["model"])):
        f.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
with open(os.path.join(history, "claude-code-scan.json"), "w") as f:
    json.dump({"offsets": {}, "seen": {}, "formatChanged": False, "lastScan": iso(now - timedelta(minutes=12))}, f)

latest = lines[-1]
epoch = lambda s: datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
plan = {
    "schema": 2, "source": "get_usage", "isSeeded": False, "promos": [], "subscriptionType": "max",
    "fetchedAt": now.timestamp() - 120,
    "fiveHour": {"percent": latest["fiveHour"]["percent"], **({"resetsAt": epoch(latest["fiveHour"]["resetsAt"])} if "resetsAt" in latest["fiveHour"] else {})},
    "sevenDay": {"percent": latest["weekly"]["percent"], "resetsAt": epoch(latest["weekly"]["resetsAt"])},
    "modelScoped": [{"kind": "weekly_scoped", "modelName": "Fable", "percent": latest["models"][0]["percent"], "resetsAt": epoch(latest["weekly"]["resetsAt"])}],
    "credits": {"isEnabled": True, "monthlyLimit": 50, "used": latest["creditsUsed"], "currency": "USD"},
}
with open(os.path.join(support, "plan-usage.json"), "w") as f:
    json.dump(plan, f)
print(f"Wrote {len(lines)} made-up readings to {history}")
