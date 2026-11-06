#!/bin/zsh
# Builds `bitmidi` (fan-made MIDI -> aligned RealBench key for a real recording).
# Usage:
#   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Tools/RealBench/bitmidi/build.sh
#   Tools/RealBench/bitmidi/.build/bitmidi help
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
APP=../../../Semitone
SOURCES=(
  bitmidi_main.swift BMFeatures.swift BMAlign.swift BMRoles.swift BMChords.swift BMKey.swift
  ../MidiTruth.swift ../Truth.swift ../../MusicBench/GroundTruth.swift
  $APP/Audio/AudioFileLoader.swift $APP/Transcription/BPConstants.swift
)
mkdir -p .build/src
# Top-level code must live in main.swift.
cp bitmidi_main.swift .build/src/main.swift
SOURCES[1]=.build/src/main.swift
xcrun swiftc ${OPT:--O} -Xcc -DACCELERATE_NEW_LAPACK -o .build/bitmidi $SOURCES \
  -framework AVFoundation -framework Accelerate -framework AudioToolbox
echo "built $(pwd)/.build/bitmidi"
