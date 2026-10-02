#!/usr/bin/env bash
#
# sec-review.sh - adversarial pre-push security gate.
#
# Runs the exact diff being pushed past the OPPOSITE model, blocks the push
# while any unaccepted critical/high finding stands, and writes a sanitized,
# committable evidence record.
#
# Usage:
#   sec-review.sh --hook                 read pre-push ref lines from stdin
#   sec-review.sh --range <base>..<head> review an explicit range
#   sec-review.sh --staged               review the staged diff
#   sec-review.sh --record-only ...      review and record, never exit non-zero
#
# Env:
#   SEC_DEV_MODEL=claude|codex   who wrote the code (skips trailer/prompt)
#   SEC_REVIEWER_CMD=<cmd>       override the reviewer (testing); receives the
#                                prompt on stdin and must print JSON on stdout
#   SEC_MAX_DIFF_BYTES=<n>       fail closed above this size (default 400000)
#   SEC_CLAUDE_MODEL=<name>      default claude-opus-5
#   SEC_NOTES_REF=<ref>          evidence notes ref (default
#                                refs/notes/security-reviews)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/prompts/security.md"
MAX_DIFF_BYTES="${SEC_MAX_DIFF_BYTES:-400000}"
CLAUDE_MODEL="${SEC_CLAUDE_MODEL:-claude-opus-5}"
BLOCKING_SEVERITIES='["critical","high"]'

die()  { printf 'secgate: %s\n' "$1" >&2; exit 2; }
warn() { printf 'secgate: %s\n' "$1" >&2; }
info() { printf 'secgate: %s\n' "$1" >&2; }

command -v jq  >/dev/null || die "jq is required (brew install jq)"
command -v git >/dev/null || die "git is required"
[ -f "$PROMPT_FILE" ] || die "prompt not found: $PROMPT_FILE"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
REPO_NAME="$(basename "$REPO_ROOT")"
REMOTE_URL="$(git remote get-url origin 2>/dev/null || echo "")"
EVIDENCE_DIR="$REPO_ROOT/.security-reviews"
ACCEPTED_FILE="$EVIDENCE_DIR/accepted.json"
NOTES_REF="${SEC_NOTES_REF:-refs/notes/security-reviews}"

# ---------------------------------------------------------------- arguments
MODE=""; RANGE=""; RECORD_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --hook)        MODE="hook" ;;
    --range)       MODE="range"; RANGE="${2:?--range needs <base>..<head>}"; shift ;;
    --staged)      MODE="staged" ;;
    --record-only) RECORD_ONLY=1 ;;
    -h|--help)     sed -n '3,20p' "$0"; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
  shift
done
[ -n "$MODE" ] || die "one of --hook, --range, --staged is required"

TMPDIR_SG="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_SG"; }
trap cleanup EXIT INT TERM
DIFF_FILE="$TMPDIR_SG/change.diff"

# ------------------------------------------------------- resolve the change
HEAD_SHA=""
case "$MODE" in
  staged)
    git diff --staged > "$DIFF_FILE"
    HEAD_SHA="$(git rev-parse HEAD)"
    RANGE="staged@$(git rev-parse --short HEAD)"
    ;;
  range)
    git diff "${RANGE%%..*}" "${RANGE##*..}" > "$DIFF_FILE" 2>/dev/null \
      || die "cannot diff range: $RANGE"
    HEAD_SHA="$(git rev-parse "${RANGE##*..}")"
    ;;
  hook)
    # stdin: <local_ref> <local_sha> <remote_ref> <remote_sha>
    ZERO="0000000000000000000000000000000000000000"
    while read -r _local_ref local_sha _remote_ref remote_sha; do
      [ -z "${local_sha:-}" ] && continue
      [ "$local_sha" = "$ZERO" ] && continue          # branch deletion
      # evidence notes carry no code and must never re-enter the gate that
      # produced them; a notes-only push has nothing to review.
      case "$_local_ref" in refs/notes/*) continue ;; esac
      base=""
      if [ "$remote_sha" = "$ZERO" ]; then
        # new branch upstream: only what is not already on any remote.
        # NOTE: plain `git rev-parse X^` echoes X^ to stdout when it cannot
        # resolve it, which silently produced a bogus base and an empty diff.
        # --verify --quiet is the only form that stays silent and fails.
        oldest="$(git rev-list "$local_sha" --not --remotes 2>/dev/null | tail -n1)"
        if [ -n "$oldest" ]; then
          base="$(git rev-parse --verify --quiet "${oldest}^" || true)"
        fi
        [ -n "$base" ] || base="$(git hash-object -t tree /dev/null)"
      else
        base="$remote_sha"
      fi

      if ! git diff "$base" "$local_sha" >> "$DIFF_FILE" 2>/dev/null; then
        warn "cannot diff ${base:0:7}..${local_sha:0:7} - FAILING CLOSED."
        exit 1
      fi
      RANGE="${base:0:7}..${local_sha:0:7}"
      HEAD_SHA="$local_sha"
    done
    ;;
esac

if [ ! -s "$DIFF_FILE" ]; then
  info "nothing to review (empty diff) - allowing"
  exit 0
fi

# code-only gate: skip when the change touches no executable file
CODE_CHANGED=$(grep -E '^\+\+\+ b/' "$DIFF_FILE" \
  | grep -Evc '\.(md|txt|lock|svg|png|jpg|jpeg|gif|ico|csv|json5)$|(^\+\+\+ b/.*\/)?(package-lock\.json|pnpm-lock\.yaml|uv\.lock)$' \
  || true)
if [ "${CODE_CHANGED:-0}" -eq 0 ]; then
  info "no executable code in this change - allowing"
  exit 0
fi

DIFF_BYTES=$(wc -c < "$DIFF_FILE" | tr -d ' ')
if [ "$DIFF_BYTES" -gt "$MAX_DIFF_BYTES" ]; then
  warn "diff is ${DIFF_BYTES} bytes, over the ${MAX_DIFF_BYTES} limit."
  warn "FAILING CLOSED - split the push or run a manual review."
  exit 1
fi

# ------------------------------------------------- who wrote this code
resolve_dev_models() {
  if [ -n "${SEC_DEV_MODEL:-}" ]; then printf '%s\n' "$SEC_DEV_MODEL"; return; fi

  if [ "$MODE" = "hook" ] || [ "$MODE" = "range" ]; then
    local trailers
    trailers="$(git log --format='%(trailers:key=Dev-Model,valueonly)' \
                  "${RANGE//../..}" 2>/dev/null | tr 'A-Z' 'a-z' | grep -E '^(claude|codex)$' | sort -u)"
    if [ -n "$trailers" ]; then printf '%s\n' "$trailers"; return; fi
  fi

  if [ -e /dev/tty ] && { : > /dev/tty; } 2>/dev/null; then
    local answer=""
    printf 'secgate: which model wrote or materially assisted this code? [claude/codex]: ' > /dev/tty
    read -r answer < /dev/tty || answer=""
    answer="$(printf '%s' "$answer" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
    case "$answer" in claude|codex) printf '%s\n' "$answer"; return ;; esac
  fi

  return 1
}

DEV_MODELS="$(resolve_dev_models)" || {
  warn "cannot determine which model wrote this code."
  warn "Set SEC_DEV_MODEL=claude|codex, or add a 'Dev-Model:' commit trailer."
  warn "FAILING CLOSED."
  exit 1
}

reviewer_for() { case "$1" in claude) echo codex ;; codex) echo claude ;; *) echo "" ;; esac; }

# ------------------------------------------------------- run the reviewer
run_reviewer() {                       # run_reviewer <reviewer> <outfile>
  local reviewer="$1" out="$2" prompt
  prompt="$(sed -e "s|{{DIFF_PATH}}|$DIFF_FILE|g" -e "s|{{REPO_ROOT}}|$REPO_ROOT|g" "$PROMPT_FILE")"

  if [ -n "${SEC_REVIEWER_CMD:-}" ]; then
    printf '%s' "$prompt" | SEC_REVIEWER="$reviewer" sh -c "$SEC_REVIEWER_CMD" > "$out" 2>/dev/null
    return $?
  fi

  case "$reviewer" in
    claude)
      command -v claude >/dev/null || { warn "claude CLI not found"; return 127; }
      claude -p "$prompt" --model "$CLAUDE_MODEL" --allowedTools Read,Grep,Glob > "$out" 2>"$out.err" ;;
    codex)
      command -v codex >/dev/null || { warn "codex CLI not found"; return 127; }
      codex exec --sandbox read-only "$prompt" > "$out" 2>"$out.err" ;;
    *) return 2 ;;
  esac
}

# a reviewer CLI can refuse before it ever reads the prompt - an unavailable
# model, an expired login, an empty credit balance. Those reasons arrive on
# stdout or stderr and are worthless to the developer if the gate eats them.
reviewer_failure_detail() {            # reviewer_failure_detail <rawfile>
  local raw="$1" src line
  for src in "$raw.err" "$raw"; do
    [ -s "$src" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] && warn "  ${line}"
    done < <(grep -v '^[[:space:]]*$' "$src" | tail -n 3)
  done
}

# pull the first well-formed JSON object out of whatever the model printed.
#
# NOTE: jq treats an EMPTY input stream as success and exits 0 for any filter,
# including has("findings"). Every check below therefore also requires a
# non-empty result, or a rambling reviewer would sail through the gate.
json_object_ok() {                     # json_object_ok <file>
  [ -s "$1" ] || return 1
  jq -e 'type == "object"' "$1" >/dev/null 2>&1
}

extract_json() {                       # extract_json <infile> <outfile>
  local raw="$1" out="$2" carve="$TMPDIR_SG/carve.json"
  : > "$out"

  # 1. the whole file already is the object
  if json_object_ok "$raw"; then
    jq . "$raw" > "$out" 2>/dev/null && json_object_ok "$out" && return 0
  fi

  # 2. the contents of the first fenced code block
  awk '/^[[:space:]]*```/ { infence = !infence; next } infence' "$raw" > "$carve"
  if json_object_ok "$carve"; then
    jq . "$carve" > "$out" 2>/dev/null && json_object_ok "$out" && return 0
  fi

  # 3. from the first "{" to the last "}", dropping any prose around it
  awk '
    NR == FNR {
      if (!first && index($0, "{")) first = FNR
      if (index($0, "}")) last = FNR
      next
    }
    first && FNR >= first && FNR <= last
  ' "$raw" "$raw" > "$carve"
  if json_object_ok "$carve"; then
    jq . "$carve" > "$out" 2>/dev/null && json_object_ok "$out" && return 0
  fi

  : > "$out"
  return 1
}

ALL_FINDINGS="$TMPDIR_SG/findings.json";  echo '[]' > "$ALL_FINDINGS"
ALL_CHECKS="$TMPDIR_SG/checks.json";      echo '[]' > "$ALL_CHECKS"
REVIEWERS_RUN=()

for dev in $DEV_MODELS; do
  reviewer="$(reviewer_for "$dev")"
  [ -n "$reviewer" ] || { warn "unknown dev model '$dev' - FAILING CLOSED"; exit 1; }
  info "code by ${dev} -> reviewing with ${reviewer}"

  raw="$TMPDIR_SG/raw-$reviewer.txt"; parsed="$TMPDIR_SG/parsed-$reviewer.json"
  if ! run_reviewer "$reviewer" "$raw"; then
    warn "${reviewer} review did not complete - FAILING CLOSED."; exit 1
  fi
  if ! extract_json "$raw" "$parsed"; then
    warn "${reviewer} did not return parseable JSON - FAILING CLOSED."
    warn "A review that cannot be read is not a review that passed."
    exit 1
  fi
  if ! { [ -s "$parsed" ] && jq -e '
           type == "object"
           and (.findings | type == "array")
           and (.verdict  | type == "string")
         ' "$parsed" >/dev/null 2>&1; }; then
    warn "${reviewer} JSON lacks a findings array or a verdict string - FAILING CLOSED."; exit 1
  fi

  jq --arg r "$reviewer" --arg d "$dev" \
     '[.findings[] | . + {review_model:$r, development_model:$d}]' "$parsed" \
     > "$TMPDIR_SG/f.json"
  jq -s 'add' "$ALL_FINDINGS" "$TMPDIR_SG/f.json" > "$TMPDIR_SG/f2.json" && mv "$TMPDIR_SG/f2.json" "$ALL_FINDINGS"
  jq -s 'add | unique' "$ALL_CHECKS" <(jq '.checks_performed // []' "$parsed") > "$TMPDIR_SG/c2.json" \
    && mv "$TMPDIR_SG/c2.json" "$ALL_CHECKS"
  REVIEWERS_RUN+=("$reviewer")
done

# ------------------------------- subtract accepted false positives
TODAY="$(date -u +%Y-%m-%d)"
[ -f "$ACCEPTED_FILE" ] || { mkdir -p "$EVIDENCE_DIR"; echo '[]' > "$ACCEPTED_FILE"; }
if ! jq -e 'type == "array"' "$ACCEPTED_FILE" >/dev/null 2>&1; then
  warn "$ACCEPTED_FILE is not a JSON array - FAILING CLOSED."; exit 1
fi

jq --slurpfile acc "$ACCEPTED_FILE" --arg today "$TODAY" '
  [ .[] as $f
    | ($f.category + ":" + $f.location) as $fp
    | ( $acc[0]
        | map(select(.fingerprint == $fp
                     and ((.expires_at // "0000-00-00") >= $today)))
        | first ) as $a
    | $f + { fingerprint: $fp,
             disposition: (if $a then "accepted_false_positive" else "open" end),
             acceptance: (if $a then {justification:$a.justification,
                                      accepted_by:$a.accepted_by,
                                      accepted_at:$a.accepted_at,
                                      expires_at:$a.expires_at} else null end) } ]
' "$ALL_FINDINGS" > "$TMPDIR_SG/disposed.json" || die "failed to apply accepted.json"

BLOCKING="$(jq --argjson sev "$BLOCKING_SEVERITIES" \
  '[.[] | select(.disposition == "open") | select(.severity as $s | $sev | index($s))] | length' \
  "$TMPDIR_SG/disposed.json")"
SUPPRESSED="$(jq '[.[] | select(.disposition == "accepted_false_positive")] | length' "$TMPDIR_SG/disposed.json")"
TOTAL="$(jq 'length' "$TMPDIR_SG/disposed.json")"

if [ "$BLOCKING" -gt 0 ]; then DECISION="fail"; else DECISION="pass"; fi

# ------------------------------------------------ write the evidence record
#
# The record is a git note on the reviewed commit, not a file in the worktree.
# A file cannot work here: the record is produced during pre-push, so it can
# only ever be committed one push later, which leaves the worktree dirty after
# every run and points head_commit at the parent of the commit that carries it.
# A note is written to .git, lands on the exact SHA that was reviewed, and
# travels to the remote on its own ref.
SHORT="$(git rev-parse --short "${HEAD_SHA:-HEAD}" 2>/dev/null || echo unknown)"
NOTE_SHA="$(git rev-parse --verify --quiet "${HEAD_SHA:-HEAD}^{commit}" 2>/dev/null || true)"
RECORD="$TMPDIR_SG/record.json"

jq -n \
  --arg repository "$REPO_NAME" \
  --arg remote "$REMOTE_URL" \
  --arg range "$RANGE" \
  --arg head "${HEAD_SHA:-}" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg devs "$(printf '%s' "$DEV_MODELS" | tr '\n' ',' | sed 's/,$//')" \
  --arg revs "$(printf '%s' "${REVIEWERS_RUN[*]}" | tr ' ' ',')" \
  --arg decision "$DECISION" \
  --arg tool "secgate/1.0" \
  --slurpfile checks "$ALL_CHECKS" \
  --slurpfile findings "$TMPDIR_SG/disposed.json" \
  '{tool:$tool, repository:$repository, remote:$remote, range:$range,
    head_commit:$head, reviewed_at:$at,
    development_model:$devs, review_model:$revs,
    checks_performed:$checks[0], findings:$findings[0], decision:$decision}' \
  > "$RECORD" || die "failed to write evidence record"

[ -n "$NOTE_SHA" ] || die "cannot resolve the reviewed commit - no record possible"

git notes --ref="$NOTES_REF" add -f -F "$RECORD" "$NOTE_SHA" >/dev/null 2>&1 \
  || die "failed to attach the evidence note to ${SHORT}"
EVIDENCE_AT="${NOTES_REF} @ ${SHORT}"

# publishing is best effort: a note that reached .git is already the record,
# and a remote that refuses it must not turn a passing review into a refusal.
if [ -n "$REMOTE_URL" ]; then
  git push --no-verify --quiet origin "${NOTES_REF}:${NOTES_REF}" >/dev/null 2>&1 \
    || warn "evidence note kept locally - publishing to origin failed"
fi

# ------------------------------------------------------------- report
printf '\n' >&2
info "repository : $REPO_NAME"
info "range      : $RANGE"
info "developed  : $(printf '%s' "$DEV_MODELS" | tr '\n' ',' | sed 's/,$//')"
info "reviewed by: ${REVIEWERS_RUN[*]}"
info "findings   : $TOTAL total, $SUPPRESSED accepted, $BLOCKING blocking"
info "evidence   : $EVIDENCE_AT"

if [ "$TOTAL" -gt 0 ]; then
  printf '\n' >&2
  jq -r '.[] | "  [\(.severity|ascii_upcase)] \(.category) @ \(.location)\n      \(.title)\n      fix: \(.remediation)\n      status: \(.disposition)"' \
    "$TMPDIR_SG/disposed.json" >&2
fi
printf '\n' >&2

if [ "$DECISION" = "fail" ]; then
  warn "PUSH BLOCKED - $BLOCKING unresolved critical/high finding(s)."
  warn "Fix them, or record a justified acceptance in"
  warn "  ${ACCEPTED_FILE#"$REPO_ROOT"/}"
  [ "$RECORD_ONLY" -eq 1 ] && exit 0
  exit 1
fi

info "PASS - no unresolved critical or high findings."
info "Read it back with: git log --notes=${NOTES_REF} -1 ${SHORT}"
exit 0
