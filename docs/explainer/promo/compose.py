import pretty_midi as pm
def mk(notes, prog, path, bpm=120, vel=96):
    m=pm.PrettyMIDI(initial_tempo=bpm); i=pm.Instrument(program=prog); b=60/bpm; t=0.0
    for p,beats in notes:
        if p: i.notes.append(pm.Note(vel,p,t,t+beats*b*0.95))
        t+=beats*b
    m.instruments.append(i); m.write(path); return t
E4,G4,A4,B4,C5,D5,E5=64,67,69,71,72,74,76
mel=[(E4,1),(G4,.5),(A4,.5),(C5,1),(B4,.5),(A4,.5),(G4,1),(E4,.5),(G4,.5),(A4,2),
     (A4,1),(C5,.5),(D5,.5),(E5,1),(D5,.5),(C5,.5),(D5,1),(B4,.5),(G4,.5),(C5,2)]
print('piano',mk(mel,0,'piano.mid'))
# guitar arpeggio Am - F - C - G
gt=[]
for ch in [(57,64,69,72),(53,60,65,69),(48,55,64,67),(55,62,67,71)]:
    for p in ch: gt.append((p,.5))
print('guitar',mk(gt,24,'guitar.mid',bpm=132))
