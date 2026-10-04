import numpy as np, scipy.io.wavfile as wf, sys
SR=44100
def load(p):
    sr,x=wf.read(p); x=x.astype(np.float32)/32768.0
    if x.ndim==1: x=np.stack([x,x],1)
    assert sr==SR; return x
def env(n,segs,base,duck,r=0.25):
    t=np.arange(n)/SR; g=np.full(n,base,np.float32)
    for a,b in segs:
        up=np.clip((t-(a-r))/r,0,1)*np.clip(((b+r)-t)/r,0,1); g=g-(base-duck)*up
    return g[:,None]
def place(out,x,at,until=None,fade=.3,gain=1.0):
    s=int(at*SR); x=x.copy()
    if until is not None:
        L=int((until-at)*SR); x=x[:L]; f=int(fade*SR); x[-f:]*=np.linspace(1,0,f)[:,None]
    e=min(len(out),s+len(x)); out[s:e]+=gain*x[:e-s]
def click():
    t=np.arange(int(.05*SR))/SR; c=np.sin(2*np.pi*1800*t)*np.exp(-t*90)*.25+np.random.randn(len(t))*np.exp(-t*300)*.08
    return np.stack([c,c],1).astype(np.float32)
mode=sys.argv[1]; bed=load('bed_raw.wav'); piano=load('piano.wav'); pb=load('playback.wav'); gt=load('guitar.wav')
if mode=='landing':
    D=45.0; n=int(D*SR); b=bed[:n].copy()
    duck=[(6.2,14.8),(20.0,26.5),(30.25,34.0)]
    b*=env(n,duck,0.62,0.16); f=int(1.6*SR); b[-f:]*=np.linspace(1,0,f)[:,None]
    out=b; place(out,piano,6.2,gain=1.0); place(out,pb,20.0,until=26.5,gain=1.0); place(out,gt,30.25,until=34.0,fade=.25,gain=1.1)
    taps=[5.25,14.55,16.6,19.7,26.55]
else:
    D=24.0; n=int(D*SR); off=int(2.0*SR); b=bed[off:off+n].copy()
    duck=[(2.6,11.2),(14.35,19.6)]
    b*=env(n,duck,0.62,0.16)
    out=b; place(out,piano,2.6,gain=1.0); place(out,pb,14.35,until=19.6,gain=1.0)
    taps=[1.85,10.75,11.85,14.0,19.65]
for t in taps: place(out,click(),t+0.02)
out=np.clip(out,-1,1); wf.write(f'{mode}_a.wav',SR,(out*32767).astype(np.int16)); print(mode,'ok',np.abs(out).max())
