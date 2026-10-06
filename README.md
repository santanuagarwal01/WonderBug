# WonderBug 🐞

This branch includes an opt-in [Wikipedia passage reranking experiment](Experiments/WikiRetrieval/README.md). Choose the **WikiRetrievalExperiment** Xcode scheme to try it; the normal scheme keeps legacy retrieval.

An offline "encyclopedia for kids" iOS app. A child (ages ~4–8) types a question — *Why do stars twinkle? What do armadillos eat?* — and gets a short, safe, simple answer generated **entirely on-device** by a small language model, answering only from a bundled offline copy of Simple English Wikipedia (252 MB, searched locally). No internet connection is ever needed (or used) to ask and answer questions.

Key product rules (from the project spec):

- Answers are 2–3 short, factual, positive sentences a young child can understand.
- A rule-based **safety gate** blocks inappropriate topics *before* the model ever sees them, rejects any Wikipedia passage that trips it, and checks every generated answer the same way before it is shown — always replying with the exact same fixed sentence: *"I'm not sure about that — let's ask your grown-up!"* — no variation, no explanation.
- This is **not a chatbot**: it never asks questions back, never suggests topics, never plays a friend/authority role.
- Every question and answer is logged so parents can review it, with blocked questions flagged for quick scanning.

---

## 1. Requirements

| What | Version |
|---|---|
| Xcode | 16+ (project uses file-system-synchronized groups) |
| iOS deployment target | 17.6 |
| Test device | **A physical iPhone.** The LLM runs via Apple's MLX framework, which does not work in the iOS Simulator (no proper Metal/GPU support). The Simulator is fine for UI/history/safety-gate work — anything that doesn't invoke the model. |
| Disk | ~1GB for the bundled model |

## 2. Setup, step by step

1. **Clone / open the project** — open `WonderBug.xcodeproj` in Xcode.

2. **Get the model weights** (not committed to git — they're ~940MB):
   - Download every file from [`mlx-community/Qwen3-1.7B-4bit`](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit) (Hugging Face → *Files and versions* tab) into a folder named `Qwen3-1.7B-4bit` placed **in the repo root** (next to `WonderBug.xcodeproj`).
   - Expected contents: `model.safetensors`, `config.json`, `tokenizer.json`, `tokenizer_config.json`, `vocab.json`, `merges.txt`, `special_tokens_map.json`, `added_tokens.json`, `model.safetensors.index.json`.
   - The Xcode project already references this folder as a synchronized group, so no Xcode steps are needed once the folder exists with the right name.

3. **Get the Wikipedia index** (not committed to git — it's 252 MB, over GitHub's 100 MB file limit): place `simplewiki.db` at `WonderBug/Resources/simplewiki.db`. It is built from a Simple English Wikipedia dump by the evaluation tools, which are kept outside this repository. Without it the app still builds and runs, but every question gets "I don't know yet".

4. **Swift Package dependencies** resolve automatically on first open. What's there and why:
   - [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) — products **MLXLLM**, **MLXLMCommon**, **MLXHuggingFace**. Runs the LLM on-device. `MLXHuggingFace` is needed even for local-only loading: it provides the `#huggingFaceTokenizerLoader()` macro that loads the tokenizer.
   - [`swift-transformers`](https://github.com/huggingface/swift-transformers) — product **Tokenizers**. Required by that macro's expanded code (macro expansions compile in *our* module, so we must import/link `Tokenizers` ourselves).
   - [`swift-jinja`](https://github.com/johnmai-dev/Jinja) — **pinned to `< 2.4.0`, do not bump.** jinja 2.4.0 changed `Jinja.Value.object` to a new `ObjectKey` type; `swift-transformers` (1.3.3) doesn't compile against it. The package is added purely to constrain transitive resolution — no product is linked. Remove the pin only after swift-transformers ships jinja ≥ 2.4 support.

5. **Signing** — select your team under *Signing & Capabilities* (a free personal team works; the app then expires after 7 days and needs re-installing from Xcode).

6. **Run on a plugged-in iPhone** (enable *Settings → Privacy & Security → Developer Mode* on the phone if prompted). First build is slow (MLX compiles, ~1GB of resources copy). After launch, **the first question takes noticeably longer** — that's the one-time model load; later questions are fast.

### Swapping the model

The code is model-agnostic: it loads whatever MLX-format model is in the app bundle. To try a different size (e.g. `Qwen3-4B-4bit` for better answers, or `0.6B` for speed): download its files, replace the model folder in the repo root, and update the folder name in Xcode's navigator (or `path` in `project.pbxproj`). No code changes.

> Note: Xcode's synchronized groups *flatten* the model files into the app bundle's top level (there is no `Qwen3-…` subfolder inside the built `.app`). That's why `QwenAnswerService` loads from `Bundle.main.bundleURL` directly.

---

## 3. How a question flows through the app

```
Child types question, taps Ask
        │
        ▼
HomeViewModel.submit()
        │  trims input; ignores empty
        ▼
SafetyService ──── blocked? ──── yes ──► fixed refusal string
        │ no                              answer never touches the model,
        ▼                                 saved to history with isBlocked=true
WikiSearchSession.lookUp(question) ─ nothing found, or passage unsafe ─► "I don't know yet"
        │ passage found                                                   model never runs
        ▼
QwenAnswerService.generateAnswer(question, context, passage)
        │  system prompt + "use only these facts" + last 2 turns + passage + question
        │  Qwen3 runs on-device via MLX, thinking mode disabled
        ▼
answer text ──── unsafe? ──── yes ──► fixed refusal string (as above)
        │ no
        ▼
from the passage? ──── no ──► "I don't know yet"
        │ yes
        ▼
+ one emoji from TopicEmoji ──► shown in AnswerView ──► saved to history (SwiftData)
                                                    └─► appended to in-memory follow-up context
```

Three subtleties worth knowing:

- **Follow-up questions.** Kids ask "Do owls eat frogs?" then "Why don't they?". Two things carry the topic. `WikiSearchSession` answers from the previous question's article when the new question has no topic of its own, and only then does the view model send earlier turns to the model (`conversationContext`, filtered to the turns about that same article, the last two of them). Any other earlier turn could only leak into the answer.
- **Blocked follow-ups.** After a blocked question, a bare follow-up ("Why not?") must get the *identical* refusal, not an answer. `HomeViewModel` remembers the pending blocked state and `SafetyService.isBareFollowUp` detects reference-only openers. Asking about a genuinely new topic clears the state.
- **Session boundaries.** Asking again from the answer screen, or going back with the Home tab, clears the input/answer but deliberately *keeps* follow-up context and blocked-topic state. Both are in-memory only, so relaunching the app is the natural session reset.

---

## 4. File-by-file guide

### App/
| File | Purpose |
|---|---|
| `WonderBugApp.swift` | `@main` entry point. Hosts everything in one `NavigationStack` and creates the SwiftData `ModelContainer` for `HistoryItem`. |

### Views/
| File | Purpose |
|---|---|
| `RootView.swift` | Shows the splash for 2s, then cross-fades to `MainTabView`. |
| `LaunchScreenView.swift` | The splash itself — logo at 80% screen width on the brand background. |
| `MainTabView.swift` | The app shell. Owns the shared `HomeViewModel` (constructed with the real `QwenAnswerService`), injects the history repository once the SwiftData context is available, and swaps content between Home / History / the current answer. Contains `CustomTabBar`, a hand-rolled tab bar with rounded top corners that stays visible even while an answer is shown (which a native `TabView` + navigation push couldn't do). |
| `HomeView.swift` | The ask screen: headline, bordered text field (custom placeholder + keyboard-dismiss button), four tap-to-insert question-starter chips (a long press edits one; edits are kept in `@AppStorage`), error text, and the Ask button (spinner + disabled while loading). Sets `answerData` on success, which makes `MainTabView` show `AnswerView`. |
| `AnswerView.swift` | Displays one Q&A: "A CURIOUS BUG ASKED…", the question, a "Read to me" TTS button, the answer, and a question bar for asking the next one in place (the new answer replaces this one via `onAnswer`). Tapping the already-selected Home tab goes back to `HomeView`. Stops speech on disappear or when the answer changes. |
| `HistoryView.swift` | Parent review screen. Live SwiftData `@Query` of all items, grouped under "TODAY / YESTERDAY / N DAYS AGO / date" headers, 🚩 prefix on blocked rows, an L1–L4 complexity tag, and a flagged-only filter toggle. Rows push `HistoryDetailView`. |
| `HistoryDetailView.swift` | Read-only detail of a stored item with the same typography and "Read to me" button as `AnswerView`, plus a custom circular back button (this screen *is* a navigation push). |
| `QuestionAnswerText.swift` | Tiny shared components — `QuestionText`, `AnswerText`, `ReadAloudButton`, `BlockedBadge` — so `AnswerView` and `HistoryDetailView` can't drift apart visually. |

### ViewModels/
| File | Purpose |
|---|---|
| `HomeViewModel.swift` | The brain of the ask flow (see diagram above). Published state: `question`, `answer`, `isLoading`, `errorMessage`. Depends on injected `AnswerServicing` + `SafetyServicing` protocols, an optional `WikiSearchSession` (nil means no bundled index, so there is nothing to answer from and every question gets `unknownAnswer`), and a `HistoryRepositoryProtocol` injected later via `configure(historyRepository:)` because it needs the environment's `ModelContext`. **Every answer comes from a Wikipedia passage**: no passage, no model run, and an answer that strayed from its passage (`WikiSearchService.isGrounded`) is replaced by `unknownAnswer` rather than shown. An unknown word ("a flurbin bird", a typo), a topic-less "they/it" question, an article that covers too little of the question, and a passage rejected as unsafe all show `unknownAnswer` alike. Letting the model answer from its own knowledge was tried and measured on device: 9 of the 12 such answers in the 2026-09-24 session were invented, so it was removed on 2026-09-26 and the app is more reticent by design. Every answer that is shown gets one emoji from `TopicEmoji`. In debug builds each step (search result, passage, prompt, raw and cleaned model output, safety verdicts) is printed to Xcode's console by `DebugLog`. Key methods: `submit()` (the whole pipeline), `clear()` (new-question reset that intentionally preserves session state). |

### Services/
| File | Purpose |
|---|---|
| `SafetyService.swift` | The rule-based content gate — **the most safety-critical file**. `blockedWords` (`graphicWords` plus `questionOnlyWords`) are matched against whole tokens only (so "war" never trips on "warm", "kill" on "skill"); `blockedPhrases` are matched at word boundaries (plain substring matching let "am i" fire inside "team is", "dam in", "program is"), with a phrase's final word allowed to run on ("self harm" → "self harming") unless it is two letters or fewer; `followUpReferencePhrases` powers blocked-topic continuation detection. "poison"/"smoke" are deliberately *not* bare blocked words (kids legitimately ask about poison ivy and volcano smoke) — dangerous *intent* phrases cover them. The fixed refusal string lives here as `blockedResponse`. The **question** is screened against the full list by `evaluate`, where words like "war" or "die" signal what a child is reaching for. A retrieved passage (`safePassage`) and the **generated answer** (`evaluateAnswer`) are screened against a **narrower** list, `graphicWords` — violence, sexual content, abuse, bodies, drink and drugs — because the full list rejected ordinary history and biology ("war" lost Harriet Tubman and George Washington, "dying" lost the Tasmanian devil). War, death, illness and the legal system reach the model and may appear in an answer — a faithful answer about Harriet Tubman was thrown away for the word "war", and a correct one about antibodies for "disease" — while inventions that matter are still caught ("He was killed in a duel with a man named John Adams" trips "killed"). `safePassage` rejects a passage that trips that narrower list — the whole passage, not just the offending sentence, because what survives a trim can still carry the same story in words the list lacks ("convicted of murdering" goes, "he had shot King" stays). "die" is a phrase rather than a blocked word (`"i die"`, `"want to die"`, `"how to die"`): a child asking how George Washington died is asking history, while "How can I die?" is not, and before this it was answered. Extend this list; never loosen it. |
| `AnswerService.swift` | `AnswerServicing` — the seam every answer generator implements (`generateAnswer(for:context:passage:)`), so the model can be swapped (or faked in tests) without touching the rest of the app. |
| `WikiSearchService.swift` | The offline Wikipedia search: an `actor` over the bundled `simplewiki.db` (SQLite FTS5 built with `detail='none'`, so only single-word MATCH queries work). A word the index has never seen falls back to its singular before being called invented (FTS5 does not fold "mantises" to "mantis"). It finds the question's subject — the first title match, unless a later one is at least 2.5 IDF rarer, which is what keeps "Are there prehistoric versions of platypuses?" off the Prehistory article — ranks candidate articles, and returns the sentences that answer — or nothing, which is how the app says "I don't know yet" without running the model. Articles are chosen by title and opening alone; once one is chosen, `choosePassage` may answer from one of its body paragraphs instead ("What do they use their trunk for?" → the Elephant article's Trunk section), which is mostly what lets a follow-up be answered at all. The opening wins ties, so a paragraph only ever displaces it by scoring higher: a paragraph cannot win on the article's own title words, on the question's subject, or on a premise word ("fish", "blue", "cold") unless the question asks why, and a section-heading match outranks any sentence match. `WikiSearchSession` carries the conversation, so "Do they jump?" reuses the previous question's article — unless the question brings a subject of its own, which `namesOwnTopic` decides from where the pronoun sits: English puts a question's subject straight after its auxiliary, so "how many teeth do **they** have" points back while "why do **elephants** use their trunks" does not (that one was answered from the Titanic article before this). A direct port of `Tools/WikiEval/eval_v2.py` in the local evaluation tools, kept honest by `Tools/WikiEval/parity/`, which checks both produce identical passages for the test questions. |
| `QwenAnswerService.swift` | The real answer generator. Lazily loads the bundled Qwen3-1.7B-4bit once via `loadModelContainer(from: Bundle.main.bundleURL, using: #huggingFaceTokenizerLoader())`, then per question: builds a chat prompt (system rules including "use only the facts in the passage" → up to 2 same-topic prior turns for a follow-up → the Wikipedia passage and the question), generates with thinking mode disabled and greedy decoding (temperature 0, no repetition penalty — MLX seeds that penalty's window from the prompt, so it suppressed the question's own words), and cleans the output with `AnswerCleanup`. The system prompt encodes the spec's voice rules: 2 or 3 sentences with a fact from the passage (demanding a "reason" the passage lacks produced made-up tautologies), facts only, plain words with no emoji, never ask back. |
| `AnswerCleanup.swift` | Turns raw model output into the answer shown: strips any stray `<think>` block (returning "" if generation died mid-think, which the view model turns into a friendly error), keeps only the first line (with a passage in the prompt, the model often restarts on a new line restating its answer, usually opening "Yes,"), trims a sentence left unfinished at the token cap, and removes emoji. Separate from `QwenAnswerService` so it compiles without MLX and can be checked on a Mac. |
| `TopicEmoji.swift` | Picks the one emoji shown after an answer from a fixed keyword list, checking the Wikipedia article's title before the question, and shows none when nothing matches. Replaced the model's own picks, which were often wrong (a peacock for spiders). |
| `SpeechService.swift` | "Read to me": wraps `AVSpeechSynthesizer` (fully on-device), strips emoji with `AnswerCleanup.removingEmoji` before speaking, publishes `isSpeaking` so buttons can flip play/pause, resets state via delegate callbacks when playback finishes naturally. |

### Models/ & Database/
| File | Purpose |
|---|---|
| `Models/AnswerData.swift` | Plain value type `{question, answer, topic}`. Double duty: the "currently shown answer" state in the UI, and the unit of follow-up context passed to the answer service. |
| `Database/HistoryItem.swift` | The SwiftData `@Model` for one logged Q&A (`id`, `question`, `answer`, `isBlocked`, `createdAt`). This is what `@Query` in `HistoryView` observes. |

### Repositories/
| File | Purpose |
|---|---|
| `HistoryRepository.swift` | `HistoryRepositoryProtocol` + SwiftData implementation: `save`, which also trims the store to the newest 700 entries (reads happen in the views through `@Query`). Keeps SwiftData out of the view model (and makes it fakeable in tests). |

### Resources/
| File | Purpose |
|---|---|
| `Colors.swift` | Brand palette as `Color.wb…` statics (background cream, title gray-green, sage accent, chip fill). |
| `Fonts.swift` | Placeholder for future custom typography (currently empty). |
| `Assets.xcassets` | App icon, `wordmark`/`logo+wordmark` brand images and the `send` glyph. |

---

## 5. Testing & debugging tips

- **Manual test battery.** Good sequences to exercise everything: a normal question → a pronoun follow-up ("Why don't they?") → an unrelated question (checks context isolation); a blocked question ("What is beer?") → "Why not?" (must repeat the identical refusal) → an innocent question (must recover); "What does poison ivy look like?" (must NOT block).
- **Reading the on-device history from your Mac.** Xcode → *Window → Devices and Simulators* → select the phone → *Installed Apps* → WonderBug → ⚙︎ → *Download Container…*. Inside the container, the SwiftData store is at `AppData/Library/Application Support/default.store` — a SQLite file; the Q&A log lives in table `ZHISTORYITEM` (timestamps are Apple-epoch: add `978307200` for Unix time). Invaluable for analyzing model answer quality in bulk.
- **Answer quality without a device.** The evaluation tools (a local repository in `Tools/`, not part of this one) run the whole answer path on a Mac: the Python search, the app's own model files in LM Studio with the app's prompt and generation settings, and the app's own Swift cleanup, safety and grounding code. `python3 answer_eval.py regression.txt` is the gate a search change should pass before it is ported to Swift; see `Tools/WikiEval/llm/README.md` for setup and for how closely the Mac reproduces the device (about 70% of answers identical — a Mac failure is real, a Mac pass still needs a device check).
- **Simulator behavior.** UI, history, and the safety gate all work in the Simulator; only actual answer generation requires the device. If you need to iterate on UI with live "answers", make a small throwaway `AnswerServicing` implementation that returns a canned string and pass it to `HomeViewModel` in `MainTabView` instead of `QwenAnswerService()`.

## 6. Known limitations / future work (Phase 2 pointers)

- **Long-tail facts.** Qwen3-1.7B answers common kid topics well but can confidently hallucinate on obscure ones. Options: the 4B model (~2.3GB), or a curated offline fact store.
- The safety gate is keyword/phrase-based — strong against direct topics, not against creative phrasing. The list is designed to be extended over time.
- Phase 2 spec items not yet started: question-complexity analytics (`complexity_level`, `has_connector`, …— the fields exist in the spec, not the schema), WonderSheets (online worksheet generation), Parent Wand (answer shaping), voice input, drag-and-drop question building blocks.
- No unit tests yet; `SafetyService` and `HomeViewModel` are the highest-value targets and were built against protocols specifically to enable this.
