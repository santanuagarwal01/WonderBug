# Test the two retrieval versions on iPhone

Open `/Users/santa/.codex/worktrees/wiki-reranking/WonderBug/WonderBug.xcodeproj`, select your connected iPhone, choose a scheme, and press Run. Use the experimental worktree project, not the project on master.

| Scheme | Installed name | What it runs |
| --- | --- | --- |
| `HybridPassageExperiment` | Wonder Bug | Earlier combined article/body retrieval, existing MiniLM, original 4.0 cutoff and original corpus |
| `SQLiteVecExperiment` | Wonder Bug Vec | Compact corpus + binary SQLite-vec neighbours + keyword rank fusion + the same MiniLM and cutoff |

The vector app uses bundle ID `com.santanu.wonderbug.vec`, so both can stay installed with separate conversations. It uses your existing signing team; Xcode may need to create the development provisioning profile for this new ID. Both debug builds retain their mode and local evaluation logging when opened from the home screen.

The three superseded app schemes were removed. Hybrid was retained because its fresh-set evidence coverage was strongest among the earlier configurations; changing its cutoff did not improve the fresh-set decisions. Their last local XML versions were backed up under `output/vector-retrieval-2026-10-27/retired-schemes/` in the primary checkout. Automatic scheme creation is disabled so only the two explicit schemes appear.

## What this experiment does—and does not do

The vector scheme uses the measured **binary** variant. It is small enough for this phone trial, but it scored 49/66 versus 50/66 for the corrected keyword baseline in the offline complete-question evaluation. Full-precision vectors scored 52/66 and are not bundled. This is an experiment, not a promoted accuracy improvement.

It retrieves 48 binary neighbours and combines them with article/body keyword candidates using the frozen RRF policy. It prepares sources consistently, removes duplicate text, and sends at most 20 passages to the unchanged MiniLM. The gate remains 4.0; Qwen and its prompts are unchanged. All model and search work is local.

The first vector lookup verifies the bundled corpus/index/vocabulary hashes and loads the encoder. It will take longer than subsequent questions. Missing or incompatible assets produce an explicit trace error and refusal; the app does not silently fall back and label a keyword result as vector retrieval.

The app's existing follow-up detector still decides whether to reuse a topic. In the vector scheme, the topic is appended to both search queries, and the existing question/topic/previous-question format goes to MiniLM. Retrieval remains corpus-wide. This is **not a trained conversation resolver**, and it differs from Hybrid's article-restricted follow-up search. The manually completed offline questions are not automatically generated on the phone.

These two app schemes also use different corpora and shortlist policies, so a phone comparison tests the whole configurations. It does not isolate the effect of vectors alone; the three-arm offline benchmark serves that purpose.

## A useful first comparison

Start a new chat for each sequence and repeat the same wording in both apps:

1. “Who was Rosa Parks?” → “Who was her husband?” → separately, “Who was Rosa Parks's husband?”
2. “Who was Marie Curie?” → “Who was her husband?” Check for confusion with her daughter.
3. “What is Jupiter?” → “What is its temperature?” → separately, “What is the temperature on the planet Jupiter?” Check that evidence describes Jupiter itself.
4. “Why do stars twinkle?”
5. “What is the highest mountain in Africa?”
6. “What is an elephant's tusk?” Check whether the answer is complete.
7. “What colour is my backpack?” It should not invent personal information.

Record wrong answers separately from refusals and incomplete answers. Compare the first question's delay with later questions; also watch for app termination or sustained heating. The prior Mac results do not establish phone latency or memory use.

## Logs and reproducibility

Each app writes local JSONL sessions to `Documents/Evaluation/` in its own container. Download the container for the app you tested. Vector traces include mode/version, effective retrieval question, neighbour source IDs/distances, selected candidates and scores, gate, asset hashes, initialization/embedding/search timings, and any vector error. The console also prints a `VECTOR` section.

Large assets remain ignored by Git and are already installed locally. For another checkout, run `prepare_device_assets.py --help` with the previously generated compact corpus, binary index and Core ML package. The checked-in manifest binds the corpus and vectors together. The baseline configuration excludes the vector model/index/corpus; the vector configuration excludes the original corpus, avoiding two Wikipedia databases in one bundle.

The vendored SQLite-vec C source is version 0.1.6, statically linked to Apple's SQLite through the local `Packages/SQLiteVec` package. Its license and the encoder's Apache 2.0 license are bundled with the experiment. No downloaded native extension is loaded at runtime.

The native parity check can be reproduced with:

```sh
python3 Experiments/WikiRetrieval/VectorRetrieval/build_device_probe.py --repo . --output /tmp/native-vector-probe
python3 Experiments/WikiRetrieval/VectorRetrieval/check_device_parity.py --binary /tmp/native-vector-probe/device-probe --resources WonderBug/Resources --reference /path/to/comparison.jsonl --output /tmp/device-parity.json
```

An unsigned generic iPhone build validates compilation and packaging. It does not establish that a signed build has been installed or exercised on your physical iPhone.

## Validation recorded for this integration

Both unsigned generic iPhone builds passed. Bundle inspection confirms the expected mode,
logging settings and corpus/model inclusion for each configuration. The existing retrieval
regression suite passed. Native candidate text, decisions and selected passages matched
all 145 eligible offline binary-arm records; five empty-content questions short-circuit
without vector search. The follow-up vector route and missing/mismatched-asset refusals
also passed. See [device-validation.json](device-validation.json) and
[device-parity.json](device-parity.json). No physical iPhone run was performed here.
