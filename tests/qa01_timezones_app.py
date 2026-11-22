"""PonteTalk QA-01 (app side): time zones in the browser.

Opens the app twice, once as a phone in Berlin and once in New York, and checks
session times, the host-time line, the calendar file and the Google/Outlook links
in the weeks the EU and US change clocks on different dates.

Run from the repo folder:
    python3 -m http.server 8765 &      # serve the app
    pip install playwright && playwright install chromium
    python3 tests/qa01_timezones_app.py
"""
import asyncio, re, sys
from playwright.async_api import async_playwright

URL = "http://localhost:8765/"
# (label, session start in UTC, expected Berlin clock, expected New York clock)
CASES = [
    ("Mar 2 (both winter time)",            "2026-03-02T17:00:00Z", "18:00", "12:00"),
    ("Mar 16 (US summer, EU winter)",       "2026-03-16T17:00:00Z", "18:00", "13:00"),
    ("Mar 30 (both summer time)",           "2026-03-30T16:00:00Z", "18:00", "12:00"),
    ("Oct 26 (EU winter, US summer)",       "2026-10-26T17:00:00Z", "18:00", "13:00"),
    ("Nov 2 (both winter time)",            "2026-11-02T17:00:00Z", "18:00", "12:00"),
]

JS = """([iso]) => {
  const s={activity_id:'qa1',title:'QA',starts_at:iso,duration_min:60,format:'online'};
  const ics=icsFor(s), g=calGoogle(s), o=calOutlook(s);
  return { when: fmtWhen(iso), host: fmtHostTime(iso,'Europe/Berlin'),
           dtstart: (ics.match(/DTSTART:(\\S+)/)||[])[1], dtend: (ics.match(/DTEND:(\\S+)/)||[])[1],
           gdates: decodeURIComponent((g.match(/dates=([^&]+)/)||[])[1]||''),
           ostart: decodeURIComponent((o.match(/startdt=([^&]+)/)||[])[1]||'') };
}"""

def utc_compact(iso):  # 2026-03-16T17:00:00Z -> 20260316T170000Z
    return re.sub(r"[-:]", "", iso.replace(".000", ""))

async def main():
    results = []
    async with async_playwright() as p:
        b = await p.chromium.launch()
        for tz, idx in (("Europe/Berlin", 2), ("America/New_York", 3)):
            ctx = await b.new_context(timezone_id=tz, locale="en-GB")
            await ctx.route("**/*supabase.co/**", lambda r: r.abort())
            pg = await ctx.new_page()
            await pg.goto(URL); await pg.evaluate("localStorage.setItem('pt_ui','en')"); await pg.reload()
            await pg.wait_for_timeout(1000)
            for case in CASES:
                label, iso, want = case[0], case[1], case[idx]
                r = await pg.evaluate(JS, [iso])
                start = utc_compact(iso)
                results.append((f"{tz}: {label} shows {want}", want in r["when"], r["when"]))
                if tz == "America/New_York":
                    results.append((f"{tz}: {label} also shows host's 18:00 Berlin", "18:00 in Berlin" in r["host"], r["host"] or "(none)"))
                else:
                    results.append((f"{tz}: {label} no host line when same zone", r["host"] == "", r["host"] or "(none)"))
                results.append((f"{tz}: {label} calendar file starts {start}", r["dtstart"] == start, r["dtstart"]))
                results.append((f"{tz}: {label} Google link starts {start}", r["gdates"].startswith(start), r["gdates"]))
                results.append((f"{tz}: {label} Outlook link is UTC", r["ostart"].startswith(iso[:16]), r["ostart"]))
            await ctx.close()
        await b.close()
    bad = 0
    for name, ok, got in results:
        bad += not ok
        print(("✅ " if ok else "❌ ") + name + "  →  " + str(got))
    print(f"\n{len(results)-bad}/{len(results)} passed")
    sys.exit(1 if bad else 0)

asyncio.run(main())
