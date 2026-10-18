# Direct passage search and evaluation (steps 1–2)

The new opt-in scheme is **DirectPassageExperiment**, using
`WONDERBUG_WIKI_RETRIEVAL=direct-passages`. The existing WikiRetrievalExperiment scheme and
legacy behavior remain available. The app defaults to legacy unless a scheme opts in.

Direct mode searches titles, section headings and paragraph bodies in a single FTS5 query,
without the previous article shortlist, manual synonym expansion or lead-only unknown-word
veto. It considers up to 48 paragraph hits, constructs contiguous context, screens passages
with the existing safety policy, and reranks at most 20 windows with the existing MiniLM.
Short paragraphs stay whole, including explanatory sentences after a definition. One bounded
passage reaches the unchanged Qwen model, so this experiment isolates retrieval effects.

The existing raw relevance cutoff of 4.0 remains fixed for A/B comparison. It is **not** an
answerability probability. All pre-cutoff candidates and scores are recorded to expose false
rejections. Follow-ups still use the existing article-based topic policy; entity resolution
and model training are outside these two steps. No SQLite-vec or new inference model is added.

## Build the database

```sh
python3 Experiments/WikiRetrieval/build_passage_index.py <original-simplewiki.db> <new-simplewiki.db>
```

The builder opens the source read-only, refuses existing output paths (including symlinks),
and produces an independently validated SQLite copy and manifest. Stable source IDs identify
article introductions (`a:<article>:lead`) and body paragraphs (`a:<article>:p:<ordinal>`).
A mapping table and external-content view reuse existing text; FTS5 stores a `detail=none`
index because queries need single-word matches, not phrase/NEAR positions. Titles use BM25
weight 3; headings and bodies use weight 1. There is no per-topic special casing.

On the pinned corpus, 529,379 passages (276,399 introductions plus 252,980 body paragraphs)
produce a 332,623,872-byte database, up from 252,276,736 bytes: **76.6 MiB added**.
The original FTS index remains in this one database so legacy and both experiments can use
identical source content. Bundle this generated file as `WonderBug/Resources/simplewiki.db`
inside the experimental checkout only. Do not bundle a second database or write through a
symlink to the original checkout. Default legacy mode works with either database; direct mode
returns an explicit error if the passage index is absent.

## Evaluation

See [the 300-case protocol](evaluation/README.md). `build_evaluator.py`, `evaluate.py` and
`summarize_evaluation.py` run the actual Swift retrieval/answer checks and optional unchanged
Qwen generation. The direct scheme records local debug session JSONL under
`Documents/Evaluation` in exported containers. No traces are uploaded.

Run `bash Experiments/WikiRetrieval/run_tests.sh` for retrieval, corpus construction,
provenance, failure-path, tokenizer and evaluation-integrity checks.

The earlier article-first experiment is documented below for comparison.

---

# Wikipedia passage reranking experiment

Branch: `codex/wiki-passage-reranking`.

This is an A/B prototype, not a validated replacement for legacy retrieval. A small
MiniLM reranker improves some evidence selection but still ranks misleading passages
highly. See [the measured results and failure cases](RESULTS.md).

## Try it on the phone

1. Open this worktree's `WonderBug.xcodeproj` (not the original checkout).
2. Select the shared **WikiRetrievalExperiment** scheme and your physical iPhone.
3. Run and ask questions. Xcode's `RERANK` log shows the number of candidates, elapsed
   model time and the highest raw relevance scores. Logs compile out of release builds.
4. Select the normal **WonderBug** scheme, with no experiment environment variable,
   to compare the legacy behavior. Relaunch between runs to reset conversation history.

The experiment scheme sets `WONDERBUG_WIKI_RETRIEVAL=passages`. Legacy is the default
for other launches, including release launches. This avoids shipping an unvalidated
change accidentally. Both modes currently bundle the generated reranker asset when
present; the environment switch changes behavior, not binary size.

The local worktree has read-only-by-convention symlinks to the original Qwen weights
and Wikipedia database; the app opens the database with SQLite's read-only flag.
On another checkout, supply these two existing assets as described in the root README
and export the reranker as below. The generated model is intentionally not in Git.
The source changes require a Swift 6.2+ compiler (Xcode 26+); iOS minimum remains 17.6.

## What changed

- SQLite searches titles/redirects, original query terms and bounded synonym expansions.
  Exact and expanded searches have separate candidate budgets. Original adjacent words
  retain title phrases containing stop words, and joined-word titles can compete with
  a split-word variant that actually exists in the database.
- Keep eight candidate articles and read their existing paragraphs. No database rebuild,
  paragraph vector store or embedding model is required.
- Build short contiguous sentence windows; preserve a short article identity sentence.
  Include complete qualifiers/negation rather than collecting unrelated sentences.
- Missing query words do not veto retrieval before body inspection. Unknown terms must
  still occur in a candidate's evidence; they are not silently discarded.
- Lexical scoring shortlists up to twenty passages, reserving two per article before
  filling spare slots. Individually unsafe windows are excluded using the existing gate.
- A local Core ML cross-encoder scores each question/passage pair. It uses fixed
  256-token inputs (at most 48 query tokens), 8-bit weight compression and FP16 compute.
- The best passage is returned only above the provisional raw-score cutoff of 4.0.
  This is a tuning parameter, NOT a probability or a validated answerability threshold.
- Qwen, its prompt, answer cleanup and final safety/grounding checks are unchanged.
  Follow-ups stay with their previous article and supply the previous question to the
  reranker. Missing/broken model assets fail closed with a distinct debug reason.

`WikiSearchService(databaseURL:)` still defaults to legacy for existing evaluation
clients. The app opts into the experiment only through the scheme environment.
The old Python reference is unchanged; the new path is evaluated in Swift.

## Export the model

Use an isolated Python 3.12 environment on a Mac. The download/conversion runs at
build time; the iOS app performs no downloads or network requests.

```sh
python3.12 -m venv /tmp/wonderbug-reranker-env
/tmp/wonderbug-reranker-env/bin/pip install -r Experiments/WikiRetrieval/requirements.txt
/tmp/wonderbug-reranker-env/bin/python Experiments/WikiRetrieval/export_reranker.py \
  --output WonderBug/Resources --cache /tmp/wonderbug-reranker-cache
```

The script pins the model revision, emits `WikiMiniLM.mlpackage` and its vocabulary,
checks source-versus-Core-ML score differences on seven sample pairs, and updates
`tokenizer-parity.json` beside the script. Xcode compiles the package to `WikiMiniLM.mlmodelc`.
No new Swift package dependency is needed. See [attribution](THIRD_PARTY.md).

## Run checks

```sh
bash Experiments/WikiRetrieval/run_tests.sh
```

The Swift harness creates a small independent SQLite fixture. It tests body evidence,
multiple candidate articles, title phrases, unresolved subjects, follow-up context,
low scores, malformed model output and missing assets. It also checks all three input
arrays against Hugging Face tokenizer fixtures, including Unicode and truncation.
These tests do not claim that the learned model understands every question.

For real-corpus comparisons with the actual Core ML model:

```sh
swiftc -D DEBUG -O -module-cache-path /tmp/wonderbug-probe-modules \
  WonderBug/Services/WikiSearchService.swift WonderBug/Services/WikiPassageReranker.swift \
  WonderBug/Services/SafetyService.swift WonderBug/Services/DebugLog.swift \
  Experiments/WikiRetrieval/Probe.swift -o /tmp/wonderbug-wiki-probe
/tmp/wonderbug-wiki-probe WonderBug/Resources/simplewiki.db \
  WonderBug/Resources/WikiMiniLM.mlpackage WonderBug/Resources
```

Before promoting the experiment, label a held-out set for whether the selected passage
actually supports the requested fact, then evaluate the complete Qwen answers. Include
false premises, imaginary subjects, ambiguous titles, comparisons, pronoun follow-ups
and genuinely absent facts. Measure peak memory, cold/warm latency and battery cost on
the intended iPhone. Do not tune the threshold solely to the examples in the probe.
