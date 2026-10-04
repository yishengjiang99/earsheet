import pretty_midi as pm, sys
bars=int(sys.argv[1]); out=sys.argv[2]; bpm=120; b=0.5; B=4*b
m=pm.PrettyMIDI(initial_tempo=bpm)
dr=pm.Instrument(0,is_drum=True); bass=pm.Instrument(38); keys=pm.Instrument(4); pad=pm.Instrument(89)
prog=[(48,[60,64,67]),(45,[57,60,64]),(41,[57,60,65]),(43,[55,59,62])]  # C Am F G
def n(i,v,p,s,d): i.notes.append(pm.Note(v,p,s,s+d))
for k in range(bars):
    t=k*B; root,ch=prog[k%4]
    intro = k==0
    for q in range(4):
        if not intro or q>=2: n(dr,112,36,t+q*b,.1)
        if q in(1,3): n(dr,95,39,t+q*b,.1); n(dr,70,38,t+q*b,.1)
        for e in range(2): n(dr,60 if e==0 else 80,42,t+q*b+e*b/2,.05)
    if k%4==3: n(dr,90,49,t+B-0.01,.1) if False else None
    if k%4==0: n(dr,85,49,t,1.0)
    for e in range(8):
        p=root if e%4!=3 else root+12
        n(bass,100,p-12+12,t+e*b/2,b/2*0.8)
    for q in range(4):
        for p in ch: n(keys,70,p+12,t+q*b+b/2,b*0.35)
    for p in ch: n(pad,45,p,t,B)
m.instruments+= [dr,bass,keys,pad]; m.write(out)
