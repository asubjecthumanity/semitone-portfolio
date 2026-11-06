import numpy as np
FPS=100
def load_notes(path):
    out=[]
    for l in open(path):
        f=l.strip().split(',')
        if len(f)>=3 and f[0][0].isdigit():
            amp=float(f[3])/127 if len(f)>3 else 0.5
            out.append((float(f[0]),float(f[1]),int(float(f[2])),amp))
    return sorted(out)

def events(notes, merge=0.035):
    """Cluster near-simultaneous onsets into events: (time, weight, lowest pitch, pitches)."""
    ev=[]
    for s,e,p,a in notes:
        if ev and s-ev[-1][0]<=merge: ev[-1][1].append((s,e,p,a))
        else: ev.append([s,[(s,e,p,a)]])
    res=[]
    for t,group in ev:
        low=min(g[2] for g in group)
        w=sum(0.3+g[3] for g in group)
        res.append((t,w,low,group))
    return res

def envelope(notes, T):
    n=int(T*FPS)+2; E=np.zeros(n)
    for t,w,low,group in events(notes):
        bass=1.0 if low<55 else 0.0
        E[int(round(t*FPS))]+= w + bass
    k=np.exp(-0.5*(np.arange(-6,7)/2.0)**2); return np.convolve(E,k/k.sum(),'same')

def lag_scores(E, lags):
    E=E-E.mean(); return np.array([np.dot(E[:-l],E[l:])/len(E) for l in lags])

def prior(lags, center=0.5, width=0.9):   # log-normal tempo prior around 120 BPM
    return np.exp(-0.5*(np.log2(lags/FPS/center)/width)**2)

def local_periods(E, win=12.0, hop=2.0, lo=0.3, hi=1.2, jump=0.12):
    """Period per window (frames), chosen by Viterbi so tempo moves smoothly."""
    lags=np.arange(int(lo*FPS),int(hi*FPS)+1); centers=[]; S=[]
    W=int(win*FPS); H=int(hop*FPS)
    for st in range(0, max(1,len(E)-W//2), H):
        seg=E[max(0,st-W//2):st+W//2]
        if len(seg)<lags[-1]+10: seg=np.pad(seg,(0,lags[-1]+10-len(seg)))
        sc=lag_scores(seg,lags); sc=sc/(sc.max()+1e-9)
        S.append(np.maximum(sc,0)*prior(lags)); centers.append(st)
    S=np.array(S); L=np.log(lags)
    # Viterbi over windows: stay near previous period (penalty on log-ratio change)
    pen=(L[:,None]-L[None,:])**2/(2*jump**2)
    D=np.log(S[0]+1e-6); bp=[]
    for i in range(1,len(S)):
        M=D[:,None]-pen; j=M.argmax(0); bp.append(j); D=M.max(0)+np.log(S[i]+1e-6)
    path=[int(D.argmax())]
    for j in reversed(bp): path.append(int(j[path[-1]]))
    path=path[::-1]
    return np.array(centers), lags[path].astype(float)

def track(E, centers, periods, tight=100.0):
    n=len(E); P=np.interp(np.arange(n), centers, periods)
    C=E.copy(); back=np.full(n,-1)
    for t in range(n):
        p=P[t]; a=int(max(0,t-2*p)); b=int(t-p/2)
        if b<=a: continue
        taus=np.arange(a,b); cost=C[taus]-tight*np.log((t-taus)/p)**2
        k=cost.argmax(); C[t]=E[t]+cost[k]; back[t]=taus[k]
    # end: best score within the last period
    tail=int(P[-1]); t=int(np.argmax(C[-tail:]))+n-tail; beats=[]
    while t>=0: beats.append(t); t=back[t]
    return np.array(beats[::-1])/FPS

def chroma(notes, a, b):
    v=np.zeros(12)
    for s,e,p,amp in notes:
        ov=min(e,b)-max(s,a)
        if ov>0: v[p%12]+=ov*(0.5+amp)
    return v

def downbeats(notes, beats, n, reset=3.0):
    """Choose bar positions by Viterbi: bass onsets and harmony changes favour beat 1."""
    evs=events(notes); et=np.array([e[0] for e in evs])
    B=len(beats); bass=np.zeros(B); harm=np.zeros(B); acc=np.zeros(B)
    for i,b in enumerate(beats):
        per=(beats[min(i+1,B-1)]-beats[max(i-1,0)])/2 or 0.5
        near=[evs[j] for j in np.where(abs(et-b)<0.07)[0]]
        if near:
            low=min(e[2] for e in near); acc[i]=max(e[1] for e in near)
            # a low note that is the lowest thing for a while around it
            window=[e for e in evs if b-per<=e[0]<b+per]
            if low<=min(e[2] for e in window): bass[i]=1.0
        c0=chroma(notes,b-per,b); c1=chroma(notes,b,b+per)
        den=np.linalg.norm(c0)*np.linalg.norm(c1)
        harm[i]=1-(c0@c1)/den if den>0 else 0
    acc/= acc.max() or 1; harm/= harm.max() or 1
    D=1.0*bass+1.0*harm+0.3*acc
    # states: position in bar 0..n-1 ; normal move pos+1 mod n, or pay `reset` to jump
    V=np.where(np.arange(n)==0, D[0], 0.0); back=[]
    for i in range(1,B):
        prev=np.roll(V,1)                       # pos-1 -> pos
        jump=V.max()-reset
        choose=prev>=jump; back.append((choose, V.argmax()))
        V=np.where(choose,prev,jump)+np.where(np.arange(n)==0, D[i], 0.0)
    pos=[int(V.argmax())]
    for choose,best in reversed(back):
        p=pos[-1]; pos.append((p-1)%n if choose[p] else int(best))
    pos=pos[::-1]
    return np.array([b for b,p in zip(beats,pos) if p==0])

def downbeat_envelope(notes, T, fps=FPS):
    """Where bars tend to start: low (bass) onsets plus harmony changes."""
    n=int(T*fps)+2; Bs=np.zeros(n)
    evs=events(notes)
    for t,w,low,group in evs:
        if low<55: Bs[int(round(t*fps))]+=1.0+0.5*max(g[1]-g[0] for g in group if g[2]==low)
    # harmony change: chroma before vs after, sampled every 50 ms, window 0.5 s
    step=5; H=np.zeros(n)
    starts=np.array([nn[0] for nn in notes]); ends=np.array([nn[1] for nn in notes]); pcs=np.array([nn[2]%12 for nn in notes])
    for f in range(0,n,step):
        t=f/fps; w=0.5
        def ch(a,b):
            ov=np.clip(np.minimum(ends,b)-np.maximum(starts,a),0,None); v=np.zeros(12); np.add.at(v,pcs,ov); return v
        c0=ch(t-w,t); c1=ch(t,t+w); d=np.linalg.norm(c0)*np.linalg.norm(c1)
        H[f]=1-(c0@c1)/d if d>0 else 0
    H=np.convolve(H,np.ones(step)/step,'same')
    k=np.exp(-0.5*(np.arange(-6,7)/2.0)**2); Bs=np.convolve(Bs,k/k.sum(),'same')
    D=Bs/(Bs.max() or 1)+H/(H.max() or 1)
    return D

def choose_period(E, D, beats_per_bar, lo=0.25, hi=1.2):
    """Pick the beat period: strong onset periodicity, plausible tempo, and a bar
    length (beats_per_bar x period) at which bass/harmony evidence repeats."""
    lags=np.arange(int(lo*FPS),int(hi*FPS)+1)
    on=lag_scores(E,lags); on=np.maximum(on,0)/on.max()
    score=on*prior(lags,width=1.3)
    # candidates: local maxima within 70% of the best
    cand=[i for i in range(1,len(lags)-1) if score[i]>=score[i-1] and score[i]>=score[i+1] and score[i]>=0.7*score.max()]
    Dz=D-D.mean(); best=None
    for i in cand:
        bar=int(round(lags[i]*beats_per_bar))
        if bar>=len(D)//2: continue
        # bar-level repetition, averaged over one and two bars
        rep=np.mean([np.dot(Dz[:-m],Dz[m:])/len(Dz) for m in (bar,2*bar)])
        tot=score[i]*(1+max(rep,0)/ (np.dot(Dz,Dz)/len(Dz)))
        if best is None or tot>best[0]: best=(tot,lags[i])
    return best[1] if best else lags[int(score.argmax())]

def choose_period2(E, D, beats_per_bar, margin=1.15):
    """Natural pulse from windowed tempo tracking, then metrically related
    alternatives; switch only when the bar length fits bass/harmony clearly better."""
    c,p=local_periods(E)
    base=float(np.median(p))
    lags=np.arange(20,141); on=lag_scores(E,lags); on=np.maximum(on,0)/(on.max() or 1)
    Dz=D-D.mean(); var=np.dot(Dz,Dz)/len(Dz) or 1
    def onset_at(P):
        i=np.searchsorted(lags,P); lo,hi=max(0,i-2),min(len(lags),i+3)
        return on[lo:hi].max() if hi>lo else 0
    def rep_at(P):
        vals=[np.dot(Dz[:-m],Dz[m:])/len(Dz)/var for m in (int(round(P*beats_per_bar)),int(round(2*P*beats_per_bar))) if 0<m<len(D)//2]
        return max(np.mean(vals),0) if vals else 0.0
    def total(P): return onset_at(P)*(1+rep_at(P))
    base_score=total(base); best=(base_score,base)
    for r in (2/3,3/2,1/2,2):
        P=base*r
        if not (25<=P<=120): continue
        s=total(P)
        if s>best[0] and s>margin*base_score: best=(s,P)
    return best[1]
