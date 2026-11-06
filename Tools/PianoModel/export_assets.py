import numpy as np, torch, json
from tk_common import load_model
m=load_model()
fe=m.framewiseFeatureExtractor; sp=fe.spectrogramExtractor
wins=torch.cat([sp.win.unsqueeze(0), sp.winGen.get().t()],0).float().numpy()          # [6,4096]
fb=fe.freq2mels.float().numpy()                                                        # [2049,229]
sc=m.scorer.map[0]; vp=m.velocityPredictor; rp=m.refinedOFPredictor
parts=[('windows',wins),('melFilterbank',fb),
       ('scorerW',sc.weight.numpy()),('scorerB',sc.bias.numpy()),
       ('velW1',vp[0].weight.numpy()),('velB1',vp[0].bias.numpy()),('velW2',vp[3].weight.numpy()),('velB2',vp[3].bias.numpy()),
       ('ofW1',rp[0].weight.numpy()),('ofB1',rp[0].bias.numpy()),('ofW2',rp[3].weight.numpy()),('ofB2',rp[3].bias.numpy())]
with open('TranskunWeights.bin','wb') as f:
    for n,a in parts: f.write(np.ascontiguousarray(a,dtype='<f4').tobytes())
man=[(n,list(a.shape)) for n,a in parts]; print(json.dumps(man)); print('total floats', sum(a.size for n,a in parts))
print('hop',m.hopSize,'win',m.windowSize,'fs',m.fs,'seg',m.segmentSizeInSecond,'hopSec',m.segmentHopSizeInSecond,'eps',fe.eps,'log',fe.log,'toMono',fe.toMono)
print('pitches', m.targetMIDIPitch[:3], '...', m.targetMIDIPitch[-1], len(m.targetMIDIPitch))
print('GELU approx:', vp[1].approximate, '| velocity/refined layer types:', [type(l).__name__ for l in vp], [type(l).__name__ for l in rp])
