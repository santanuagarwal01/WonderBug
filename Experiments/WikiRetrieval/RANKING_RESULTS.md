# What changed, and what actually improved

October 19, 2026 — experimental branch `codex/wiki-passage-reranking`.

**Candidate selection improved modestly. The small reranker training trial did not improve
its reserved comparison set. Changing the cutoff did not improve the separate validation or
fresh test. Qwen still makes mistakes with correct evidence.**

## 1. Candidate selection: implemented

The new search combines article search with direct paragraph search. It merges overlapping
excerpts from the same source into contiguous text, keeps several articles represented, and
uses freed slots for body-search results. It still scores at most **20 passages**, using the
same MiniLM model and 256-token inputs. There are no new topic-specific rules or synonym lists;
the hybrid modes do not use the older handwritten synonym expansion.

| Evidence diagnostic | Earlier article experiment | Direct paragraph experiment | New combined search |
|---|---:|---:|---:|
| Supporting sentence reaches reranker, development | 121/152 | 108/152 | **126/152** |
| Supporting sentence selected and accepted, development | 77/152 | 73/152 | **80/152** |
| Supporting sentence reaches reranker, fresh questions | 28/32 | 27/32 | **29/32** |
| Supporting sentence selected and accepted, fresh questions | 23/32 | 21/32 | **25/32** |

These count exact annotated sentences, not every valid alternative answer. Development results
informed the shortlist design. The fresh set was frozen after implementation: 32 source-backed
questions across eight additional animal topics, plus eight unknown/ambiguous questions.

## 2. Reranker: evaluated and trained, original retained

I trained the existing MiniLM architecture locally for three epochs on **166 reviewed pairs**.
Another **30 pairs on four reserved question topics** selected the checkpoint. Training labels
included both useful alternative sources and misleading related passages. Missing an annotated
sentence was never automatically treated as proof that a candidate was wrong.

The original model scored **0.894** on the reserved pair-ranking metric (AUC); the three adapted
checkpoints scored **0.885, 0.885 and 0.875**. The original won the predeclared selection rule.
**No trained weights were installed.** This is a small adaptation pilot, not evidence that a
larger, better training set cannot help. Training scripts, labels, splits and results are saved.

## 3. Gate: calibrated, available separately, not promoted

The original cutoff was 4.0. A labelled 40-case calibration group selected **3.798828125**:
it admitted 27 supported and two unsupported passages, compared with 25 supported and two
unsupported at 4.0. The selection required at least 90% observed support precision and no more
unsupported admissions than the original cutoff.

On a separate 40-case development validation group, **both thresholds admitted 25 supported
and seven unsupported passages**. On the 40 fresh questions, the two thresholds made identical
decisions. The calibration benefit did not generalize in these checks. High-scoring wrong
passages remain: relevance is not a reliable answerability test.

The fitted setting is an explicit comparison option. It is checked against the retrieval
version and model identity; missing or incompatible calibration fails with a logged reason.
It is not a probability of correctness. The normal/default app behavior is unchanged.

## Answers with unchanged Qwen

Every generated answer in the fresh run was reviewed. Among the 32 source-backed questions:

| Displayed answer assessment | Earlier article experiment | New search + fitted cutoff |
|---|---:|---:|
| Correct and supported | 19 | 21 |
| Incorrect | 4 | 4 |
| Unsupported additions/transfer | 3 | 1 |
| Repeated question instead of answer | 1 | 1 |
| No displayed answer | 5 | 5 |

Both refused all eight additional unknown/ambiguous questions. The new run still says
**earthworms have legs** and **snails have backbones**, even though its passages say otherwise.
The final overlap check accepts these contradictions. It also accepts a repeated question.

Do not treat the two-answer difference as a proven accuracy gain: this is a small, single-reviewer
sample, and two identical question/evidence pairs produced different wording despite greedy
settings in the local Mac runtime. One changed whether the overlap gate accepted the answer.
The source snapshot itself also contains inaccurate/vandalized claims; source support is not
an independent factuality guarantee.

## Try it and verify

- **HybridPassageExperiment:** candidate repair with original model and original cutoff.
- **CalibratedPassageExperiment:** same repair/model, fitted experimental cutoff.
- Existing schemes and `master` remain intact. Qwen training remains deferred.

No extra model, embedding index or database storage was added in this task. The only new data
resource is a small gate JSON file. Mac retrieval medians were about **240 ms** for combined
search versus **187 ms** for the earlier article experiment on the fresh run. These are local
measurements, not iPhone performance guarantees. Phone memory/battery testing remains outstanding.
Only one of 3,540 development reranker inputs exceeded the tokenizer budget; none of the 780
fresh hybrid inputs did. Exact-span metrics inspect presented text rather than truncated tokens.

See [protocol and reproduction](evaluation/ranking/README.md), [fresh results](evaluation/ranking/fresh-results.json),
and [gate calibration](evaluation/ranking/gate-calibration.json). Raw logs remain local under
`evaluation/runs/2026-10-19-ranking/`. No annotations are used as runtime rules.

Validation: Swift retrieval/tokenizer/failure-path checks, Python calibration/split/provenance checks,
and the unsigned generic iOS build passed. The earlier experiment matched its previous binary
on all 40 fresh cases for selected passage, title, decision and rejection reason.
