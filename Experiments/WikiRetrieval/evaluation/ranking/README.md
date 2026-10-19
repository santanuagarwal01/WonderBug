# Retrieval, reranker adaptation and rejection experiment

These are offline research artifacts. No annotation, topic list or expected answer is read by
the app. Only the small `wiki-relevance-gate.json` operating point is bundled.

## Reproduce

1. Build the evaluator with `build_evaluator.py` and run `hybrid-passages` on development cases.
   The archived first trial used a 16/4 quota; it was rejected. The final approach merges
   overlapping, contiguous windows from the same source, preserves article diversity, and
   fills freed slots from body FTS. All paths use at most 20 MiniLM pairs.
2. Install `Experiments/WikiRetrieval/requirements.txt` in an isolated Python environment.
   Download the revision pinned in `export_reranker.py` to a local directory. Run:

   ```sh
   python Experiments/WikiRetrieval/train_reranker.py --source <checkpoint> \
     --data Experiments/WikiRetrieval/evaluation/ranking/train.jsonl \
     --splits Experiments/WikiRetrieval/evaluation/ranking/split.json --output <new-directory>
   ```

   There are 196 reviewed pairs: 166 fitting pairs on 18 question topics and training-only
   ambiguous/personal questions, plus 30 model-selection pairs on four other question topics.
   Gold passages are positive labels. Candidate labels were reviewed individually; absence of
   the gold sentence does NOT mean negative. Seven ambiguous/partial candidate labels were
   excluded. Candidate texts can mention other topics; this is question-topic separation,
   not complete separation of every entity mentioned in training text.

   Train all parameters of the same MiniLM with balanced binary cross entropy, learning rate
   1e-5, batch 8, seed 20261018, three epochs. Save every epoch; select by pair AUC, then balanced
   loss on model-selection topics. Baseline is eligible. Baseline won this pilot; none of the
   adapted checkpoints is bundled. This small pilot does not establish a ceiling for fine-tuning.
   `score_reranker.py` can replay fixed candidate sets through a local checkpoint.
   `export_reranker.py --source ... --parity-output ...` supports future approved checkpoints,
   with conversion parity validation. The new local-checkpoint export path was not exercised
   in this run because no adapted checkpoint qualified for deployment.
3. Run `calibrate_gate.py --reviews .../gate-reviews.jsonl --output <new-report.json>`.
   Forty cases on eight calibration topics plus unknown/ambiguous questions select a cutoff;
   forty other development cases provide a separate diagnostic check. The objective maximizes
   supported admissions at >=90% empirical precision while not exceeding the original cutoff's
   unsupported admissions. This is an experimental policy choice, not a correctness guarantee.
   `supported_rejected` means selected supporting passages rejected, not all answerable questions
   missed by retrieval. A score cannot recover an answer that is absent from the selected passage.
4. After freezing the pipeline, run `fresh-suite.jsonl` with `--splits fresh`. Its eight animal
   topics and eight unknown/ambiguous questions were not used for fitting, checkpoint selection
   or cutoff selection. They were written by the same evaluator after implementation, so are
   not an independent third-party benchmark. The original held-out set was already inspected
   in the previous experiment and is not presented as fresh validation here.

Raw runs are retained locally under `evaluation/runs/2026-10-19-ranking/`. `run-hashes.json`
identifies their contents. Model selection history/manifests, gate labels, fresh answer labels,
and compact results are tracked here. Model checkpoints used only for the rejected training
pilot are reproducible from the pinned source and are not included in the app.

## Limitations

Labels were reviewed by one assistant and primarily assess source support. The Wikipedia
snapshot contains factual errors and vandalism (including an absurd hippo IQ claim); following
such evidence does not guarantee truth. The app's source snapshot was not changed in this task.
The fresh animal set is small and cannot establish overall app accuracy. The original dev set
informed shortlist iteration, so its improvement is a development result, not independent proof.

Qwen parameters, prompt, generation settings and final overlap check were unchanged. The Mac
local runtime produced different text for two pairs with identical questions/evidence despite
zero temperature; answer differences cannot all be attributed causally to retrieval. The final
overlap gate still misses contradictions and accepts a repeated question as an answer.
