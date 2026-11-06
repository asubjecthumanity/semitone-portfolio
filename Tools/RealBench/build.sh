#!/bin/zsh
# Builds `realbench` (runs every Semitone pipeline on a real recording and
# scores it) from the app's own sources, plus the compiled Core ML models it
# loads. Usage:
#   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Tools/RealBench/build.sh
#   Tools/RealBench/.build/realbench <audio> <truth.json> --out DIR
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
APP=../../Semitone
T=$APP/Transcription
BENCH=../MusicBench
SOURCES=(
  realbench_main.swift Truth.swift Evaluate.swift Pipelines.swift MidiTruth.swift Evidence.swift
  $BENCH/Scoring.swift $BENCH/GroundTruth.swift
  $APP/Audio/AudioFileLoader.swift $APP/Audio/MidiExport.swift
  $T/BPConstants.swift $T/BasicPitchModel.swift $T/TranscriptionEngine.swift $T/NoteExtraction.swift
  $T/DetectionMode.swift $T/NoteEvent.swift $T/ChordAnalyzer.swift $T/ChordSymbol.swift $T/BeatTracker.swift $T/BeatGrid.swift
  $T/TranscriptionMode.swift $T/LeadLine.swift
  $T/Music/HarmonicPercussive.swift $T/Music/VoiceSplitter.swift
  $T/Music/MusicTranscriber.swift $T/Pipeline/*.swift
  $T/Piano/PianoModel.swift $T/Piano/PianoFeatures.swift $T/Piano/PianoDecoder.swift $T/Piano/PianoTranscriber.swift
)
mkdir -p .build/src
# Top-level code must live in main.swift.
cp realbench_main.swift .build/src/main.swift
SOURCES[1]=.build/src/main.swift
xcrun swiftc ${OPT:--O} -default-isolation MainActor -Xcc -DACCELERATE_NEW_LAPACK -o .build/realbench $SOURCES \
  -framework CoreML -framework AVFoundation -framework Accelerate -framework AudioToolbox
# The app bundle ships compiled models; compile the same packages once here.
for m in NMP TranskunBackbone; do
  if [[ ! -d .build/$m.mlmodelc || $APP/$m.mlpackage -nt .build/$m.mlmodelc ]]; then
    rm -rf .build/$m.mlmodelc
    xcrun coremlcompiler compile $APP/$m.mlpackage .build > /dev/null
  fi
done
echo "built $(pwd)/.build/realbench"
