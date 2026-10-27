#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-pilot}"
output="${2:?Provide a new absolute output directory}"
case "$output" in /*) ;; *) echo 'Output must be absolute' >&2; exit 2;; esac
test -e "$output" && { echo 'Refusing to overwrite an earlier quality run' >&2; exit 2; }
manifest="$root/Verification/Automation/Fixtures/DocumentQuality/corpus-v1.json"
case "$mode" in
  pilot) manifest="$root/Verification/Automation/Fixtures/DocumentQuality/pilot-v1.json"; method='controlledAnswersHaveCorrectRequirementScores()';;
  holdout) manifest="$root/Verification/Automation/Fixtures/DocumentQuality/holdout-v1.json"; method='controlledAnswersHaveCorrectRequirementScores()';;
  repairs) manifest="$root/Verification/Automation/Fixtures/DocumentQuality/generation-regressions-v3.json"; method='controlledAnswersHaveCorrectRequirementScores()';;
  focus) manifest="$root/Verification/Automation/Fixtures/DocumentQuality/generation-focus-v1.json"; method='focusedGenerationRegressions()';;
  followup) manifest="$root/Verification/Automation/Fixtures/DocumentQuality/generation-followup-v1.json"; method='controlledAnswersHaveCorrectRequirementScores()';;
  semantic) manifest="$root/Verification/Automation/Fixtures/DocumentQuality/semantic-controls-v3.json"; method='semanticControlsRejectBadDrafts()';;
  acceptance) manifest="$root/Verification/Automation/Fixtures/DocumentQuality/acceptance-regressions.json"; method='knownFalseApprovalsAreRejected()';;
  unit) method='unused';;
  controls) method='controlledAnswersHaveCorrectRequirementScores()';;
  generation) method='frozenCorpusGenerationRecordsEveryAttempt()';;
  *) echo 'Use pilot, controls, holdout, repairs, generation, focus, followup, semantic, acceptance, or unit' >&2; exit 2;;
esac
mkdir -p "$output"
cp "$manifest" "$output/input.json"
cp "$root/Verification/Automation/Fixtures/DocumentQuality/semantic-controls-v3.json" "$output/semantic-control-contract.json"
cp "$root/Verification/Automation/Fixtures/DocumentQuality/acceptance-regressions.json" "$output/acceptance-control-contract.json"
cp "$root/FoundationEvals/FoundationEvalsTests/EvaluationDocumentQualityTests.swift" "$output/quality-harness.swift"
cp "$root/FoundationEvals/FoundationEvals/Services/EvaluationDocumentGenerator.swift" "$output/generator.swift"
cp "$root/FoundationEvals/FoundationEvals/Services/EvaluationDocumentDraftPipeline.swift" "$output/draft-pipeline.swift"
cp "$root/FoundationEvals/FoundationEvals/Services/EvaluationDocumentSemanticReviewer.swift" "$output/semantic-reviewer.swift"
cp "$root/FoundationEvals/FoundationEvals/Services/EvaluationRunner+Judge.swift" "$output/judge.swift"
cp "$root/FoundationEvals/FoundationEvals/Services/EvaluationRunner+DocumentJudge.swift" "$output/document-judge.swift"
cp "$root/plugins/apple-foundation-evals/native/AppEngine/EvaluationJudge.swift" "$output/judge-schema.swift"
python3 - "$root" "$output" <<'PYHASH'
import hashlib, json, sys
from pathlib import Path
root, output = map(Path, sys.argv[1:])
services = root / "FoundationEvals/FoundationEvals/Services"
paths = set(services.glob("Evaluation*Judge*.swift")) | {services / "EvaluationRunner.swift", services / "EvaluationRunner+Prompt.swift"}
paths.update((root / "plugins/apple-foundation-evals/native/AppEngine").glob("Evaluation*Judge*.swift"))
(output / "judge-source-hashes.json").write_text(json.dumps({str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(paths)}, sort_keys=True))
PYHASH
git -C "$root" rev-parse HEAD > "$output/base-commit.txt"
git -C "$root" diff HEAD -- FoundationEvals script Verification/Automation/Fixtures/DocumentQuality plugins/apple-foundation-evals/native/AppEngine > "$output/source.patch"
if [[ -n "${INTENTS_DOCUMENT_QUALITY_JUDGE_CONFIG:-}" ]]; then
  cp "$INTENTS_DOCUMENT_QUALITY_JUDGE_CONFIG" "$output/judge-config.json"
  export INTENTS_DOCUMENT_QUALITY_JUDGE_CONFIG="$output/judge-config.json"
  export TEST_RUNNER_INTENTS_DOCUMENT_QUALITY_JUDGE_CONFIG="$output/judge-config.json"
fi
export INTENTS_DOCUMENT_QUALITY_CORPUS="$output/input.json"
export INTENTS_DOCUMENT_QUALITY_OUTPUT="$output"
export TEST_RUNNER_INTENTS_DOCUMENT_QUALITY_CORPUS="$output/input.json"
export TEST_RUNNER_INTENTS_DOCUMENT_QUALITY_OUTPUT="$output"
export INTENTS_DOCUMENT_ACCEPTANCE_CORPUS="$output/acceptance-control-contract.json"
export TEST_RUNNER_INTENTS_DOCUMENT_ACCEPTANCE_CORPUS="$INTENTS_DOCUMENT_ACCEPTANCE_CORPUS"
tests=("-only-testing:FoundationEvalsTests/EvaluationDocumentQualityTests/$method")
if [[ "$mode" == semantic ]]; then
  tests+=("-only-testing:FoundationEvalsTests/EvaluationDocumentQualityTests/knownFalseApprovalsAreRejected()")
fi
if [[ "$mode" == unit ]]; then tests=(); fi
if [[ "$mode" == generation || "$mode" == unit ]]; then
  tests+=("-only-testing:FoundationEvalsTests/EvaluationDocumentSemanticTests"
    "-only-testing:FoundationEvalsTests/EvaluationDocumentTests"
    "-only-testing:FoundationEvalsTests/EvaluationDocumentPersistenceTests"
    "-only-testing:FoundationEvalsTests/EvaluationDocumentJudgeIsolationTests")
fi
cd "$root"
set +e
xcodebuild -jobs 2 -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-document-suite-derived \
  -resultBundlePath "$output/results.xcresult" -parallel-testing-enabled NO -collect-test-diagnostics never \
  "${tests[@]}" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test > "$output/xcodebuild.log" 2>&1
status=$?
set -e
echo "$status" > "$output/exit-code.txt"
echo "Quality run $mode finished with status $status: $output"
exit "$status"
