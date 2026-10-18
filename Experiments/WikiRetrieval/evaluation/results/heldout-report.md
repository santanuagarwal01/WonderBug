# Evaluation results

Exact source/span coverage is a conservative retrieval diagnostic. It can miss valid alternative evidence and is not factual answer accuracy.
Answer correctness requires a separate review. Source support alone does not establish that Wikipedia itself is correct.

| Mode | Cases | Selected gold-span coverage | Supported cases without an answer | Median retrieval |
|---|---:|---:|---:|---:|
| direct-passages | 64 | 21/48 | 7/48 | 257.2 ms |
| gold | 48 | —/— | 1/48 | — ms |
| legacy | 64 | 16/48 | 22/48 | 71.6 ms |
| passages | 64 | 25/48 | 3/48 | 328.0 ms |

## Answer review

Counts below include only explicitly reviewed cases. Unreviewed generated answers remain unclassified.

| Mode | Reviewed generated cases | Displayed-answer assessments | Unreviewed generated answers |
|---|---:|---|---:|
| direct-passages | 47 | {"correct": 33, "partial": 2, "unsupported": 3, "incorrect": 6, "nonanswer": 2} | 0 |
| gold | 48 | {"correct": 43, "incorrect": 2, "partial": 1, "unsupported": 1} | 0 |
| legacy | 30 | {"correct": 24, "incorrect": 3, "partial": 1, "unsupported": 1, "nonanswer": 1} | 0 |
| passages | 51 | {"correct": 41, "incorrect": 4, "partial": 3, "unsupported": 2, "nonanswer": 1} | 0 |
