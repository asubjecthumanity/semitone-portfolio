"""Run the PyTorch reference; emit notes/sustain or enforce segment-feature parity."""
import argparse
import json
from pathlib import Path
import sys

try:
    from .compare import (compare_features, limit, load_features, DEFAULT_FEATURE_MAX_ABS, DEFAULT_FEATURE_MEAN_ABS)
    from .reference_io import clipped_reference_events
except ImportError:
    from compare import (compare_features, limit, load_features, DEFAULT_FEATURE_MAX_ABS, DEFAULT_FEATURE_MEAN_ABS)
    from reference_io import clipped_reference_events


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prefix")
    parser.add_argument("segment", nargs="?", type=int)
    parser.add_argument("--feature-max-abs", type=float, default=DEFAULT_FEATURE_MAX_ABS)
    parser.add_argument("--feature-mean-abs", type=float, default=DEFAULT_FEATURE_MEAN_ABS)
    args = parser.parse_args(argv)
    if args.segment is not None and args.segment < 0:
        parser.error("segment must be nonnegative")
    try:
        limit(args.feature_max_abs, "feature maximum error")
        limit(args.feature_mean_abs, "feature mean error")
        # Keep heavyweight/model imports out of the portable validation path.
        import numpy as np
        import torch
        try:
            from .tk_common import load_model
        except ImportError:
            from tk_common import load_model
        from transkun.Util import makeFrame
        model = load_model()
        prefix = args.prefix
        samples = load_features(prefix + "_samples.f32")
        audio = np.asarray(samples, dtype=np.float32)
        if args.segment is not None:
            k = args.segment
            pad, step, segment = 352_800, 353_280, 705_600
            padded = np.concatenate([np.zeros(pad, np.float32), audio, np.zeros(pad, np.float32)])
            start = k * step
            source = np.zeros(segment, np.float32)
            count = max(0, min(segment, len(padded) - start))
            source[:count] = padded[start:start + count]
            frames = makeFrame(torch.tensor(source)[None], model.hopSize, model.windowSize).unsqueeze(0)
            frames = (frames - frames.mean(dim=[1, 2, 3], keepdim=True)) / (frames.std(dim=[1, 2, 3], keepdim=True) + 1e-8)
            reference = model.framewiseFeatureExtractor(frames).reshape(-1).numpy()
            python_path = f"{prefix}_feat{k}_python.f32"
            np.asarray(reference, dtype="<f4").tofile(python_path)
            report = compare_features(load_features(python_path), load_features(f"{prefix}_feat{k}.f32"),
                                      max_abs=args.feature_max_abs, mean_abs=args.feature_mean_abs)
            print(json.dumps(report, sort_keys=True, allow_nan=False))
            return 0 if report["passed"] else 1
        notes, sustain = clipped_reference_events(model.transcribe(torch.tensor(audio)[:, None]), len(audio) / 44_100)
        # Validate both lists before writing either file, so malformed decoder
        # output cannot create a seemingly valid partial reference CSV.
        Path(prefix + "_python.csv").write_text("".join(",".join(map(str, row)) + "\n" for row in notes), encoding="utf-8")
        Path(prefix + "_python_sustain.csv").write_text("".join(",".join(map(str, row)) + "\n" for row in sustain), encoding="utf-8")
        print(f"python notes {len(notes)}; sustain spans {len(sustain)}")
        return 0
    except (OSError, ValueError, ImportError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    sys.exit(main())
