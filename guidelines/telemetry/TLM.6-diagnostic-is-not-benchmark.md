+++
id = "TLM.6"
title = "Diagnostic mode is not benchmark mode — telemetry-enabled runs carry observer-effect labels and cannot be quoted as clean throughput"
category = "telemetry"
status = "draft"
summary = "Telemetry-enabled runs carry an observer-effect label and cannot be quoted as clean throughput. The build system fails closed against `--benchmark --trace`; artefacts name their build profile."
tags = ["observer-effect", "benchmark", "build-profile", "fail-closed", "vigil"]
+++

## Rationale

If a benchmark number was produced by a run with telemetry
turned on, the number is not the system's number. It is the
system-plus-harness number. The harness perturbs:

- **Caches.** Telemetry buffers, sink threads, and emit code
  occupy I-cache and D-cache slots the work loop would have
  used.
- **TLB and prefetcher.** New code regions and new memory
  regions disturb both.
- **Branch predictor.** The probe sites are new branches
  whose predictor state is built from scratch.
- **Scheduling.** A sink thread on the same socket can steal
  cycles from the work thread; the OS scheduler treats it as
  legitimate work.
- **Allocations.** Per-event allocations (even one!) change
  allocator state and may trigger madvise/mmap traffic.
- **Power and thermal.** A second hot thread changes the
  socket's power envelope; turbo behaviour shifts.

The cost is not always large; sometimes it is well below the
noise floor. But the cost is not zero, and it is not known in
advance. The discipline is: **never let a telemetry-enabled
build produce a number that gets quoted as a clean baseline.**

The mature pattern is **build-profile fail-closed**. The build
system has explicit profiles — `--performance`, `--benchmark`,
`--profile`, `--trace`, `--test` — and the combinations that
violate the contract are *rejected by the build script*, not
flagged after the fact. Vigil packet 142 is the canonical
worked example: `scripts/build.sh --performance --trace` exits
with status 2 and no artefact is produced. The check is at
build time because it is the last point where a human can
intervene before a polluted artefact reaches a measurement
run.

Engine evidence:

- **Unity** documents deep profiling as "significant
  overhead" and explicitly tells users not to interpret
  deep-profiled numbers as production performance.
- **Unreal CSV Profiler** is documented as "not available in
  shipping builds."
- **Tracy** acknowledges that an enabled build is a
  profiling build; the documentation expects this and treats
  it as a feature, not a flaw.
- **Vigil packet 142** formalised this: `--performance` and
  `--benchmark` profiles are rejected at the build script if
  any trace/diagnostic flag is set, with exit code 2.

A related but distinct point: **sampling profilers are
different.** `perf record`, Instruments Time Profiler, VTune
sampling, and Apple Silicon's CPU sampling are *approximately
non-invasive* — they interrupt the CPU periodically and read
program counters, with overhead bounded by the sample rate
(typically <2.5× per Brendan Gregg's surveys for `perf stat`).
A sampled benchmark is closer to a clean benchmark than an
instrumented one. The corpus position: instrumented telemetry
means observer-effect-labeled; sampling profilers can be run
against a clean build *without* changing what was built.

The artefact contract:

- Every benchmark result names the build profile it was
  produced under (`vigil-bench-mlx-performance-no-trace`,
  not `vigil-bench`).
- A diagnostic run is labeled diagnostic in its own filename
  and metadata.
- The two are never aggregated into the same dataset.

## Guidance

- **Make the contract a build-system check, not a code
  comment.** `--performance` + `--trace` should be a
  refused command, not a "should not be done."
- **Name artefacts by build profile.** Filenames, internal
  metadata, displayed labels all reflect what the build was
  compiled with.
- **Treat diagnostic-build numbers as diagnostic.** They
  explain behavior; they do not headline release notes.
- **Sampling profilers can be applied to clean builds.**
  `perf record -F 997 ./clean-binary`, `xctrace record
  --template "Time Profiler"`, VTune sampling. Distinguish
  this from instrumented runs in any methodology
  description.
- **A "diagnostic mode" toggle at runtime, in a build
  compiled with diagnostics, must still be labeled.** The
  artefact metadata records the runtime state too — "the
  binary was diagnostic-capable, and the diagnostic mode was
  enabled for this run."
- **Cross-reference `EMB.*` for the hardest cases.** Embedded
  systems with hard real-time constraints may not even
  *boot* with telemetry enabled. The diagnostic-vs-benchmark
  split is most starkly visible there.
- **Document the harness cost in the diagnostic run.** "This
  run was diagnostic mode; the harness cost was measured at
  X ns/zone × Y zones per frame = Z% overhead." Without the
  number, the diagnostic build is mute.

## Example

```bash
# Good: build script rejects the violating combination.
# Exit code 2 means "you asked for two things that contradict";
# no artefact is produced.
#
# scripts/build.sh
case "$1 $2" in
    "--performance --trace"|"--benchmark --trace")
        echo "ERROR: --trace cannot be combined with --performance or --benchmark"
        echo "       Telemetry-enabled builds carry observer-effect overhead"
        echo "       and cannot be quoted as clean throughput."
        exit 2
        ;;
    "--performance"|"--benchmark")
        # Build with VIGIL_PROFILE_ENABLED undefined; no trace
        # macro expansions, no diagnostic env parsing.
        cmake -DVIGIL_TRACE=OFF -DVIGIL_DIAGNOSTIC=OFF ...
        ;;
    "--trace")
        # Diagnostic build; produces vigil-bench-diagnostic-*
        # artefacts that are never aggregated into clean
        # benchmark datasets.
        cmake -DVIGIL_TRACE=ON ...
        ;;
esac
```

```cpp
// Good: artefact metadata records the build profile.
// The benchmark harness writes this into the result file
// and refuses to upload if it disagrees with the binary.
struct BenchResult {
    std::string  binary_name;       // "vigil-bench-performance"
    std::string  build_profile;     // "performance, no-trace"
    bool         telemetry_enabled; // false; checked at startup
    bool         diagnostic_mode;   // false
    double       throughput_t_s;
};

void publish_result(const BenchResult& r) {
    if (r.telemetry_enabled || r.diagnostic_mode) {
        // Diagnostic build; goes to diagnostic dataset.
        write_diagnostic_run(r);
        return;
    }
    write_clean_baseline(r);
}

// Bad: the same binary, with a runtime flag, is run twice and
// both numbers are quoted as "throughput." One is observer-
// effect-laden; both end up in the headline.
int main(int argc, char** argv) {
    if (argv[1] && std::string{argv[1]} == "--trace") {
        enable_tracing();   // adds harness cost
    }
    run_benchmark();
    print_throughput();     // no label distinguishing the two
}
```

## Caveats

- **Sometimes the harness cost is what you want to measure.**
  A run with telemetry on can be the right benchmark for
  *the harness itself*. Label it that way; it does not
  headline the system's throughput.
- **The sampling-profiler exception is approximate.** `perf
  record` does interrupt the CPU; on a tight loop saturating
  one core, sampling at 1 kHz adds measurable overhead.
  Document the sample rate and check the noise floor.
- **Build-profile fail-closed is rule-of-three rigorous.**
  Three profiles (`performance`, `benchmark`, `trace`) and
  the disallowed combinations grows quadratically; codify
  the matrix.
- **A "shipped with telemetry on" product is a design
  decision, not a violation** — RAD Telemetry's case. The
  rule is "label it"; the rule is not "never ship with
  telemetry on."
- **Diagnostic runs are valuable evidence for behavior,
  not throughput.** A diagnostic run that shows "the MTP
  policy switched 87 times" is the right evidence for the
  policy question; it is not the right evidence for the
  throughput question.
- **The benchmark dataset itself must remain pure.** Mixing
  diagnostic and clean runs in the same dataset poisons
  long-term trend analysis. Two separate datasets.

## References

- Unity, *Profiler — Deep Profiling overhead* — Unity
  Manual.
- Unreal Engine, *CSV Profiler* (not available in shipping
  builds) —
  <https://dev.epicgames.com/documentation/en-us/unreal-engine/csv-profiler>
- Tracy Profiler — enabled-build acknowledgement —
  <https://github.com/wolfpld/tracy>
- Vigil packet 142, *Unreal-Style Observability Boundary* —
  build-profile fail-closed at the build script
  (exit code 2 for `--performance --trace`).
- Brendan Gregg, *perf Examples* — sampling overhead
  estimates — <https://www.brendangregg.com/perf.html>
- Cross-reference: `TLM.1` (compile-out is the
  foundation), `TLM.8` (artifact-scan validation enforces
  the contract), `EMB.*` (hard-real-time systems and the
  observer-effect ceiling), `GEN.*` (codegen perturbation
  from probe-site presence).
