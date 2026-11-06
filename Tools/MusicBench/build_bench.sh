#!/bin/zsh
# Builds `musicbench` (scores the any-instrument pipeline on rendered songs)
# from the app's own transcription sources. Usage:
#   Tools/MusicBench/build_bench.sh && Tools/MusicBench/.build/musicbench <songsDir> --set dev
set -e
cd "$(dirname "$0")"
APP=../../Semitone
T=$APP/Transcription
SOURCES=(
  bench_main.swift Options.swift Scoring.swift GroundTruth.swift
  $APP/Audio/AudioFileLoader.swift
  $T/BPConstants.swift $T/BasicPitchModel.swift $T/TranscriptionEngine.swift $T/NoteExtraction.swift
  $T/DetectionMode.swift $T/NoteEvent.swift $T/ChordAnalyzer.swift $T/BeatTracker.swift $T/TranscriptionMode.swift
  $T/Music/HarmonicPercussive.swift $T/Music/VoiceSplitter.swift $T/Music/MusicTranscriber.swift
  $T/Pipeline/PipelineStages.swift $T/Pipeline/SourceProfiler.swift $T/Pipeline/NoteEngines.swift $T/Pipeline/OnsetEnvelope.swift
  $T/Piano/PianoModel.swift $T/Piano/PianoFeatures.swift $T/Piano/PianoDecoder.swift $T/Piano/PianoTranscriber.swift
)
mkdir -p .build/bench
# Top-level code must live in main.swift.
cp bench_main.swift .build/bench/main.swift
SOURCES[1]=.build/bench/main.swift
swiftc ${OPT:--O} -framework CoreML -default-isolation MainActor -Xcc -DACCELERATE_NEW_LAPACK -o .build/musicbench $SOURCES
echo "built .build/musicbench"
