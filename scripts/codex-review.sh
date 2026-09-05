#!/usr/bin/env bash
# codex-review.sh — independent review of a packet and the corpus content it adds.
#
# Usage:  ./scripts/codex-review.sh <packet-file> [output-file]
#
# Adapted from the browser-llm script of the same name. The difference matters:
# there, the artifact under review is application code, and the question is
# whether it works. Here the artifact is *guidance other people will follow*,
# and the question is whether it is TRUE. A corpus entry that is elegant,
# well-formatted and factually wrong is worse than no entry, because it will be
# cited.
#
# Default output: docs/research/<packet-name>-codex-review.md
#
# Reviewer independence is the point: this session's author should not be the
# only one judging whether the packet's claims hold.

set -euo pipefail

cd "$(dirname "$0")/.."

# Pinned here rather than in ~/.codex/config.toml so this script's behavior does
# not drift with the user's interactive default. Override with CODEX_MODEL.
MODEL="${CODEX_MODEL:-gpt-5.6-sol}"
EFFORT="${CODEX_EFFORT:-high}"

# The MCP servers this review is required to consult. Names must match the
# server keys in ~/.codex/config.toml or the reviewer will cite tools it never
# called.
GUIDELINES_URL="${CPP_GUIDELINES_URL:-http://127.0.0.1:7011}"
PERF_URL="${CPP_PERF_URL:-http://127.0.0.1:7015}"

die() { echo "codex-review.sh: $*" >&2; exit 1; }

command -v codex >/dev/null 2>&1 || die "'codex' CLI not found on PATH"

PACKET="${1:-}"
OUTPUT_ARG="${2:-}"
[ -n "${PACKET}" ] || die "usage: $0 <packet-file> [output-file]"
[ -r "${PACKET}" ] || die "cannot read packet: ${PACKET}"

# The MCP servers are a hard requirement of this review, not a nice-to-have.
# Checking here converts a silent mid-review skip into an upfront failure.
#
# Branch on curl's exit status, not on the body: any HTTP status means the
# server is listening (a bare GET returns 406 because the MCP streamable
# transport wants its own Accept headers), so `curl -f` must NOT be used.
check_mcp() {
  name="$1"; url="$2"
  if ! curl -s -o /dev/null --max-time 5 "${url}" 2>/dev/null; then
    die "MCP server '${name}' is not reachable at ${url}
  This review is required to be grounded in it. Start the server and retry,
  rather than running a review that cannot check what it claims to check."
  fi
}
check_mcp "cpp-guidelines" "${GUIDELINES_URL}"
check_mcp "cpp-performance" "${PERF_URL}"

PACKET_BASE="$(basename "${PACKET}" .md)"
OUTPUT="${OUTPUT_ARG:-docs/research/${PACKET_BASE}-codex-review.md}"
[ -e "${OUTPUT}" ] && die "review already exists: ${OUTPUT}
  delete it or pass a different output path"

PROMPT_FILE="$(mktemp -t cppperf-codex-prompt.XXXXXX)"
trap 'rm -f "${PROMPT_FILE}"' EXIT

{
  cat <<'PROMPTEOF'
You are performing an independent review of a work packet and the corpus
content it adds, in the cpp-perf-guidelines repository. You are the second
reader: the packet's author already believes the work is correct. Your job is
to find where that belief is wrong.

WHAT THIS REPOSITORY IS
-----------------------
A curated corpus of low-level C++ performance guidelines, deliberately sitting
BELOW the ISO C++ Core Guidelines. The ISO guidelines stop at "use the standard
library well"; this corpus owns the concrete technique layer.

Internal R&D under Plainsight Systems LLC; no operating brand. It is consumed
by an MCP server that parses it and exposes it to agents, so the document
format IS a parser contract.

Each guideline is one Markdown file with TOML frontmatter under
guidelines/<category>/, format specified in README.md. Categories are declared
in categories.toml.

WHY THIS REVIEW IS DIFFERENT FROM AN APPLICATION-CODE REVIEW
------------------------------------------------------------
The artifact under review is guidance other engineers will follow and cite. A
corpus entry that is elegant, well-formatted, internally consistent and
FACTUALLY WRONG is worse than no entry at all, because its confidence is what
makes it dangerous. Weight your effort accordingly:

  Factual accuracy  >  originality/sourcing  >  format compliance  >  style

WHAT TO REVIEW, IN PRIORITY ORDER
---------------------------------
  1. FACTUAL ACCURACY. This is the primary job. Every technical claim in the
     new guidelines — every number, threshold, flag name, API name, behavioral
     assertion, version claim — must be true and must match what its cited
     source actually says.

     Check specifically:
       - Numbers and thresholds attributed to a source. Does the source say
         that number, or has it drifted in the retelling?
       - Compiler and linker flag names and their spelling. A wrong flag is a
         reader's wasted afternoon.
       - API names, semantics, and defaults.
       - Claims about what an engine, browser, or toolchain does. Are these
         stated with the right scope, or is one vendor's behavior presented as
         universal?
       - Attributions. Does the cited source support the claim attached to it,
         or merely sit near it?
       - Anything stated with more confidence than its evidence supports.
         Flag over-claiming even where the claim is probably true.

     You have web access. Use it. Check the cited sources rather than relying
     on your own recollection of them, and say which ones you actually opened.

  2. THE PACKET'S CLAIMS. The packet states intent, acceptance criteria and
     guaranteed invariants. Check each against the working tree. A packet
     describing content, properties or guarantees that do not exist is a
     serious finding aimed at the reviewer, and is exactly what this review
     exists to catch.

  3. SOURCING RULE COMPLIANCE. CONTRIBUTING.md requires that every guideline is
     original work: techniques may be studied and cited, but text and code must
     not be copied or closely paraphrased. Check the new prose and the code
     examples against their cited sources for lifted or transliterated
     material. This is a licensing exposure, not a style preference.

  4. CONTRADICTIONS WITH THE EXISTING CORPUS. New guidelines must not silently
     contradict existing ones. Where they qualify or override an existing rule
     for a new context, that must be explicit and cross-referenced, not left
     for a reader to discover.

  5. CROSS-REFERENCE ACCURACY. Guidelines cite each other by ID with a short
     description of what the referenced rule says. Verify BOTH that each cited
     ID exists AND that the description matches that guideline's actual title
     and content. An ID that exists but is described wrongly passes the
     repository's validator and still misleads every reader.

  6. C++ EXAMPLE CORRECTNESS. The examples are the largest section of a typical
     guideline and carry most of the teaching. Check that they compile in
     principle, are idiomatic modern C++, do what their comments claim, and do
     not violate the C++ Core Guidelines while purporting to demonstrate good
     practice.

  7. FORMAT AND PARSER CONTRACT. Frontmatter fields, ID/token/directory
     consistency, summary length, required sections, working local links, per
     README.md. `python3 tools/validate_corpus.py` is the mechanical check —
     run it, but do not stop there; it checks structure, not truth.

  8. NO-FACADES. Guidance that reads as settled when it is contested;
     recommendations with no stated cost; confident advice on a topic the
     research did not actually cover.

HARD REQUIREMENT — GROUND EVERY GUIDELINE CITATION IN THE MCP SERVERS
---------------------------------------------------------------------
Two MCP servers are available and you MUST use them. Do not cite a rule from
memory.

  cpp-guidelines    search_guidelines / get_guideline   (ISO C++ Core Guidelines)
  cpp-performance   search_guidelines / get_guideline   (this corpus, as published)

  1. Use cpp-guidelines to check the C++ examples against Core Guidelines rules,
     and to find rules the examples violate that the packet did not consider.
  2. Use cpp-performance to check the NEW guidelines against the EXISTING corpus
     for contradiction and duplication.

  IMPORTANT: the cpp-performance server indexes the corpus as PUBLISHED, which
  will not yet contain the guidelines this packet adds. Read those from the
  working tree. Use the server for what already exists; use the files for what
  is new. Do not report a new guideline as missing from the server — that is
  expected and is not a finding.

If either server is unavailable, or any MCP call is cancelled or denied, you
MUST state this in your output as a REVIEW ENVIRONMENT FAILURE and mark the
affected check as NOT PERFORMED. Never proceed as though a guideline had been
consulted when it was not. Silently skipping this is the single worst thing you
can do in this review.

Do not manufacture findings to appear thorough. If something is sound, say so
and say why. Equally, do not soften a real finding to be agreeable. A finding
that a specific number is wrong is worth more than ten observations about tone.

OUTPUT FORMAT
-------------
Markdown. Lead with an outcome line:

  OUTCOME: approved | approved_with_notes | changes_requested | needs_decision

Then, as separate sections kept distinct from each other:
  - Summary (what the packet claimed, and whether it holds)
  - Factual accuracy findings — the primary section. Each with severity,
    file:line, the claim as written, what the source actually says, the source
    you checked, and the expected correction.
  - Sourcing and originality
  - Corpus consistency (contradictions, duplication, cross-reference accuracy)
  - C++ example review, grounded in cpp-guidelines rule IDs
  - Format and parser contract
  - MCP grounding — which servers and tools you actually called, which external
    sources you actually opened, and any REVIEW ENVIRONMENT FAILURE
  - Residual risk

Severity: P0 blocks (factually wrong guidance, licensing exposure), P1 blocks
(materially misleading, wrong attribution), P2 should fix, P3 optional.
A P0 or P1 finding blocks acceptance.

PROMPTEOF

  printf '=== PACKET UNDER REVIEW: %s ===\n' "${PACKET}"
  cat "${PACKET}"
  printf '\n=== END PACKET ===\n\n'

  printf 'FILES ADDED OR CHANGED BY THIS WORK\n'
  printf -- '-----------------------------------\n'
  git diff --stat HEAD~1 HEAD 2>/dev/null || git status --short
  printf '\n'

  printf 'Repository root is the current working directory. Read whatever\n'
  printf 'guideline files, research notes, README and tooling you need to judge\n'
  printf 'the claims above. The research note cited by the packet records which\n'
  printf 'sources each guideline rests on — check the guidelines against those\n'
  printf 'sources, not against the research note alone.\n'
} > "${PROMPT_FILE}"

# '-a on-request' is REQUIRED: the cpp-guidelines / cpp-performance MCP tools
# are approval-gated in ~/.codex/config.toml. Under a bare 'codex exec' those
# calls are cancelled and the review proceeds having read no guideline at all.
# Do not drop this flag.
echo "codex-review.sh: reviewing ${PACKET}" >&2
echo "  model:  ${MODEL} (effort ${EFFORT})" >&2
echo "  output: ${OUTPUT}" >&2

mkdir -p "$(dirname "${OUTPUT}")"

codex -a on-request exec \
  -m "${MODEL}" \
  -c model_reasoning_effort="\"${EFFORT}\"" \
  -o "${OUTPUT}" \
  - < "${PROMPT_FILE}" || {
  RC=$?
  echo "codex-review.sh: codex exited non-zero (${RC})" >&2
  exit "${RC}"
}

[ -s "${OUTPUT}" ] || die "codex produced an empty review — not keeping it"

echo "codex-review.sh: review written to ${OUTPUT}" >&2
