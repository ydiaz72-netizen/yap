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
    if row[0] in FIX:
      p=[]
      for a,b in (x.rsplit(':',1) for x in FIX[row[0]].split('|')):
        sub=1 if b.endswith('*') else 0; b=b.rstrip('*'); r,_,v=b.partition('=')
        p.append([a,r,sub]+([v] if v else []))
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
json.dump({"v":"2026-11-24b","stories":out},open('stories/de.json','w'),ensure_ascii=False,separators=(',',':'))
print(len(out),"stories",sum(len(o["s"]) for o in out),"sentences, no parts:",miss)
for o in out:
  for e in o["s"]: print(' | '.join(f'{x[0]}:{x[1]}'+('*' if x[2] else '') for x in e.get("px",[])) or "—", )

# ---- key words for each story: words from the flashcard lists that appear in it (lemma match) ----
import spacy
_nlp=spacy.load('de_core_news_md')
V={}; RANK={"A1":0,"A2":1,"B1":2,"B2":3,"C1":4}
for l in ["a1","a2","b1","b2","c1"]:
  for w in json.load(open(f"vocab/de-{l}.json"))["words"]:
    k=w["w"].lower(); k=k[4:] if k[:4] in ("der ","die ","das ") else k
    V.setdefault(k,(w,l.upper()))
BLOCK={"die Dosis","die Sucht"}
SKIP=set("sein haben werden können müssen wollen sollen dürfen mögen möchten machen gehen geben kommen sagen gut viel sehr auch noch schon und aber oder nicht ich du er sie es wir ihr heute jetzt dann".split())
d=json.load(open("stories/de.json"))
for st in d["stories"]:
  lv=RANK[st["lv"]]; cand={}
  for e in st["s"]:
    for t in _nlp(e["de"]):
      if t.pos_ not in ("NOUN","VERB","ADJ","ADV") : continue
      svp=[c.text.lower() for c in t.children if c.dep_=="svp"]
      keys=[svp[0]+t.lemma_.lower()] if svp else [t.lemma_.lower(), t.text.lower()]
      for k in keys:
        if k not in V or k in SKIP or k in cand: continue
        noun=V[k][0]["w"][:4].lower() in ("der ","die ","das ")
        if noun!=(t.pos_=="NOUN") or V[k][0]["w"] in BLOCK: continue
        cand[k]=(V[k],e["de"])
  pick=sorted(cand.items(), key=lambda kv:(abs(RANK[kv[1][0][1]]-lv), -RANK[kv[1][0][1]]))[:6]
  st["kw"]=[{"w":v[0][0]["w"],"tr":v[0][0]["tr"],"ex":v[1]} for k,v in pick]
json.dump(d,open("stories/de.json","w"),ensure_ascii=False,separators=(',',':'))
for st in d["stories"]: print(st["id"], [x["w"] for x in st["kw"]])
