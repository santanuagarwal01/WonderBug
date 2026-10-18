# Evaluation results

Exact source/span coverage is a conservative retrieval diagnostic. It can miss valid alternative evidence and is not factual answer accuracy.
Answer correctness requires a separate review. Source support alone does not establish that Wikipedia itself is correct.

| Mode | Cases | Selected gold-span coverage | Supported cases without an answer | Median retrieval |
|---|---:|---:|---:|---:|
| direct-passages | 236 | 80/172 | 34/172 | 266.4 ms |
| gold | 172 | —/— | 10/172 | — ms |
| legacy | 236 | 65/172 | 70/172 | 68.6 ms |
| passages | 236 | 85/172 | 25/172 | 260.3 ms |

## Answer review

Counts below include only explicitly reviewed cases. Unreviewed generated answers remain unclassified.

| Mode | Reviewed generated cases | Displayed-answer assessments | Unreviewed generated answers |
|---|---:|---|---:|
| direct-passages | 168 | {"correct": 119, "incorrect": 26, "partial": 14, "unsupported": 3, "nonanswer": 2} | 0 |
| gold | 168 | {"correct": 140, "incorrect": 15, "unsupported": 4, "partial": 2, "nonanswer": 1} | 0 |
| legacy | 30 | {"correct": 19, "incorrect": 4, "partial": 6, "nonanswer": 1} | 97 |
| passages | 51 | {"correct": 42, "incorrect": 4, "partial": 4, "nonanswer": 1} | 125 |
