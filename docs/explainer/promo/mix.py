import numpy as np, scipy.io.wavfile as wf, sys
SR=44100
def load(p):
    sr,x=wf.read(p); x=x.astype(np.float32)/32768.0
    if x.ndim==1: x=np.stack([x,x],1)
    assert sr==SR; return x
def mask(n,segs,r=0.2):
    t=np.arange(n)/SR; m=np.zeros(n,np.float32)
    for a,b in segs: m=np.maximum(m,np.clip((t-(a-r))/r,0,1)*np.clip(((b+r)-t)/r,0,1))
    return m[:,None]
def place(out,x,at,src=(0,None),fade=.3,until=None):
    a=int(src[0]*SR); x=x[a:(int(src[1]*SR) if src[1] else None)].copy()
    if until is not None: x=x[:int((until-at)*SR)]
    f=int(fade*SR); x[-f:]*=np.linspace(1,0,f)[:,None]
    g=int(.02*SR); x[:g]*=np.linspace(0,1,g)[:,None]
    s=int(at*SR); e=min(len(out),s+len(x)); out[s:e]+=x[:e-s]
def click():
    t=np.arange(int(.05*SR))/SR; c=np.sin(2*np.pi*1800*t)*np.exp(-t*90)*.25+np.random.RandomState(1).randn(len(t))*np.exp(-t*300)*.08
    return np.stack([c,c],1).astype(np.float32)
mode=sys.argv[1]; full=load('bed_raw.wav'); drums=load('bed_drums.wav'); piano=load('piano.wav'); pb=load('playback.wav'); gt=load('guitar.wav')
if mode=='landing':
    D,off=39.5,2.0; demos=[(6.0,10.6),(16.0,21.5),(25.5,29.0)]
    piano_parts=[(6.0,(0,2.0),.02),(8.0,(6.0,None),.3)]; extra=[(pb,16.0,21.5,.3),(gt,25.5,29.0,.25)]
    taps=[5.05,10.3,12.3,15.5,21.55]; endfade=1.6
else:
    D,off=19.0,1.0; demos=[(2.5,6.6),(10.0,14.6)]
    piano_parts=[(2.5,(0,2.0),.02),(4.5,(6.5,None),.3)]; extra=[(pb,10.0,14.6,.3)]
    taps=[1.85,6.35,7.45,9.6,14.65]; endfade=0.01
n=int(D*SR); o=int(off*SR); m=mask(n,demos)
out=full[o:o+n]*0.62*(1-m)+drums[o:o+n]*0.32*m
f=int(endfade*SR); out[-f:]*=np.linspace(1,0,f)[:,None]
for at,src,fd in piano_parts: place(out,piano,at,src=src,fade=fd)
for x,at,until,fd in extra: place(out,x,at,until=until,fade=fd)
for t in taps: place(out,click(),t+0.02,fade=.01)
out=np.clip(out,-1,1); wf.write(f'{mode}_a.wav',SR,(out*32767).astype(np.int16)); print(mode,'ok',round(len(out)/SR,2))
