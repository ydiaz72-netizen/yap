# PonteTalk QA tests

Checks from the V1 roadmap (Testing rows). Each test cleans up after itself.

| File | Roadmap | What it checks | How to run |
| --- | --- | --- | --- |
| `qa01_timezones.sql` | QA-01 | Times saved in UTC, Berlin ↔ New York in the weeks the clocks change, "fits my free time", clock-change night, host's own clock | Supabase → SQL Editor → paste → Run |
| `qa01_timezones_app.py` | QA-01 | The app as a phone in Berlin and in New York: session times, "host's time" line, calendar file, Google and Outlook links | `python3 -m http.server 8765 &` then `python3 tests/qa01_timezones_app.py` |
| `qa03_waitlist.sql` | QA-03 | Waitlist positions, seat offer for 30 min, expired offer passes on, accept in time = seat, late accept = no seat, never more people than seats, leaving the waitlist | Supabase → SQL Editor → paste → Run |

The SQL tests create test users and sessions inside the test, then undo everything at the end, so nothing stays in the database and no emails go out. The result is a table with ✅ / ❌ per check.

Known limit (found by QA-01): a session that crosses midnight in your own time (for example 23:30–00:30) never counts as "fits my free time".
