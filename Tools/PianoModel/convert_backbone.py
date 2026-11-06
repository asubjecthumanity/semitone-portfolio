"""Convert Transkun's transformer backbone to Core ML for the Neural Engine.

Needs Python <= 3.13 (coremltools' native writer isn't built for 3.14), e.g.:
  /usr/bin/python3 -m venv venv39 && venv39/bin/pip install "torch==2.7.*" "torchaudio==2.7.*" \
      "coremltools==8.3.*" "numpy<2" moduleconf pretty_midi scipy ncls "setuptools<81" && \
      venv39/bin/pip install --no-deps transkun
Input  'features' [1, 691, 229, 6]  fp32 (log-mel, 6 windows; computed in Swift)
Output 'ctx'      [1, 90, 691, 256] fp32 (per-symbol, per-frame embeddings)

Everything computes in fp16 except the final ConvTranspose1d (upConv1dSkip), which stays fp32.
In fp16 on the Neural Engine that one layer is what wrecks accuracy (clip 3 F1 0.971 -> 0.840);
with it in fp32 (Core ML runs it on the CPU) the notes match the fp32 model: 1,293/1,293 on clip 3.
Measured on iPhone 17 / iOS 27 (60 s of clip 3): all-fp32 on the CPU 37.5 s, fp16 on the Neural Engine 9 s.
The GPU is avoided: on iOS 27 Core ML's GPU path (MPSGraph) aborts while compiling this model.
int8 weights change decoded notes.
"""
import torch, moduleconf, pkg_resources, coremltools as ct
import torch.utils.checkpoint as _ckpt
_ckpt.checkpoint = lambda f, *a, **k: f(*a)            # training-only; breaks tracing
_mg = torch.meshgrid
def _meshgrid(*t, **k):                                 # 1-D meshgrid is a no-op; coremltools rejects it
    if len(t) == 1 and isinstance(t[0], (list, tuple)): t = tuple(t[0])
    return (t[0],) if len(t) == 1 else _mg(*t, **k)
torch.meshgrid = _meshgrid

cm = moduleconf.parseFromFile(pkg_resources.resource_filename('transkun', 'pretrained/2.0.conf'))
model = cm["Model"].module.TransKun(conf=cm["Model"].config)
ck = torch.load(pkg_resources.resource_filename('transkun', 'pretrained/2.0.pt'), map_location='cpu', weights_only=False)
model.load_state_dict(ck.get("best_state_dict", ck.get("state_dict")), strict=False); model.eval()

class Backbone(torch.nn.Module):
    def __init__(self, m): super().__init__(); self.m = m; self.pitches = torch.tensor(m.targetMIDIPitch)
    def forward(self, feat): return self.m.backbone(feat, outputIndices=self.pitches)

example = torch.rand(1, 691, 229, 6)
with torch.no_grad(): traced = torch.jit.trace(Backbone(model).eval(), example, check_trace=False)
keep_fp32 = lambda op: op.op_type == 'conv_transpose'
ml = ct.convert(traced, inputs=[ct.TensorType(name='features', shape=tuple(example.shape))],
                outputs=[ct.TensorType(name='ctx')], convert_to='mlprogram', minimum_deployment_target=ct.target.iOS17,
                compute_precision=ct.transform.FP16ComputePrecision(op_selector=lambda op: not keep_fp32(op)))
ml.save('TranskunBackbone.mlpackage')
print('saved TranskunBackbone.mlpackage')
