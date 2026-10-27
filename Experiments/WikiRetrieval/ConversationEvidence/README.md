# Conversation and evidence experiment — stages 1–3

This experiment tests whether supplying the intended complete question and retaining
source structure improves evidence retrieval. It does **not** implement a learned
conversation resolver, change Qwen, or claim improved generated-answer accuracy.

The frozen suite contains all 41 questions from the 20 October device session in their
original order and two session boundaries, plus 34 new questions in nine conversations.
The latter are assistant-authored evaluation cases, not an independent benchmark. They
were frozen before their retrieval results were inspected. No evaluation question,
rewrite, expected answer, or audit target is read by the iPhone application.

Read [RESULTS.md](RESULTS.md) for the plain-language findings and measured regressions.

## Controls

Run each question against each database using the app's actual Swift hybrid retrieval,
original MiniLM, threshold 4.0, and maximum 20 reranked candidates:

1. `baseline`: original question and existing stateful follow-up rules.
2. `unscoped-original`: original question, searched across articles without topic reuse.
3. `unscoped-resolved`: reviewed complete question, searched across articles.

The third arm is an **oracle experiment**. Its rewrites use intended conversation history,
including the expected previous answer where a question refers to that answer. A future
learned resolver can make mistakes; this arm does not measure its accuracy or latency.
Resolved questions are sent to both candidate retrieval and reranking. Safety checks are
retained, including blocked-topic continuation. Unknown personal facts are not manually
blocked by the experiment; their inappropriate admissions remain visible in the results.

## Corpus repair

`legacy_extractor.py` archives extraction functions from the user's original local Tools
repository for parity checks, without restoring that repository's deleted working files.
The archived source is Tools commit `2a2216a48e76ae6f345561d23f5a642ec2899eb2`, blob
`bb7e32fe2e90d42273a3641d95bd2bd9e110b9c2`; command-line entry points were removed.
`audit_corpus.py` reproduces the stored articles and traces omissions to the pinned dump.

`extract_evidence.py` preserves labelled infobox fields, lists (including concise indexes
of explicitly labelled entries), simple tables with column headers, and short prose.
These are markup-processing rules, not per-question answer rules. The same 4,000-character
body budget applies to every article; up to 1,200 characters are reserved for structured
evidence. Prose then takes priority over long catalogues. Complete blocks are kept or
omitted; sentences and numbers are not cut to hit the budget. Adjacent compatible short
blocks are packed to limit row/index overhead. Lead text and article/redirect membership
are preserved from the baseline database.

Unknown templates, numeric-only infobox values, and tables with merged cells are not interpreted. The
builder cannot guarantee complete Wikipedia coverage. It still excludes reference/link
sections and can omit late content under the fixed budget. It does not repair incorrect
claims already present in the source. Structured fields can contain facts blocked by the
app's safety policy; that existing runtime policy remains in force.

`build_corpus.py` writes a new independent database, validates SQLite/FTS integrity, and
records source/dump/output hashes and revision-level paragraph provenance. Paragraph
ordinals belong to a specific corpus version: do not compare source IDs across versions
without their database hash. It refuses existing outputs, symlinks and source overwrite.
`export_runtime.py` creates another validated copy without the large build-only provenance
table, preserving every passage byte-for-byte. The audit database is kept separately.

`compact_corpus.py` tests a smaller alternative without changing runtime code. It assigns
each article `max(600, min(4000, old_body_characters))`, then selects a global scale in
0.05 increments so retained whole paragraphs fit at most 90% of the old total body
characters. The 10% margin leaves room for short-row index overhead. This selects scale
0.60 for this corpus. Size alone determines the scale; no evaluation results are read.
It preserves paragraph text and original ordinals, rebuilding FTS after pruning. This can
remove facts and adjacent context, so it is an experimental comparison, not a shipping policy.

## Reproduce

From this directory, create a Python environment and install `requirements.txt`. This is
a build-time parser dependency, not an iPhone dependency. Set paths explicitly:

```sh
python -m unittest test_extraction test_protocol test_summary test_compaction -v
python build_probe.py --repo /path/to/experimental/WonderBug --output /tmp/conversation-build
python audit_corpus.py --baseline /path/to/baseline.db --dump /path/to/simplewiki.xml --output /path/to/new-audit.json
python build_corpus.py --source /path/to/baseline.db --dump /path/to/simplewiki.xml --output /path/to/new-structured.db
python export_runtime.py /path/to/new-structured.db /path/to/new-runtime.db
python compact_corpus.py --source /path/to/new-runtime.db --baseline /path/to/baseline.db --output /path/to/new-compact.db
python run_comparison.py --binary /tmp/conversation-build/conversation-eval --database /path/to/baseline.db --reranker /path/to/WikiMiniLM.mlpackage --resources /path/to/Resources --suite suite.jsonl --output /path/to/baseline-run.jsonl --corpus-label baseline
python run_comparison.py --binary /tmp/conversation-build/conversation-eval --database /path/to/new-runtime.db --reranker /path/to/WikiMiniLM.mlpackage --resources /path/to/Resources --suite suite.jsonl --output /path/to/structured-run.jsonl --corpus-label structured
```

Use a new output name for every run. Core ML may require permission to compile its model
in the system temporary directory. Raw traces stay local. Results distinguish passage
admission from whether it contains a sufficient answer; the latter requires evidence
review. Matching a topic or a few words is not proof of factual support.

## Review and reproduce the summary

Run the compact database through `run_comparison.py` as above with `--corpus-label compact`.
Keep labels `baseline`, `structured` and `compact` when using the checked-in reviews.
The three `*-support-reviews.jsonl` files bind every admitted output to its exact passage
hash. New or changed evidence requires a new review; do not copy a score based on title.

```sh
python summarize.py --suite suite.jsonl --runs /path/to/baseline-run.jsonl /path/to/structured-run.jsonl /path/to/compact-run.jsonl --reviews baseline-support-reviews.jsonl structured-support-reviews.jsonl compact-support-reviews.jsonl --output /path/to/new-results.json
```

The complete measured summary is `results.json`. `source-quality-flags.json` separately
records selected passages with obvious source contamination encountered during review.
This is not an exhaustive fact check. Core-answer support is deliberately distinct from
source reliability and generated-answer correctness.

The small source audits and build/run manifests are versioned here. Large databases and
raw traces remain in the local output directory named in `RESULTS.md`; they are not app
resources. The initial `baseline-corpus.jsonl` run was interrupted by a Core ML sandbox
restriction and is not included in any metric. The completed `baseline-corpus-run.jsonl`
is the one used. Rebuilds may produce different SQLite bytes across library versions;
compare content and run new reviews when passage text changes.
