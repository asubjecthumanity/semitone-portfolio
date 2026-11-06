#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 -m unittest discover -s "$SCRIPT_DIR" -p 'test_*.py' -v
