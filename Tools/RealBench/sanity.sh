#!/bin/zsh
# Re-runs RealBench's sanity checks (README "Sanity checks"):
#   Tools/RealBench/sanity.sh OUTDIR [SONGDIR]
# 1. MusicBench test01 (no drums) and test02 (a kit; drums are not scored): realbench's
#    quick-music vs musicbench's "mix music" line on the same render.
# 2. Piano clip 3 of "semitone training" (read only): first 60 s, and the whole trusted set.
# 3. piano44: a 4/4 solo piano piece with two 2/4 bars (piano44/make_piano44.py, rendered with the
#    macOS General MIDI piano), so the half-bar cut that clip 3 (5/4) never takes is checked too.
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
OUT=${1:?usage: sanity.sh OUTDIR [SONGDIR]}
SONGS=${2:-$OUT/synthetic}
TRAINING=${TRAINING:-$PWD/../../data/clip3}   # AUDIOTEST3.wav is not in the repo (46 MB)
RB=$PWD/.build/realbench
MB=$PWD/../MusicBench/.build/musicbench
[[ -x $RB ]] || ./build.sh
[[ -x $MB ]] || ../MusicBench/build_bench.sh
[[ -x ../MusicBench/.build/render ]] || ../MusicBench/build.sh render
mkdir -p $OUT/truth
for song in test01 test02; do
  mkdir -p $SONGS/$song
  [[ -f $SONGS/$song/$song.wav ]] || ../MusicBench/.build/render $SONGS/$song --only $song
  $MB $SONGS/$song --set test > $OUT/musicbench_$song.txt
  python3 make_truth.py musicbench $SONGS/$song/$song.json -o $OUT/truth/$song.truth.json
  $RB $SONGS/$song/$song.wav $OUT/truth/$song.truth.json --out $OUT/$song
done
python3 make_truth.py notelist "$TRAINING/MIDITEST3_aligned_steady.json" -o $OUT/truth/test3_first60.truth.json \
  --part piano --instrument Piano --until 60 --name "TEST3 first 60 s (aligned steady)"
$RB "$TRAINING/AUDIOTEST3.wav" $OUT/truth/test3_first60.truth.json --duration 60 --out $OUT/test3_60s
python3 make_truth.py notelist "$TRAINING/MIDITEST3_aligned_steady.json" -o $OUT/truth/_steady.json --part piano --instrument Piano
python3 make_truth.py notelist "$TRAINING/MIDITEST3_aligned_rubato.json" -o $OUT/truth/_rubato.json --part piano \
  --instrument Piano --ignore 110:130 --ignore 240:250
python3 make_truth.py merge $OUT/truth/_steady.json $OUT/truth/_rubato.json -o $OUT/truth/test3_trusted.truth.json \
  --name "TEST3 trusted set (aligned steady+rubato, 110-130 and 240-250 s ignored)"
rm $OUT/truth/_steady.json $OUT/truth/_rubato.json
$RB "$TRAINING/AUDIOTEST3.wav" $OUT/truth/test3_trusted.truth.json --pipelines quick,piano --beats-per-bar 5 \
  --out $OUT/test3_full_trusted
python3 piano44/make_piano44.py -o $OUT/truth/piano44_written.json
echo '{"Piano": 0}' > $OUT/truth/piano44_programs.json
[[ -f $SONGS/piano44/mix.wav ]] || swift als2truth/render_gm.swift $OUT/truth/piano44_written.json $SONGS/piano44 \
  --programs $OUT/truth/piano44_programs.json > /dev/null
$RB $SONGS/piano44/mix.wav $SONGS/piano44/truth.json --pipelines quick,piano,music --out $OUT/piano44
echo "musicbench (compare with the quick-music rows of $OUT/test01/summary.txt, $OUT/test02/summary.txt):"
grep -hE "^  test0|^mix music|^beats|^downbeats|chords \(all" $OUT/musicbench_test0*.txt
