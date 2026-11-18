# Bench: is Apple's on-device model good enough?

A macOS command-line tool that runs the app's own recap engines over the same
recordings and compares them:

| Label | What it is | Default model |
|---|---|---|
| `apple` | `AppleOnDeviceEngine`, the Foundation Models path the app ships | on-device |
| `haiku` | the Anthropic API, the app's default provider setting | `claude-haiku-4-5-20251001` |
| `strong` | a stronger Claude, to show the ceiling | `claude-sonnet-5-5` |

The engine sources are symlinked from `ios/CatchMeUp` (`Sources/BenchCore/App`), so the
benchmark exercises the shipping prompts, chunking, guided generation, JSON repair and
merging, not a copy. The only edit to app code is two `#if !CATCHMEUP_BENCH` guards in
`RecapEngine.swift` that leave out the settings-dependent factory and the demo engine.

## Quick start

```bash
cd ios/Bench
swift run bench check                      # model availability, key, corpus summary
swift run bench run --engines apple        # free, runs on this Mac
```

The cloud engines and the judge read `ANTHROPIC_API_KEY` from the environment and never
print it. With direnv it is already loaded; otherwise:

```bash
export ANTHROPIC_API_KEY="$(secret get ANTHROPIC_API_KEY)"
swift run bench run --max-cost 3           # all three engines
swift run bench judge --max-cost 4         # blind Claude judge
swift run bench report                     # tables and a verdict
```

`judge` and `report` use the most recent `results/<timestamp>` unless you pass `--out`.
Runs are resumable: finished recordings are skipped unless you pass `--force`.

Requires macOS 26 with Apple Intelligence enabled for the `apple` engine.

## What is measured

Mechanical checks (no judge, no vendor bias):

- **Failure rate.** Errors, refusals, and recaps with no summary and no notes.
- **Fact coverage.** Share of hand-written gold facts the notes cover.
- **Bookmarks on target.** Timestamps the player can seek to and that land within 60 s of a real transcript line.
- **Invented names.** Speaker names that are not in the transcript, and trap names that cannot be.
- **Name clashes.** One real name attached to several speakers.
- **Unsupported numbers.** Figures in the notes that never appear in the transcript. This is a proxy: a correctly computed figure (an average, a percentage) also counts, for every engine alike.
- **Time and API cost** per recording.

Judged checks (`bench judge`, a stronger Claude, `claude-opus-5-5` by default):

- Faithfulness, completeness and usefulness from 1 to 5, scored blind against the transcript.
- Pairwise preference between every two engines, run in both orders. A win only counts if it holds in both; a split is a tie.

## The pass bar

`criteria.json` is the bar for `apple` replacing `haiku`. It is meant to be set before you
look at results. The report prints each criterion as pass, FAIL, or n/a (no data yet), and
an overall verdict that is only "Meets every criterion" when nothing is missing or failing.

## The corpus

`corpus/<id>/transcript.txt` plus `meta.json` (mode, title, gold facts, real and trap
names). Nine recordings: short, medium and long (4+ on-device windows) lectures, and
meetings including one where nobody is named, so any name in its notes is invented.
They are written for the benchmark; they are not real recordings.

Add your own, in the app's `[HH:MM:SS] text` shape:

```bash
swift run bench import --file my-lecture.txt --id bio-week4 --mode lecture --title "Bio week 4"
```

Imported recordings have no gold facts, so they get every metric except fact coverage.
Add entries under `gold.facts` in its `meta.json` to include it there. Real recordings are the better test:
the sample set is small and tidy.

## Cost

Everything that calls the API counts against `--max-cost` (default $5 per invocation), and
a call is refused before it is sent once the limit is reached. Prices live in
`Sources/BenchCore/Anthropic.swift`. Models with no listed price report cost as unknown.
Use `--haiku-model`, `--strong-model` and `--judge-model` to try other models.

## Reading the results fairly

- Few recordings means noisy numbers. Treat small gaps as ties.
- The judge is a Claude model and may favour Claude-style writing; the mechanical metrics do not share that bias.
- Timing is from this Mac. An iPhone is slower and can throttle, so re-time on a device before relying on it.
- Quality metrics cover only recordings an engine finished.
- Not covered yet: Ask over a brain, flashcard minting, material analysis and meeting extraction. They are separate on-device code paths and may fail differently.

## Tests

```bash
swift test
```

Covers the metrics, corpus integrity (every gold fact is anchored in its transcript), report
verdicts, the pairwise rule, pricing, and the HTTP layer against a stubbed network (request
shape, no sampling parameters, spend accounting, retries, key never in errors).
