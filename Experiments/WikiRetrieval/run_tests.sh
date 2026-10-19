#!/bin/bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
repo=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d /tmp/wonderbug-wiki-tests.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
swiftc -O -default-isolation MainActor -module-cache-path "$scratch/modules" \
  "$repo/WonderBug/Services/WikiRetrievalTrace.swift" \
  "$repo/WonderBug/Services/WikiSearchService.swift" \
  "$repo/WonderBug/Services/WikiPassageReranker.swift" \
  "$repo/WonderBug/Services/SafetyService.swift" \
  "$repo/WonderBug/Services/DebugLog.swift" \
  "$repo/Experiments/WikiRetrieval/Tests.swift" -o "$scratch/tests"
"$scratch/tests" "$repo/WonderBug/Resources/wiki-minilm-vocab.txt" "$repo/Experiments/WikiRetrieval/tokenizer-parity.json" "$repo/Experiments/WikiRetrieval/build_passage_index.py"

python3 "$repo/Experiments/WikiRetrieval/test_passage_index.py"
python3 "$repo/Experiments/WikiRetrieval/test_evaluation.py"

python3 "$repo/Experiments/WikiRetrieval/test_ranking.py"
