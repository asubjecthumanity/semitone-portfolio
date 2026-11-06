from .models import Note, Pedal, Performance, pedal_extended
from .io import load_performance, read_midi, read_csv
from .scoring import ScoreConfig, evaluate_performance, match_notes
from .benchmark import evaluate_version, compare_runs
from .runners import NativeRunner, BasicPitchRunner, CommandRunner
from .integrity import verify_run
from .version import TESTER_VERSION as __version__

__all__ = ["Note", "Pedal", "Performance", "ScoreConfig", "evaluate_performance",
           "evaluate_version", "compare_runs", "NativeRunner", "BasicPitchRunner", "CommandRunner", "verify_run",
           "load_performance", "read_midi", "read_csv", "match_notes", "pedal_extended"]
