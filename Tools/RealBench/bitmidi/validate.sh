#!/bin/zsh
# bitmidi validation suite: aligns MIDI with known answers back to its recording and reports the timing
# error. Needs the git-ignored bench/ folder (BENCH=/path/to/bench if it is not at the repo root).
#   Tools/RealBench/bitmidi/validate.sh            # after build.sh
cd "$(dirname "$0")"
B=.build/bitmidi
BENCH=${BENCH:-../../../bench}
A=$BENCH/songs/angie
R=$BENCH/songs/ableton
M=(); for i in 0 1 2 3 4 5 6; do M+=(--midi $A/MIDI/S0$i.mid); done
run() {
  echo "=== $1"; shift
  $B validate "$@" 2>/dev/null | grep -E "transposition found|all mapped|confident sections|beat error|spans found|matched|flags vs"
}
run "angie, exact MIDI" $A/mix.flac $M --shift 0 --rate 1 --amp 0
run "angie, warped (default: +3 semitones, 1.12x +-6% tempo)" $A/mix.flac $M
run "angie, warped + 30 ms random onset jitter" $A/mix.flac $M --jitter 0.03
run "angie, warped, no drums, only piano+bass+flute" $A/mix.flac $M --no-drums --keep-parts 0,4,5
run "angie, strong drift (0.85x +-10%, 23 s period)" $A/mix.flac $M --rate 0.85 --amp 0.1 --period 23
run "angie, MIDI lacks 100-130 s" $A/mix.flac $M --cut 100:130
run "angie, MIDI plays 60-80 s twice" $A/mix.flac $M --repeat 60:80
run "angie, all at once (-5 st, 0.9x, cut, repeat, jitter, 4 parts)" $A/mix.flac $M --shift -5 --rate 0.9 --cut 30:45 --repeat 150:170 --jitter 0.02 --keep-parts 0,1,4,5
run "patience-gm (GM render of an Ableton set), warped" $R/patience-gm/mix.wav --midi $R/patience-gm/truth.json
run "in-the-rain keyonly (real Ableton export, sparse key), warped" $R/in-the-rain/keyonly.wav --midi $R/in-the-rain/keyonly.truth.json
run "in-the-rain full (real export with vocals and drums not in the key), warped" $R/in-the-rain/full.wav --midi $R/in-the-rain/full.truth.json
