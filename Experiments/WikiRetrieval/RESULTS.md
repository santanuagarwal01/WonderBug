# Initial experiment results — 2026-10-06

This is a development smoke comparison of 15 questions against the bundled database,
not a held-out accuracy benchmark. It ran the real Swift retrieval paths and quantized
Core ML reranker on this Mac. It did **not** run Qwen or certify final answer correctness.

## Size and latency

- Generated Core ML package: approximately 22 MiB (about 23 MB), plus a 226 KiB vocabulary.
  Compiled app size and peak runtime memory have not been measured on an iPhone.
- Source PyTorch versus quantized Core ML: maximum absolute logit difference about 0.12
  on seven conversion checks. Swift's token IDs, masks and segment IDs match all seven
  Hugging Face fixtures exactly.
- Warm reranker time: approximately 61–81 ms for 20 passages on this Mac.
- Whole warm lookup: approximately 104–752 ms in this small run; SQL work can dominate.
- First lookup: approximately 2.7 seconds, including lazy model loading.
- These are single-run observations, not statistical benchmarks or iPhone estimates.

## Build and regression checks

- Unsigned Debug build for a generic physical iOS destination: passed with the
  `WikiRetrievalExperiment` scheme. The compiled model and both original data assets
  are present in the built app bundle.
- Swift fixture regression checks: passed, including safe-window filtering and
  keeping the newest follow-up question first in the truncated model input.
- Seven tokenizer parity checks: passed.
- No physical iPhone run or final-answer evaluation has been performed.

## Evidence selection

| Question | Legacy | Experiment | Assessment |
|---|---|---|---|
| What do armadillos eat? | General introduction without diet | Nine-banded armadillo diet | Better evidence, but Qwen must preserve the species qualifier |
| What do koalas eat? | Diet in selected lead | Diet plus koala identity | Useful evidence retained |
| Can ostriches fly? | Relevant lead | Explicit flightlessness passage | Useful evidence retained |
| How many legs do spiders have? | Lead | Passage explicitly saying eight legs | Useful evidence retained |
| Do fish have lungs? | General Lung article | Lungfish passage describing the exception | Better evidence, but should not generalize to all fish |
| How do elephants communicate? | Unrelated elephant introduction | Abstains | Avoids answering from an irrelevant passage |
| What do flibberwumps eat? | Abstains | Abstains | Unknown-subject constraint retained |
| Why do we get goosebumps? | Book series | Correct physical-sensation article ranks first, but below cutoff | Candidate recall improves; still an unnecessary abstention |
| Why do stars twinkle? | Abstains | Nursery rhyme | Incorrect sense still ranks above cutoff |
| Why do cats purr? | Abstains | Perfume article ranks first, below cutoff | Still lacks useful retrieved evidence; abstains |
| Why do giraffes have long necks? | Abstains on lead coverage | Lamarckism article, including its warning that the hypothesis is wrong | Risky evidence: a small generator may repeat the discredited explanation |
| Is a whale a fish? | Mammal definition | Mammal definition plus unrelated diet paragraph | Identity retained, but relation ranking is still weak |
| Why do leaves change color? | Mentions chlorophyll and color | Similar partial evidence | Does not clearly establish the seasonal mechanism |
| Why do dogs wag their tails? | Abstains | Happy tail-wagging in one dog breed | Partial evidence, not a general causal explanation |
| What is a volcano? | Relevant definition | Relevant definition | Useful evidence retained |

## Interpretation

The new candidate stage does expose previously hidden body evidence. The model is small
and inexpensive enough on this Mac to justify further evaluation. However, this MS MARCO
reranker sometimes rewards topical wording without resolving the question's sense,
causality or the reliability of the claim inside a passage. Raising one score threshold
cannot fix all three: it also rejects valid passages such as Goose bumps.

Keep the experiment opt-in. The next decision should be based on labeled held-out
retrieval and complete-answer results, not a lower abstention count. Candidate recall
needs improvement when the correct article has no title/lead lexical match; direct
paragraph indexing is one possible follow-up. Model choice or domain adaptation is a
separate question from that recall limitation.
