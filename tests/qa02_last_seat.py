"""PonteTalk QA-02: two people try to take the last seat at the same moment.

Needs a direct database connection (two at once), so it can't run in the SQL Editor.
Use a copy of the database or your Supabase connection string:
    pip install "psycopg[binary]"
    DATABASE_URL="postgresql://..." python3 tests/qa02_last_seat.py

It makes a test host, a 1-seat session and test guests, runs 20 rounds where two (and then five)
guests press Join at exactly the same time, checks that exactly one gets the seat and the rest
land on the waitlist, then deletes everything it made.
"""
import os, sys, json, threading, uuid
import psycopg

DSN = os.environ.get("DATABASE_URL", "host=/tmp/pgt port=5499 dbname=t user=postgres")
ROUNDS = 20

def as_user(conn, uid):
    conn.execute("select set_config('request.jwt.claim.sub', %s, false), set_config('request.jwt.claims', %s, false)",
                 (str(uid), '{"sub":"%s","role":"authenticated"}' % uid))

def main():
    admin = psycopg.connect(DSN, autocommit=True)
    host = uuid.uuid4(); guests = [uuid.uuid4() for _ in range(5)]; acts = []
    users = [host] + guests; old = None
    try:
        for u in users:
            admin.execute("insert into auth.users(id, email) values (%s, %s)", (u, f"qa-{str(u)[:8]}@test.invalid"))
            admin.execute("""insert into profiles(id, display_name, time_zone, adult_confirmed_at) values (%s,'QA','Europe/Berlin',now())
                             on conflict (id) do update set adult_confirmed_at = now()""", (u,))
        old = admin.execute("select value from app_settings where key='new_user_approval_sessions'").fetchone()
        admin.execute("update app_settings set value='0' where key='new_user_approval_sessions'")
        conns = [psycopg.connect(DSN, autocommit=True) for _ in guests]
        for c, g in zip(conns, guests): as_user(c, g)

        results = []
        for rnd in range(ROUNDS):
            k = 2 if rnd < ROUNDS // 2 else 5           # first half: 2 people, second half: 5 people
            act = uuid.uuid4(); acts.append(act)
            admin.execute("""insert into activities(id, host_id, title, language_a, starts_at, duration_min, seats, host_time_zone)
                             values (%s, %s, %s, 'de', now() + make_interval(days => %s), 60, 1, 'Europe/Berlin')""",
                          (act, host, f"QA race {rnd}", 2 + rnd))
            barrier = threading.Barrier(k); out = [None] * k
            def press(i):
                barrier.wait()
                try: out[i] = conns[i].execute("select pt_join_activity(%s)->>'status'", (act,)).fetchone()[0]
                except Exception as e: out[i] = "error: " + str(e).split("\n")[0]
            ts = [threading.Thread(target=press, args=(i,)) for i in range(k)]
            [t.start() for t in ts]; [t.join() for t in ts]
            joined = admin.execute("select count(*) from participants where activity_id=%s and status='joined'", (act,)).fetchone()[0]
            ok = joined == 1 and out.count("joined") == 1 and out.count("waitlisted") == k - 1
            results.append((rnd + 1, k, ok, out, joined))

        bad = 0
        for rnd, k, ok, out, joined in results:
            bad += not ok
            print(("✅" if ok else "❌"), f"round {rnd:2}: {k} people at once → {', '.join(out)}  (seats taken: {joined}/1)")
        print(f"\n{len(results)-bad}/{len(results)} rounds: exactly one person got the last seat, the rest went to the waitlist")
        for c in conns: c.close()
        return 1 if bad else 0
    finally:
        if old is not None:
            admin.execute("update app_settings set value=%s::jsonb where key='new_user_approval_sessions'", (json.dumps(old[0]),))
        for a in acts:
            admin.execute("delete from participants where activity_id=%s", (a,))
            admin.execute("delete from activities where id=%s", (a,))
        for u in users:
            for t in ("notifications", "user_blocks"):
                try: admin.execute(f"delete from {t} where user_id=%s", (u,))
                except Exception: pass
            admin.execute("delete from profiles where id=%s", (u,))
            admin.execute("delete from auth.users where id=%s", (u,))
        admin.close()

sys.exit(main())
