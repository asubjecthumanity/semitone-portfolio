#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP="$SCRIPT_DIR/../../Semitone"
sh "$SCRIPT_DIR/run_python.sh"
if ! command -v swiftc >/dev/null 2>&1; then
    echo "Swift checks not run: install/use the project's Xcode Swift toolchain." >&2
    exit 2
fi
mkdir -p "$SCRIPT_DIR/.build"
swiftc -O -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -o "$SCRIPT_DIR/.build/bugfixchecks" "$SCRIPT_DIR/main.swift" \
    "$SCRIPT_DIR/../MusicBench/Options.swift" \
    "$APP/Transcription/NoteEvent.swift" \
    "$APP/Transcription/ChordAnalyzer.swift" \
    "$APP/Transcription/AIChartInterpreter.swift"
"$SCRIPT_DIR/.build/bugfixchecks"
swiftc -O -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -o "$SCRIPT_DIR/.build/audiochecks" "$SCRIPT_DIR/AudioChecks/main.swift" \
    "$APP/Audio/AudioFileLoader.swift" "$APP/Transcription/BPConstants.swift"
"$SCRIPT_DIR/.build/audiochecks"
swiftc -O -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -o "$SCRIPT_DIR/.build/generationchecks" "$SCRIPT_DIR/GenerationChecks/main.swift" \
    "$APP/Transcription/ReanalysisGeneration.swift"
"$SCRIPT_DIR/.build/generationchecks"
swiftc -O -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -o "$SCRIPT_DIR/.build/settingschecks" "$SCRIPT_DIR/SettingsChecks/main.swift" \
    "$APP/Transcription/DetectionMode.swift" "$APP/Transcription/TranscriptionMode.swift" \
    "$APP/Transcription/NoteExtraction.swift" "$APP/Transcription/BPConstants.swift" \
    "$APP/Transcription/NoteEvent.swift"
"$SCRIPT_DIR/.build/settingschecks"
swiftc -O -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -o "$SCRIPT_DIR/.build/scoringchecks" "$SCRIPT_DIR/ScoringChecks/main.swift" \
    "$SCRIPT_DIR/../MusicBench/Scoring.swift" "$SCRIPT_DIR/../MusicBench/GroundTruth.swift" \
    "$APP/Transcription/NoteEvent.swift"
"$SCRIPT_DIR/.build/scoringchecks" "$SCRIPT_DIR/scoring_oracle.json"
