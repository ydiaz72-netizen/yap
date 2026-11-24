# Builds stories/de.json from tools/stories_*.py (run from the repo root). Needs spaCy + de_core_news_md (see vocab_parts.py).
import json,sys
sys.path.insert(0,'tools')
from vocab_parts import parts
L=["de","en","es","ar","fa","tr","uk","ur"]
S=[]
exec(open('tools/stories_a.py').read().replace("S=[","S+=[",1))
exec(open('tools/stories_b.py').read())
import glob,os
for f in sorted(glob.glob('tools/stories_[c-z].py')): exec(open(f).read())
out=[]; miss=0
for st in S:
  o={"id":st["id"],"lv":st["lv"],"pal":st["pal"],"title":dict(zip(L,st["title"])),"s":[],"q":[]}
  for row in st["s"]:
    assert len(row)==8,row
    exec(open('tools/stories_fix.py').read(),globals())
    if row[0] in FIX: p=[[a.rstrip('*'),b.rstrip('*'),1 if b.endswith('*') else 0] for a,b in (x.rsplit(':',1) for x in FIX[row[0]].split('|'))]
    else: p=parts(row[0])
    miss+= p is None
    if p and p[0][1] in("V","M","H") and not p[0][2]: p[0]=p[0][:3]+["q"]
    e={"de":row[0],"tr":dict(zip(L[1:],row[1:]))}
    if p: e["px"]=p
    o["s"].append(e)
  for q in st["q"]:
    assert len(q)==9,q
    o["q"].append({"de":q[0],"ok":bool(q[1]),"tr":dict(zip(L[1:],q[2:]))})
  out.append(o)
json.dump({"v":"2026-11-24a","stories":out},open('stories/de.json','w'),ensure_ascii=False,separators=(',',':'))
print(len(out),"stories",sum(len(o["s"]) for o in out),"sentences, no parts:",miss)
for o in out:
  for e in o["s"]: print(' | '.join(f'{x[0]}:{x[1]}'+('*' if x[2] else '') for x in e.get("px",[])) or "—", )
