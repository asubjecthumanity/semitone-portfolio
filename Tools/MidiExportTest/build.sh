#!/bin/sh
# Builds and runs the MIDI export checks on macOS (see main.swift).
# usage: Tools/MidiExportTest/build.sh [directory to keep the .mid files in]
set -e
cd "$(dirname "$0")"
APP=../../Semitone
OUT="${TMPDIR:-/tmp}/midiexporttest"
swiftc -O -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -o "$OUT" main.swift \
    "$APP/Audio/MidiExport.swift" \
    "$APP/Transcription/NoteEvent.swift" \
    "$APP/Transcription/ChordAnalyzer.swift" \
    "$APP/Transcription/ChordSymbol.swift" \
    "$APP/Transcription/Pipeline/ChordVoicer.swift" \
    "$APP/Transcription/BeatGrid.swift" \
    "$APP/Transcription/BeatTracker.swift"
"$OUT" "$@"
