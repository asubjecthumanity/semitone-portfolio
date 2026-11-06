#!/bin/zsh
# Builds and runs the HarmonicPercussive test, optimized and unoptimized.
set -e
cd "$(dirname "$0")"
APP=../../../Semitone
OUT=${TMPDIR:-/tmp}/semitone-hpss-test
mkdir -p "$OUT"
for opt in -O -Onone; do
  cp hpss_test.swift "$OUT/main.swift"   # top-level code must live in main.swift
  swiftc $opt -default-isolation MainActor -o "$OUT/hpss_test$opt" "$OUT/main.swift" \
    "$APP/Transcription/Music/HarmonicPercussive.swift"
  echo "== $opt"
  "$OUT/hpss_test$opt"
done
