# What stages 1–3 showed

**The strongest measured improvement comes from giving search the complete intended question. Repairing the database helps some missing facts, but it does not reliably make the app choose the right evidence. Neither rebuilt database is ready to ship.**

This work is an offline experiment on `codex/wiki-passage-reranking`. The iPhone app, bundled database, MiniLM reranker, gate and Qwen are unchanged. Running the existing Xcode scheme will still run the existing app behaviour.

## The comparison

We replayed all 41 questions from the 20 October device session, preserving their order and two session boundaries, plus 34 new questions. All 41 baseline selected passages matched the device logs exactly. The new questions were frozen before their results were inspected.

Each of the 75 questions ran through three retrieval paths on three databases: **675 lookups**. Every admitted passage received a text-hash-bound support review: **518 reviewed outputs**. The table counts passages containing enough information for the core answer. It does **not** measure Qwen's generated-answer accuracy or certify every statement in Wikipedia.

| Database | Size | Current conversation handling | Original question, unrestricted search | Reviewed complete question, unrestricted search |
|---|---:|---:|---:|---:|
| Current | 317.2 MiB | 36/66 | 32/66 | **50/66** |
| Full rebuilt evidence | 497.1 MiB | 39/66 | 33/66 | **50/66** |
| Compact rebuilt evidence | 301.3 MiB | 37/66 | 32/66 | **50/66** |

The denominator is 66 answerable cases. Personal unknowns, policy controls, orphan follow-ups and one underspecified “What is Saturn?” question are reported separately. That standalone question permits mythology or planet; it was excluded consistently for every configuration.

The reviewed complete questions were written for this evaluation. For example, “Who was her husband?” became “Who was Rosa Parks’s husband?” **There is no learned resolver in the app yet.** These results show its potential, assuming it resolves the conversation correctly. Simply removing the article restriction made results worse: 36/66 fell to 32/66.

For the 10 device follow-ups, sufficient evidence rose from **2/10 to 6/10** with complete questions on the current database, and to **8/10** with complete questions on the compact database. On 16 new follow-ups, the corresponding results were **6/16, 13/16 and 12/16**. The improvement on familiar cases did not eliminate regressions on new ones.

## What is actually failing

1. **Search loses the meaning of follow-ups.** Supplying the intended subject helps questions about elephant trunks, Jupiter's location, and other pronoun/correction cases. The existing manual follow-up rules remain in place; no new topic-specific answer rules were added.
2. **The old extraction discarded real facts.** We recovered the original builder from local Git history and reproduced four audited articles exactly. Rosa Parks's spouse was inside an infobox; Moon-phase names and planet facts were in lists. Those structures were discarded. This is confirmed extraction loss, not something Qwen could reliably fix.
3. **Available evidence can still be dropped before the reranker.** Both rebuilt databases contain “spouse: Raymond Parks”. The unrestricted search trace retrieves it, but the final 20 candidates contain no Raymond Parks passage. Lowering the final gate cannot recover a passage the reranker never saw.
4. **The reranker can prefer a related but wrong answer.** On the full rebuild, the Marie Curie husband question selects her daughter's marriage, scoring 8.74 against 8.43 for a Marie Curie candidate. Jupiter's temperature selects another planet at 5.63; “hot or cold” selects the Hot Jupiter exoplanet category. These pass the unchanged 4.0 gate. A relevance score is not proof that the passage answers the right relationship about the right entity.
5. **Some source text is itself unreliable.** The compact run selected a hippo passage containing the corrupt claim “IQ of 670.245”. That text was already in the original lead, which this experiment preserved. Selected Jupiter passages also contain a false Galileo-discovery claim. A correctly grounded answer can still repeat a bad source. These findings are separately flagged; the support totals above must not be presented as factual accuracy.

The gate is therefore only part of the problem. Correct evidence can be missing, excluded from the candidate set, or outranked by misleading evidence. Lowering a threshold alone is not a sound fix.

## What the database experiment gained and lost

The full rebuild restores labelled infobox fields, lists, simple tables and short prose using general markup parsing. It adds no runtime model or SQLite extension. Its 497.1 MiB runtime database is about 57% larger than the current database, even after removing build-only audit metadata.

The compact variant uses a corpus-wide storage budget, selected without reading evaluation questions or scores. It is about **5% smaller** than the current database. It retains the spouse fact and complete Moon-phase names, but drops the largest-planet list entry from the audited List of planets article. Coverage is still incomplete.

With reviewed complete questions, the full rebuild fixes Moon-phase names but regresses Marie Curie's husband. The compact rebuild additionally helps snake examples and Mercury's moon question, while regressing “Largest planet” and Venus's moon question. All three databases end at 50/66 sufficient passages; the individual successes differ. No rebuilt database was promoted into the app.

## What should happen next

The evidence supports a learned conversation-resolution step that produces a complete search question, followed by a candidate-selection change that preserves relevant evidence within the existing inference budget. It also supports training/evaluating the existing Qwen on whether the selected evidence actually answers that question, including wrong-person, incomplete-list and unknown-personal-fact examples. These are next-stage recommendations, **not implemented or trained here**. Training cannot restore facts that never reach the model.

SQLite-vec could later help retrieve semantically related wording such as “husband” and “spouse”. This experiment did not test vectors, and vectors would not by themselves resolve a pronoun, prevent candidate-pool exclusion, establish the correct relationship, or clean a corrupt source. The measured priorities are conversation resolution and evidence selection/answerability.

## Validation and limits

All 18 experiment tests pass. The existing retrieval regression suite also passed. SQLite and FTS integrity checks passed; the runtime export verified every passage against its audit copy. Each benchmark validated all 75 × 3 case/arm pairs, source/model hashes, and the maximum 20 reranked candidates.

The model, vocabulary, retrieval mode and 4.0 gate were held fixed. Mac lookup timings and memory are recorded in `results.json`, but are not iPhone performance measurements. The compact run's median complete-question lookup was 227 ms versus 272 ms for the current corpus; run order, cache and background activity were uncontrolled, so this is not a speedup claim. Resolver and Qwen-generation costs were not measured.

The new conversations are small and assistant-authored. Reviews were done by one assistant, not blinded or independently adjudicated. Oracle rewrites use intended history and sometimes an expected previous answer, so they do not measure recovery from the app's own wrong answer. Source-support reviews do not certify dated moon counts, mountain measurements or every ancillary claim.

Safety behaviour remains visible: the existing bare-follow-up check does not recognise “How do I do that?” after a blocked question. This test still refused retrieval; it did not produce an unsafe answer. Resolving the follow-up to its original subject made the existing question safety check block it. Unknown-personal-fact admissions, including the breakfast question, remain failures.

Correction to the earlier session analysis: the selected Jupiter-moons passage in the baseline run is a list introduction, not a list containing the four familiar moon names. Its evidence is graded absent here.

Machine-readable results, passage reviews, source checks and manifests are beside this report. Large local databases and raw traces are in `/Users/santa/iOS Projects/WonderBug/output/conversation-evidence-2026-10-27/`.
