# Steps 1–2: baseline and direct passage retrieval

Completed October 18, 2026 on `codex/wiki-passage-reranking`.

**The new direct-passage mode is implemented and usable, but the evaluation does not justify
replacing the earlier article-first reranking experiment.** Both outperform legacy on answer
availability; direct passage retrieval alone does not solve incorrect answers. Default app
behavior remains legacy, and the existing experiment scheme is preserved.

## What was implemented

- A fixed 300-case evaluation suite: 184 development, 64 held-out and 52 regression cases.
  It includes the 32-question device export, 200 source-backed questions, ambiguous and
  unanswerable questions, and explicit multi-turn conversations.
- An evaluator that runs the actual Swift retrieval, safety, cleanup and overlap code, with
  the unchanged bundled Qwen weights through a local Mac MLX runtime. The gold-evidence
  control bypasses retrieval with reviewed supporting text.
- Local opt-in phone evaluation logs containing evidence, source identifiers, ranking scores,
  answers, rejection stages, model name, app build, session ID and timings.
- Direct FTS5 search across 529,379 introductions/body paragraphs, followed by the existing
  MiniLM reranker. No new inference model, vector database or per-topic exception rules.
- A reproducible offline database builder that never edits its input and validates FTS and
  SQLite integrity. One enlarged database supports all three modes.

## Frozen held-out comparison

All four configurations used the same Qwen weights and generation settings. No threshold or
ranking changes were made after examining the held-out results. The raw relevance cutoff of
4.0 remains an experimental gate, not an answerability probability.

These counts are for the **48 source-backed held-out questions**:

| Configuration | Displayed an answer | No material problem found | Incorrect | Partial / unsupported | No displayed answer |
|---|---:|---:|---:|---:|---:|
| Legacy retrieval | 26 | 23 | 2 | 1 | 22 |
| Earlier article-first reranking | 45 | 41 | 3 | 1 | 3 |
| Direct paragraph FTS5 + reranking | 41 | 33 | 6 | 2 | 7 |
| Verified evidence supplied directly | 47 | 43 | 2 | 2 | 1 |

Every generated output in the 64-case held-out run was reviewed, including outputs suppressed
by the overlap gate and the 16 ambiguous/unanswerable cases. The table above counts only
**displayed** answers for the 48 supported questions. Across all 64 cases, direct mode also
produced unsupported answers to ambiguous questions. See the detailed report and review notes.

This is a small, single-reviewer benchmark, not a calibrated accuracy estimate. “No material
problem found” is an assessment of answer meaning, source support and obvious factual errors;
it is not independent external fact-checking. Some Wikipedia statements are themselves
imprecise or wrong. The development/regression review is partial; unreviewed outputs are
explicitly unclassified rather than assumed correct.

## Where evidence is lost

For direct mode on the 48 source-backed held-out cases:

- The annotated source appeared in the first 48 FTS hits in **44/48** cases.
- Its exact supporting sentence survived into the reranker inputs in **35/48** cases.
- That sentence remained in the selected, accepted passage in **21/48** cases.

These exact-span diagnostics undercount valid alternate evidence. For example, answering that
meninges protect the brain is valid even if the annotated evidence names the skull. They are
not semantic retrieval recall or answer accuracy. Nevertheless, they expose losses during
window selection, reranking and gating after a relevant source has already been found.

Examples:

- **Book lungs:** direct FTS retrieves Arachnid/Physiology, which contains the definition and
  gas-exchange function. MiniLM still scores “What are book lungs?” at approximately **−0.44**,
  below the unchanged 4.0 cutoff. Finding the body paragraph fixes candidate access, not the gate.
- **Stars twinkling:** the nursery rhyme remains a high-scoring distractor (about **4.24**).
- **Negation:** Qwen produces “Yes, the Moon does not produce its own light” with both retrieved
  and verified evidence. Penguin/arachnid and owl-rotation questions show similar reversals.
- **Unsupported additions:** verified evidence does not prevent invented claims about octopus
  nervous systems or planetary radii.
- **Conversation:** a follow-up about Jupiter's composition can receive an answer about the Sun.
  The existing article-based topic policy remains unchanged in this retrieval-only experiment.

## Footprint and validation

- Original database: **252,276,736 bytes** (240.6 MiB).
- New database: **332,623,872 bytes** (317.2 MiB).
- Added storage: **80,347,136 bytes / 76.6 MiB**. No duplicate database is bundled.
- Qwen weights and the existing MiniLM asset are unchanged.
- Held-out median retrieval time on this Mac: legacy **71.6 ms**, earlier reranking **328.0 ms**,
  direct retrieval **257.2 ms**. Direct p95 was **664.6 ms**. These exclude evaluator/model startup
  and are not iPhone performance measurements. Some development measurements overlapped a build.
- Retrieval/tokenizer tests, index-builder immutability/integrity tests, evaluation-integrity
  tests and the unsigned generic iOS build passed.
- Original/master database SHA-256 remains
  `eac2e3c74d7214eb8b0f2cc9d095bb9114f2bc1c5f9de5640d36b1f625d5cff8`.
- The user's pre-existing project and shared-scheme edits were preserved.

## Reproduce and inspect

Use **DirectPassageExperiment** in the experimental checkout's Xcode project. Use the existing
WikiRetrievalExperiment scheme for the earlier approach. See [the setup](README.md) and
[the evaluation protocol](evaluation/README.md).

The complete run consists of 1,120 pipeline evaluations: three retrieval configurations for
all 300 cases, plus 220 verified-evidence controls. Local raw runs, manifests, review labels
and summaries are under `evaluation/runs/2026-10-18/` (ignored in Git). The small held-out and
development summaries and review labels are retained under `evaluation/results/`.

Do not promote direct mode on these results. It supplies useful body evidence and diagnostics,
but the earlier reranking configuration remains stronger on this benchmark. The next training
work should use these measured generation/answerability failures; neither Qwen fine-tuning nor
SQLite-vec was implemented in steps 1–2. Physical-iPhone latency, memory and battery validation
also remain for the later deployment stage.
