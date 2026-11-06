#!/bin/bash
# Builds the MusicBench command-line tools into Tools/MusicBench/.build/.
#
#   ./build.sh            build every target
#   ./build.sh render     build just `render`
#
# Each target is a build_<name> function plus an entry in TARGETS. GroundTruth.swift is
# the format shared by all targets, so every target compiles it.
set -euo pipefail

cd "$(dirname "$0")"
OUT=.build
mkdir -p "$OUT"

SWIFTC_FLAGS=(-O -parse-as-library)

compile() {
    local name=$1
    shift
    echo "building $OUT/$name"
    xcrun swiftc "${SWIFTC_FLAGS[@]}" -o "$OUT/$name" "$@"
}

# render: synthetic songs (WAV + ground-truth JSON) for the benchmark.
build_render() {
    compile render render_main.swift SongGen.swift Render.swift GroundTruth.swift \
        -framework AVFoundation -framework AudioToolbox
}

# To add the benchmark runner, define build_musicbench here, e.g.
#   build_musicbench() {
#       compile musicbench bench_main.swift Scoring.swift GroundTruth.swift <app sources...> \
#           -framework AVFoundation ...
#   }
# and add "musicbench" to TARGETS.

TARGETS=(render)

if [ $# -eq 0 ]; then
    set -- "${TARGETS[@]}"
fi
for target in "$@"; do
    if ! declare -F "build_$target" > /dev/null; then
        echo "unknown target: $target (known: ${TARGETS[*]})" >&2
        exit 2
    fi
    "build_$target"
done
