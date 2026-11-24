import spacy, json, re, sys
nlp=spacy.load('de_core_news_md')
TIME=set("vorhin neulich gleich bislang künftig zukünftig heutzutage nun heute gestern morgen jetzt bald oft immer nie manchmal selten schon noch gerade sofort früh spät abends morgens täglich wieder später danach dann vorher damals bisher endlich zuerst lange nachts mittags wöchentlich jährlich stets neulich demnächst kürzlich inzwischen".split())
TIMEN=set("Montag Dienstag Mittwoch Donnerstag Freitag Samstag Sonntag Wochenende Woche Jahr Monat Tag Abend Morgen Mittag Nacht Uhr Stunde Stunden Minuten Jahren Tagen Wochen Monaten Januar Februar März April Mai Juni Juli August September Oktober November Dezember Sommer Winter Frühling Herbst Zeit Moment Urlaub Pause Feierabend Ende Anfang".split())
PLACEP=set("in im ins an am auf aus bei beim zu zum zur nach von vom neben hinter vor über unter zwischen".split())
def isverb(t): return t.tag_.startswith("V")
def vrole(t,sub):
  g=t.tag_
  if g in("VVPP","VAPP","VMPP"): return "Pa"
  if g=="VVIZU": return "I"
  if g.endswith("INF"):
    if g=="VMINF" and any(c.tag_.endswith("INF") for c in t.children): return "Mi"
    return "I"
  if g.endswith("FIN") or g.endswith("IMP"):
    if g.startswith("VM"): return "M"
    if g.startswith("VA") and any(isverb(c) and c.dep_=="oc" for c in t.children): return "H"
    return "V"
  return "V"
PAIR={"mich":"ich","mir":"ich","dich":"du","dir":"du","uns":"wir","euch":"ihr"}
def refl_ok(t):
  sb=[c for c in t.head.children if c.dep_=="sb"]
  h=t.head
  while not sb and h.head.i!=h.i: h=h.head; sb=[c for c in h.children if c.dep_=="sb"]
  return bool(sb) and PAIR.get(t.text.lower())==sb[0].text.lower()
def drole(t,toks):
  d=t.dep_
  if d in("sb","ep","sbp"): return "S"
  if d=="da": return "Rf" if (t.text.lower()=="sich" or t.tag_=="PRF" and refl_ok(t)) else "D"
  if d in("oa","da") and t.tag_=="PPER" and t.text.lower() in("mir","dir","ihm","uns","euch","ihnen","Ihnen".lower()) and not (t.text.lower()=="sich"): return "Rf" if refl_ok(t) else "D"
  if d=="oa":
    if t.text.lower()=="sich" or t.tag_=="PRF" and refl_ok(t): return "Rf"
    return "O"
  if d in("og",): return "D"
  if d=="pd": return "Pd"
  if d=="ng": return "Ng"
  if d=="op": return "Po"
  if d=="svp": return "X"
  if d=="cp": return "K"
  if d in("ju","cd"): return "J"
  if d=="pm" and t.text.lower()=="zu": return "Z"
  if d in("mo","mnr","app"):
    words=[x.text for x in toks]
    if any(w.lower() in TIME for w in words) or any(w in TIMEN for w in words) or re.match(r"^\d{4}$",words[-1]): return "T"
    if toks[0].tag_ in("APPR","APPRART") and toks[0].text.lower() in PLACEP: return "P"
    if t.tag_=="ADV" and t.text.lower() in("hier","dort","da","drinnen","draußen","oben","unten","überall","zuhause","weg","hin","her"): return "P"
    return "Mo"
  if d=="oc": return "Oc"
  return "Mo"
def subtree_novb(t):
  out=[t]
  for c in t.children:
    if c.dep_=="punct": continue
    if isverb(c) and c.dep_ in("rc","oc","mo","re","cj"): continue
    out+=subtree_novb(c)
  return out
def clause(v,sub,res,seen):
  res.append((v.i,v.i,vrole(v,sub),sub,v)); seen.add(v.i)
  for c in v.children:
    if c.dep_=="punct" or c.i in seen: continue
    if isverb(c):
      csub=sub or c.dep_ in("rc",) or any(x.dep_=="cp" for x in c.children) or any(x.tag_ in("PRELS","PRELAT","PWS","PWAV") and x.dep_!="punct" for x in c.children if x.i<c.i and x.i==min(y.i for y in c.subtree))
      if c.dep_=="oc" and not any(x.dep_=="cp" for x in c.children) and c.tag_ not in("VVFIN","VAFIN","VMFIN"): csub=sub
      clause(c,csub,res,seen); continue
    toks=sorted(subtree_novb(c),key=lambda x:x.i)
    for x in toks: seen.add(x.i)
    # nested clauses hanging off nouns etc
    for x in toks:
      for cc in x.children:
        if isverb(cc) and cc.i not in seen and cc.dep_ in("rc","oc","mo","re","cj"): clause(cc,True,res,seen)
    r=drole(c,toks)
    # split into contiguous runs
    run=[toks[0]]
    for x in toks[1:]:
      if x.i==run[-1].i+1: run.append(x)
      else: res.append((run[0].i,run[-1].i,r,sub,c)); run=[x]
    res.append((run[0].i,run[-1].i,r,sub,c))
def parts(text):
  d=nlp(text); out=[]
  for s in d.sents:
    root=s.root
    if not isverb(root): return None
    res=[]; seen=set(); clause(root,False,res,seen)
    covered=set(); 
    for a,b,*_ in res: covered.update(range(a,b+1))
    if any(t.i not in covered and not t.is_punct for t in s): return None
    for a,b,r,sub,h in sorted(res,key=lambda x:x[0]):
      txt=d[a:b+1].text.rstrip(".!?").strip()
      if r=="X": e=[txt,r,1 if sub else 0,txt.lower()+h.head.lemma_]
      else: e=[txt,r,1 if sub else 0]
      if r in("H",) and h.lemma_=="werden": e.append("werden")
      out.append(e)
  return out
if __name__=="__main__" and sys.argv[1:]!=["--write"]:
  for s in sys.argv[1:]: print(s, parts(s))

# Usage (adds "px" sentence parts to every example sentence in vocab/de-*.json):
#   pip install spacy "de_core_news_md @ https://github.com/explosion/spacy-models/releases/download/de_core_news_md-3.8.0/de_core_news_md-3.8.0-py3-none-any.whl"
#   python3 tools/vocab_parts.py --write
if __name__=="__main__" and sys.argv[1:]==["--write"]:
  import glob
  for p in sorted(glob.glob("vocab/de-*.json")):
    d=json.load(open(p)); n=0
    for w in d["words"]:
      try: x=parts(w["ex"])
      except Exception: x=None
      if x:
        if x[0][1] in("V","M","H") and not x[0][2]: x[0]=x[0][:3]+["q"]
        w["px"]=x; n+=1
      else: w.pop("px",None)
    json.dump(d,open(p,"w"),ensure_ascii=False,separators=(",",":")); print(p,n)
