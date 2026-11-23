# PonteTalk QA tests

Checks from the V1 roadmap (Testing rows). Each test cleans up after itself.

| File | Roadmap | What it checks | How to run |
| --- | --- | --- | --- |
| `qa01_timezones.sql` | QA-01 | Times saved in UTC, Berlin ↔ New York in the weeks the clocks change, "fits my free time", clock-change night, host's own clock | Supabase → SQL Editor → paste → Run |
| `qa01_timezones_app.py` | QA-01 | The app as a phone in Berlin and in New York: session times, "host's time" line, calendar file, Google and Outlook links | `python3 -m http.server 8765 &` then `python3 tests/qa01_timezones_app.py` |
| `qa02_last_seat.py` | QA-02 | 20 rounds of 2 and then 5 people pressing Join on the last seat at the same instant: exactly one gets it, the rest go to the waitlist | needs a direct database connection: `DATABASE_URL="postgresql://…" python3 tests/qa02_last_seat.py` (cleans up after itself) |
| `qa03_waitlist.sql` | QA-03 | Waitlist positions, seat offer for 30 min, expired offer passes on, accept in time = seat, late accept = no seat, never more people than seats, leaving the waitlist | Supabase → SQL Editor → paste → Run |
| `qa04_strikes.sql` | QA-04 | No-show = 1, late cancel = ½, monthly free pass, 60-day expiry, host-cancelled sessions don't count, 7-day and 30-day blocks, warn-only vs blocks on, block end | Supabase → SQL Editor → paste → Run |
| `qa05_permissions.sql` | QA-05 | Signed out / not 18+ / host / blocked / removed can't join; only the host approves, pauses and resets; outsiders can't see the room; members can't change seats, other sessions or settings directly | Supabase → SQL Editor → paste → Run |

The SQL tests create test users and sessions inside the test, then undo everything at the end, so nothing stays in the database and no emails go out. The result is a table with ✅ / ❌ per check.

| `trust_fixes.sql` | QA-04/05 | Sessions across midnight fit free times; host late cancel = ½ strike (guests none); host removes a person, seat passes on, removed person can't rejoin | Supabase → SQL Editor, after `sql/trust_fixes.sql` |

The midnight limit QA-01 found is fixed by `sql/trust_fixes.sql`.

| `vocab_duel.sql` | VC-03 | Start a duel, play once, scores hidden until you play, impossible times refused, bell for the starter, a third person or someone blocked can't join, links end after 7 days | Supabase → SQL Editor, after `sql/vocab_duel.sql` |
| `bridge_league.sql` | Bridge Builder | Weekly league: only people who joined count, max 60 XP per send and 5,000 per week, board order and own place, blocked people hidden, leaving hides you, new week starts at 0 | Supabase → SQL Editor, after `sql/bridge_league.sql` |
