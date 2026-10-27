# SQLite-vec + BM25 retrieval experiment

Completed results: see [RESULTS.md](RESULTS.md). Full precision improves sufficient
evidence from 50/66 to 52/66 with completed questions; binary vectors fall to 49/66.
The experiment has not been promoted to the app.

This is a functioning offline comparison using the app's Swift passage preparation,
safety checks and existing MiniLM cross-encoder, plus a small Core ML sentence encoder.
It does not yet add a vector scheme to the iPhone app or change its default behaviour.
Qwen generation and learned conversation resolution are not part of this comparison.

## Fixed comparison

The 75-case conversation suite and compact 608,614-passage corpus from
`../ConversationEvidence` are held fixed. `protocol.json` records the parameters before
vector retrieval results are inspected. Each original and reviewed complete question is
run through three arms (450 records total):

- `bm25-fusion`: article and passage keyword-search rankings are merged by reciprocal
  rank fusion (RRF), instead of allocating article candidates first and filling leftovers.
- `vec-float-fusion`: the same lexical ranking plus 48 full-precision cosine neighbours
  from SQLite-vec, combined by RRF.
- `vec-binary-fusion`: the same lexical ranking plus 48 binary/Hamming neighbours from
  SQLite-vec. It does not secretly rescore with full vectors.

RRF uses k=60, with one lexical and one dense vote in the vector arms. Overlapping windows
cannot multiply a source's vote. Identical normalized final text is also deduplicated
within each arm before filling the 20 slots. All arms render the same source through the same Swift
passage preparation and safety policy. The highest word-overlap window for each source
is used; complete short paragraphs are preserved. There are at most 20 reranked passages
and the gate remains 4.0. Fusion can still discard relevant sources; it is not a guarantee.

The keyword arm includes both a fusion change and canonical passage preparation, compared
with the historical app. Only the comparison *between these three arms* isolates vectors.
Original questions search without topic reuse. Reviewed complete questions are an oracle
control, sometimes using an expected prior answer, not an implemented conversation model.

## Embeddings and SQLite-vec

The encoder is `sentence-transformers/all-MiniLM-L6-v2`, revision
`1110a243fdf4706b3f48f1d95db1a4f5529b4d41`: 384 dimensions, a 256-token limit,
attention-masked mean pooling and L2 normalization. These are separate weights from the
existing MiniLM cross-encoder. Documents include title, optional section, then paragraph.
The whole corpus is embedded independently of evaluation questions or expected answers.

`build_index.py` uses SQLite-vec 0.1.6 to store float and sign-quantized binary vectors.
Batches commit both representations and a resume checkpoint together. Resuming requires
matching corpus, model and tokenizer identities. Evaluation refuses incomplete indexes.
`export_index.py` removes the unused representation into a separate file and checks every
retained vector's bytes and ID. Vector IDs are meaningful only with the recorded corpus hash.

`export_embedder.py` creates an iOS 17+ Core ML model with int8-compressed weights and
float16 computation. Compression describes weight storage, not an all-integer compute
pipeline. The benchmark embeds queries using Swift/Core ML, while corpus embeddings use
the pinned original encoder. Conversion and Swift tokenizer parity are tested explicitly.
The raw PyTorch weights and float reference index are research artifacts, not proposed
shipping assets. On-device integration still needs native SQLite-vec linkage and device tests.

## Reproduce

Create a Python 3.12 environment and install `requirements.txt`. `environment.lock.txt`
records the installed transitive versions. Keep model downloads, indexes and raw traces
outside the app resources and outside Git. Use new output paths; a partial index can resume.

```sh
python download_model.py --output /path/to/encoder
python build_index.py --corpus /path/to/compact-runtime.db --model /path/to/encoder --output /path/to/vectors-reference.db --device mps
python export_index.py /path/to/vectors-reference.db /path/to/vectors-binary.db --kind binary
python export_embedder.py --model /path/to/encoder --output /path/to/coreml-embedder
python build_probe.py --repo /path/to/WonderBug --output /tmp/vector-build
python -m unittest test_vector_retrieval test_review_results -v
```

`build_probe.py` instruments only copies of the service/tokenizer in the build directory.
It never edits app source files. The bridge uses the actual Core ML reranker and safety
implementation. `smoke_bridge.py --help` gives the arguments for Swift tokenizer parity,
embedding parity, safety and 20-candidate budget checks.

```sh
python run_comparison.py --binary /tmp/vector-build/vector-eval --corpus /path/to/compact-runtime.db --reranker /path/to/WikiMiniLM.mlpackage --vocabulary /path/to/wiki-minilm-vocab.txt --model /path/to/encoder --coreml-embedder /path/to/coreml-embedder/WikiEmbedder.mlpackage --embedding-vocabulary /path/to/coreml-embedder/wiki-embedder-vocab.txt --float-index /path/to/vectors-reference.db --binary-index /path/to/vectors-binary.db --suite ../ConversationEvidence/suite.jsonl --protocol protocol.json --output /path/to/run.jsonl
python review_results.py queue --suite ../ConversationEvidence/suite.jsonl --run /path/to/run.jsonl --protocol protocol.json --previous-reviews ../ConversationEvidence/baseline-support-reviews.jsonl ../ConversationEvidence/structured-support-reviews.jsonl ../ConversationEvidence/compact-support-reviews.jsonl --output /path/to/review-queue.json
```

Review every previously unseen admitted passage against the intended question. Fill its
`review` with `support` (`sufficient`, `partial`, `absent`, or `ambiguous`) and an explanatory
`note`. A topic/title match alone does not establish support. Keep the hash-bound text intact.

```sh
python review_results.py summarize --suite ../ConversationEvidence/suite.jsonl --run /path/to/run.jsonl --protocol protocol.json --reviews /path/to/reviewed.json --output /path/to/results.json
```

This measures selected evidence support, not generated-answer accuracy. The earlier corpus
contains known bad and dated source claims. No retrieval method repairs those automatically.
The suite has already been used in earlier work; this is not a fresh independent benchmark.
Query component timings are Mac measurements, with shared preparation and warmed models;
they must not be reported as iPhone end-to-end latency or battery cost.

Model and library references:
- https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2
- https://alexgarcia.xyz/sqlite-vec/python.html
- https://alexgarcia.xyz/sqlite-vec/guides/binary-quant.html
- https://www.sbert.net/examples/sentence_transformer/applications/retrieve_rerank/README.html
