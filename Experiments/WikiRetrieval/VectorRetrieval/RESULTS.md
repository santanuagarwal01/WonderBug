# SQLite-vec experiment: results

The hybrid retrieval experiment is implemented and tested. Full-precision vectors give a small gain; the lightweight binary version does not beat the corrected keyword baseline. Neither is ready to become the app default on this evidence.

This work lives on `codex/wiki-passage-reranking`. It is an offline experiment using the real Swift passage preparation, safety checks and MiniLM reranker. It does **not** add a vector Xcode scheme or change the running iPhone app. Qwen generation and training are not included.

## What changed

The experiment embeds all 608,614 passages with a separate small sentence encoder, stores the vectors in SQLite-vec, retrieves semantic neighbours alongside keyword matches, merges their rankings, and lets the existing MiniLM score at most 20 passages. The gate remains 4.0. No question-specific retrieval rules were added.

Three configurations use the same corpus, passage preparation, reranker and budget. The keyword baseline also fixes article-first candidate allocation by merging article and body rankings. Therefore gains over the historical app cannot all be attributed to vectors; the comparison between these three configurations isolates their contribution.

## Results

These numbers count questions whose **selected passage contains sufficient evidence**. They are not generated-answer accuracy or proof that dated source claims are currently correct.

| Question input | Keyword fusion | + full-precision vectors | + binary vectors |
| --- | ---: | ---: | ---: |
| Original wording, without conversation resolution | 30/66 | 32/66 | 30/66 |
| Manually completed questions with the intended person/topic | 50/66 | 52/66 | 49/66 |

The complete-question condition is an oracle control: a person supplied the missing context, sometimes using the expected previous answer. It does not demonstrate an implemented conversation resolver. The original-wording condition does not reuse the app's existing session topic, so it should not be presented as current app accuracy either.

Full-precision vectors recover sufficient evidence for the largest planet, why stars twinkle, and Africa's highest mountain. They also replace a sufficient elephant-tusk passage with an incomplete one: three gains and one regression, a net gain of two.

Binary vectors recover Africa's highest mountain, but lose the elephant-tusk result and Rosa Parks's husband in the completed-question condition. Their smaller footprint comes with a measurable retrieval tradeoff in this configuration.

## What the failures tell us

**Rosa Parks now succeeds with keyword fusion alone.** The relevant source is present at rank 14 in the prepared body-search pool and rank 15 in the full-precision neighbour list. It survives preparation and reaches MiniLM in both configurations. It is absent from the first 48 binary neighbours; merging that list pushes the keyword hit outside the 20-passage budget. Binary retrieval rejects the question. This is candidate loss before reranking, not a stricter gate. These ranks refer to this compact corpus and stage, not the earlier structured-corpus SQL diagnostic.

**The reranker still confuses related entities.** All three configurations select Irène Joliot-Curie's husband passage for Marie Curie's husband (score 7.496, above the 4.0 gate). All three select the temperature of TrES-4b for Jupiter's temperature (score 5.625). Adding semantic candidates does not make a relevance score a reliable check that a fact belongs to the requested person or planet. Raising a single threshold is not a demonstrated solution.

**Vectors do not resolve conversation references.** Among ten device follow-ups, original wording succeeds on only one in every configuration. Supplying the intended context raises this to nine for keyword/full-precision and eight for binary. The missing conversation interpretation remains a separate problem. In two new unresolved follow-ups, binary retrieval additionally admits unrelated passages about steel and the film *The Founder*.

**Source completeness and quality remain constraints.** Some selected passages identify the topic but omit the requested fact. Dated counts and inaccurate source statements also require separate handling; a retrieval score cannot establish current factual truth. For example, Jupiter's moon-count evidence is explicitly dated April 2025. This evaluation credits its source support, not its currency today.

## Size and speed

| Asset | Measured size |
| --- | ---: |
| Binary vector index, all passages | 41.7 MiB |
| Core ML sentence encoder | 21.7 MiB |
| Encoder + binary index + vocabulary | 63.6 MiB |
| Compact corpus + these assets | 364.9 MiB |

Using the compact corpus offsets part of the addition: this total is 47.7 MiB (about 15%) larger than the original 317.2 MiB corpus. These are prepared asset sizes; native SQLite-vec linkage and compiled iPhone packaging overhead have not been measured. Existing Qwen and reranker assets are unchanged and excluded from both sides.

Median vector search on the Mac is approximately 402 ms for full precision and 29 ms for binary. Query embedding is approximately 5–8 ms. These are component timings with warmed models, not iPhone end-to-end latency. Shared passage preparation also means component medians cannot simply be added to compare complete pipelines. The 948.9 MiB research index contains **both** vector formats and is not a measured float-only shipping asset.

## Verification and limits

- All 608,614 passages were indexed independently of evaluation questions. The binary export was checked byte-for-byte against the reference vectors and IDs.
- Eleven unit tests passed, along with Swift/Core ML embedding and tokenizer parity, safety/budget checks, and a preparation-isolation test for identical text under different source IDs.
- All 450 runs completed: 75 cases × two input modes × three configurations. Every admitted result was reviewed: 357 admissions map to 93 distinct question/passage pairs; 35 reused exact prior reviews and 58 received new reviews.
- Sixty-six cases are answerable; nine controls/exclusions are reported separately. The standalone ambiguous “What is Saturn?” case is excluded consistently. Unknown personal facts still sometimes receive irrelevant evidence.
- The suite includes 41 device questions and 34 additional cases. It was inspected in previous work and is not a fresh independent holdout. Labels reflect manual evidence review, not independent blinded adjudication.
- The implementation and protocol were frozen before inspecting the comparison output. Corpus, model, tokenizer, binary and trace hashes are recorded. No Qwen answers were generated, and no device performance or battery measurements were taken.

## Recommendation

Keep the experiment available, but do not promote the binary configuration or ship the large reference index. SQLite-vec works as the vector search component; it does not solve the whole answer-selection problem.

The next bounded experiment should test whether a less aggressive vector representation or a larger binary candidate pool can preserve useful semantic hits without displacing strong keyword evidence, while keeping the same final reranking budget. Evaluate on fresh questions before choosing a configuration. Separately, the wrong-person/wrong-planet examples justify training or calibrating the existing reranker on hard entity and relation negatives, and evaluating a learned conversation resolver. These are proposed next steps, not changes implemented here.

## Files

- [Reproduction instructions](README.md)
- [Frozen protocol](protocol.json)
- [Machine-readable results and per-case reviews](results.json)
- [Hash-bound passage review records](support-reviews.json)
- [Run manifest](comparison.manifest.json)
- [Candidate-loss diagnostics](failure-diagnostics.json)
- [Implementation hashes](implementation-manifest.json)

Large local artifacts, including the raw 450-record trace, indexes and encoder, remain outside Git at `/Users/santa/iOS Projects/WonderBug/output/vector-retrieval-2026-10-27/`.
