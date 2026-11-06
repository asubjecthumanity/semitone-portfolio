"""Usage: python examples/evaluate_exports.py manifest.json predictions version output"""
import sys
from pianobench import evaluate_version

if len(sys.argv) != 5:
    raise SystemExit("usage: evaluate_exports.py manifest.json predictions_dir version output_dir")
report = evaluate_version(sys.argv[1], prediction_dir=sys.argv[2], version=sys.argv[3],
                          output_dir=sys.argv[4], prediction_offset_semantics="key_release",
                          version_metadata={"stage": "saved performance-MIDI/JSON outputs"})
print("Onset macro F1:", report["summary"]["onset"]["macro_f1"])
