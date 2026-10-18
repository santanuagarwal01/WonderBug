# Step 1 evaluation protocol

The fixed suite has 300 cases: 200 source-backed factual/explanation questions across
50 article topics, 24 unanswerable questions, 24 ambiguous questions, 20 turns in 10
conversations, and the 32 questions/answers exported on October 13, 2026.

Splits: 184 development, 64 held-out, 52 regression. Held-out article topics are excluded
from the other source-backed partitions, including the follow-up cases. This is an initial
benchmark, not a representative estimate for every child's question. Historical questions
were already seen during development and are never counted as unseen. Some held-out topics
can still be related to development topics; article-disjoint is not domain-disjoint.

`annotated-bank.json` contains source-support annotations reviewed against the pinned local
corpus. `gold.support_span` is an exact source sentence, not an exact expected generated
answer. `gold.text` includes neighboring context, and `gold_passage` supplies an article
identity. These are source-support labels, not independently fact-checked encyclopedia
claims. Some source wording is inaccurate (e.g. the generalization about all mammals in
Giraffe); answer review must distinguish fidelity from actual correctness.

No fixture, annotation, topic list or expected answer is imported by the app. No topic-specific
retrieval rules were added. Data annotations are deliberately separate from runtime behavior.

Historical export timestamps and displayed answers are preserved. App mode, retrieved passages,
model build and conversation resets were not recorded in that export. The historical cases are
therefore replayed fresh. Dedicated conversation cases test follow-ups with explicit boundaries,
using the model's actual preceding answer. They do not reconstruct undocumented device state.

## Measurements

- Stable gold source ID in the first 48 FTS hits (direct mode).
- Exact supporting sentence surviving the at-most-20 reranker inputs.
- Exact supporting sentence present in the selected passage, after rejection gates.
- Supported questions receiving no displayed answer; distinguish retrieval, safety, cleanup and
  overlap rejection. Do not call every missing answer a retrieval failure.
- Wrong, partially supported and correct generated/displayed answers from **separate review**.
  Never use the word-overlap check or MiniLM score as a factuality label.
- Local Mac cold/warm latency. Phone memory, battery and latency still require a physical-device run.

Exact-span coverage undercounts legitimate alternate evidence and paraphrases. It is a
reproducible diagnostic, not semantic retrieval recall. The gold control isolates generation
with known supporting text; it is not a realistic retrieval configuration and is not shipped.

## Reproduce

From the repository root (use absolute paths for assets):

```sh
python3 Experiments/WikiRetrieval/build_evaluator.py /tmp/wonderbug-eval
python3 -m venv /tmp/wonderbug-eval-python
/tmp/wonderbug-eval-python/bin/pip install -r Experiments/WikiRetrieval/evaluation/requirements.txt
```

Run `evaluate.py --help`. Required inputs are `--binary`, `--database`, `--reranker`,
`--resources`, `--suite`, and a new `--output` path. The default is retrieval-only on
development+regression cases, across `legacy,passages,direct-passages`.

For model answers add `--answers --model-dir <the bundled model directory> --model-id
<local LM Studio instance id>`. Start a local LM Studio server, loading the exact app model
folder (verify its path, not just its display name). No remote service is required. Add `gold`
to `--modes` for the verified-evidence control. The evaluator uses the actual Swift retrieval,
safety, cleanup and grounding code, extracts the actual Swift system prompt, and renders the
bundled tokenizer template with thinking disabled, 100 output tokens and greedy decoding.
The Mac runtime is not claimed to be bit-identical to iPhone MLX Swift.

Each run records suite/database/binary/model hashes, prompt hash, generation settings, complete
retrieval traces, answers and rejection reasons. Outputs cannot overwrite an earlier run.
Freeze implementation before running `--splits heldout`; do not tune against that result.

```sh
python3 Experiments/WikiRetrieval/summarize_evaluation.py <run.jsonl> --output <report.md>
```

The summary emits a JSON review queue. Supply separate JSONL reviews with `id`, `mode`,
`assessment` (`correct`, `incorrect`, `partial`, `unsupported`, or `nonanswer`) and `notes` using
`--reviews`. Review labels can include an `answer_sha256` fingerprint; mismatched labels are rejected. Generated and displayed-output assessments are reported separately. Unreviewed outputs are explicitly unclassified. Keep original run files immutable.

## Phone logs

The DirectPassageExperiment debug scheme enables `WONDERBUG_EVALUATION_LOG=1`. Local JSONL
records are written to `Documents/Evaluation/session-<UUID>.jsonl` and appear in an exported
app container. They include generated/displayed answers, source IDs and text, ranking scores,
rejection stage, model name, app build, timing and launch/session ID. This logging is disabled
in release builds and sends nothing to a server. A new app launch is a new conversation session;
the existing Clear button retains conversation state.
