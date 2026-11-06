#!/bin/bash
set -euo pipefail
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "The native Semitone runner requires macOS with Xcode and Core ML." >&2
  exit 2
fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
bench_dir="$(dirname "$script_dir")"
repo_dir="${1:-$(cd "$bench_dir/../.." && pwd)}"
app_dir="$repo_dir/Semitone"
out_dir="$bench_dir/.build"
mkdir -p "$out_dir"
cp "$script_dir/main.swift" "$out_dir/main.swift"
sources=(
  "$app_dir/Transcription/Piano/PianoModel.swift"
  "$app_dir/Transcription/Piano/PianoFeatures.swift"
  "$app_dir/Transcription/Piano/PianoDecoder.swift"
  "$app_dir/Transcription/Piano/PianoTranscriber.swift"
  "$app_dir/Transcription/BasicPitchModel.swift"
  "$app_dir/Transcription/TranscriptionEngine.swift"
  "$app_dir/Transcription/NoteExtraction.swift"
  "$app_dir/Transcription/DetectionMode.swift"
  "$app_dir/Transcription/TranscriptionMode.swift"
  "$app_dir/Transcription/NoteEvent.swift"
  "$app_dir/Transcription/BPConstants.swift"
  "$app_dir/Audio/AudioFileLoader.swift"
)
python3 "$script_dir/build_receipt.py" capture "$repo_dir" "$out_dir" "$script_dir/main.swift" "${sources[@]}"
xcrun swiftc -O -Xcc -DACCELERATE_NEW_LAPACK \
  "$out_dir/main.swift" \
  "${sources[@]}" \
  -framework CoreML -framework AVFoundation -framework Accelerate \
  -o "$out_dir/pianobench-native"
model_stage_dir="$(mktemp -d "$out_dir/model-XXXXXXXX")"
trap 'rm -rf "$model_stage_dir"' EXIT
xcrun coremlcompiler compile "$app_dir/TranskunBackbone.mlpackage" "$model_stage_dir"
xcrun coremlcompiler compile "$app_dir/NMP.mlpackage" "$model_stage_dir"
rm -rf "$out_dir/TranskunBackbone.mlmodelc"
mv "$model_stage_dir/TranskunBackbone.mlmodelc" "$out_dir/TranskunBackbone.mlmodelc"
rm -rf "$out_dir/NMP.mlmodelc"
mv "$model_stage_dir/NMP.mlmodelc" "$out_dir/NMP.mlmodelc"
python3 "$script_dir/build_receipt.py" finalize "$repo_dir" "$out_dir" "$script_dir/main.swift" "${sources[@]}"
echo "Built $out_dir/pianobench-native"
