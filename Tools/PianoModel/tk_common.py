import torch, moduleconf, numpy as np, pkg_resources, math
def load_model():
    cm=moduleconf.parseFromFile(pkg_resources.resource_filename('transkun','pretrained/2.0.conf'))
    m=cm["Model"].module.TransKun(conf=cm["Model"].config)
    c=torch.load(pkg_resources.resource_filename('transkun','pretrained/2.0.pt'),map_location='cpu',weights_only=False)
    m.load_state_dict(c.get("best_state_dict",c.get("state_dict")),strict=False); m.eval(); torch.set_grad_enabled(False)
    return m
