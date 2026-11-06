"""Copies the app's two AI prompts (AIChartInterpreter.systemPrompt and
cleanupPrompt) into the semitone-ai Worker, which holds them so the phone
only ever sends notes, never a prompt of its own.

    python3 Tools/AIProxy/export_prompts.py ~/Desktop/claudecode/semitone-ai/src/prompts.json

Run it whenever either prompt changes, then deploy the Worker.
"""
import json, re, sys
from pathlib import Path

src = (Path(__file__).resolve().parents[2] / "Semitone/Transcription/AIChartInterpreter.swift").read_text()


def prompt(name):
    m = re.search(rf'static let {name} = """\n(.*?)\n\s*"""', src, re.S)
    if not m:
        sys.exit(f"{name} not found")
    lines = m.group(1).split("\n")
    # Swift strips the closing delimiter's indentation from every line.
    indent = min((len(l) - len(l.lstrip(" ")) for l in lines if l.strip()), default=0)
    text = "\n".join(l[indent:] for l in lines)
    # Swift's line-continuation backslash joins a line to the next.
    return re.sub(r"\\\n", "", text)


out = {"chart": {"system": prompt("systemPrompt"), "max_tokens": 1500},
       "cleanup": {"system": prompt("cleanupPrompt"), "max_tokens": 2500}}
Path(sys.argv[1]).write_text(json.dumps(out, indent=2) + "\n")
print("wrote", sys.argv[1], {k: len(v["system"]) for k, v in out.items()})
