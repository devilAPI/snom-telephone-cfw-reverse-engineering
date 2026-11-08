import sys,numpy as np
R=16000;L=96
feed=np.fromfile(sys.argv[1],dtype='<i2').astype(float)
for p in sys.argv[2:]:
    x=np.fromfile(p,dtype='<i2').astype(float); x-=x.mean()
    n=1<<20; c=np.fft.irfft(np.fft.rfft(x,n)*np.conj(np.fft.rfft(feed,n)),n); lag=int(np.argmax(np.abs(c[:len(x)])))-L//2
    out=[]
    for k,(a,b) in {'sine440':(0,1),'sweep':(1.5,3.5),'chord':(4,6)}.items():
        i0,i1=int(a*R),int(b*R)
        X=np.array([feed[i0-j:i1-j] if i0-j>=0 else np.r_[np.zeros(j-i0),feed[:i1-j]] for j in range(-L//2,L//2)]).T
        y=x[lag+L//2+i0:lag+L//2+i1]
        h,*_=np.linalg.lstsq(X,y,rcond=None); e=1-((y-X@h)**2).sum()/(y**2).sum()
        out.append('%s %.1f%%'%(k,100*e))
    print(p.split('/')[-1],' linear-FIR explained: ',', '.join(out))
