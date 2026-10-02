#!/usr/bin/env bash
#
# run-acceptance-tests.sh - produces the two evidence artifacts Asana requires:
#   1. a NEGATIVE test: unresolved critical/high findings block the push
#   2. a POSITIVE test: the remediated change passes and can proceed
#
# Runs against a throwaway repo in $TMPDIR. Touches no product repo.
# Uses the REAL reviewers by default. Pass --stub to exercise the plumbing
# without spending model quota.
#
set -uo pipefail
SECGATE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$SECGATE_HOME/sec-review.sh"
OUT="${SECGATE_HOME}/tests/evidence"
STUB=0
[ "${1:-}" = "--stub" ] && STUB=1

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

mkdir -p "$WORK/secgate-acceptance-test"
cd "$WORK/secgate-acceptance-test"
git init -q .; git config user.email secgate@citizengo.org; git config user.name "secgate acceptance"

# ---- baseline -------------------------------------------------------------
mkdir -p app/api/report
cat > app/api/report/route.js <<'BASE'
export const GET = async () => Response.json({ ok: true });
BASE
git add -A; git commit -qm "baseline"
BASE_SHA="$(git rev-parse HEAD)"

# ---- the vulnerable change ------------------------------------------------
cat > app/api/report/route.js <<'VULN'
// Fetches a report from a URL supplied by the caller and returns it verbatim.
export const GET = async (request) => {
  const target = new URL(request.url).searchParams.get("source");
  const upstream = await fetch(target);            // no validation at all
  const body = await upstream.text();
  return new Response(body, { status: upstream.status });
};
VULN
git add -A; git commit -qm "feat: proxy an upstream report

Dev-Model: claude"
VULN_SHA="$(git rev-parse HEAD)"

run_gate() {                       # run_gate <stubfile-or-empty>
  if [ "$STUB" -eq 1 ]; then
    SEC_DEV_MODEL=claude SEC_REVIEWER_CMD="bash $1" "$GATE" --range "${BASE_SHA}..$(git rev-parse HEAD)"
  else
    SEC_DEV_MODEL=claude "$GATE" --range "${BASE_SHA}..$(git rev-parse HEAD)"
  fi
}

echo "=============================================================="
echo " NEGATIVE TEST - a server-side fetch of a caller-supplied URL"
echo "=============================================================="
if [ "$STUB" -eq 1 ]; then
  cat > "$WORK/stub-fail.sh" <<'S'
cat >/dev/null
echo '{"checks_performed":["injection","redirect_ssrf","data_leakage","validation"],"findings":[{"id":"F1","severity":"critical","category":"redirect_ssrf","location":"app/api/report/route.js:GET","title":"Server-side fetch of a caller-controlled URL","rationale":"The source parameter reaches fetch unvalidated, so the server can be made to request internal addresses.","remediation":"Resolve the target against an allowlist of permitted hosts before fetching."}],"verdict":"fail"}'
S
fi
run_gate "$WORK/stub-fail.sh"; NEG=$?
echo ">>> exit $NEG (expected 1 - push blocked)"
git notes --ref=refs/notes/security-reviews show HEAD > "$OUT/negative-test-evidence.json" 2>/dev/null

# ---- the remediated change ------------------------------------------------
cat > app/api/report/route.js <<'FIXED'
const ALLOWED_HOSTS = new Set(["reports.citizengo.org"]);

export const GET = async (request) => {
  const raw = new URL(request.url).searchParams.get("source");
  let target;
  try {
    target = new URL(raw ?? "");
  } catch {
    return Response.json({ error: "invalid_source" }, { status: 400 });
  }
  if (target.protocol !== "https:" || !ALLOWED_HOSTS.has(target.hostname)) {
    return Response.json({ error: "source_not_allowed" }, { status: 400 });
  }
  const upstream = await fetch(target);
  if (!upstream.ok) {
    return Response.json({ error: "upstream_unavailable" }, { status: 502 });
  }
  return Response.json(await upstream.json());
};
FIXED
git add -A; git commit -qm "fix: allowlist the report source and stop echoing upstream bodies

Dev-Model: claude"

echo
echo "=============================================================="
echo " POSITIVE TEST - the same change, remediated"
echo "=============================================================="
if [ "$STUB" -eq 1 ]; then
  cat > "$WORK/stub-pass.sh" <<'S'
cat >/dev/null
echo '{"checks_performed":["injection","redirect_ssrf","data_leakage","validation","configuration"],"findings":[{"id":"F1","severity":"low","category":"validation","location":"app/api/report/route.js:GET","title":"No timeout on the upstream fetch","rationale":"A slow upstream can hold the handler open.","remediation":"Pass an AbortSignal with a timeout."}],"verdict":"pass"}'
S
fi
run_gate "$WORK/stub-pass.sh"; POS=$?
echo ">>> exit $POS (expected 0 - push allowed)"
git notes --ref=refs/notes/security-reviews show HEAD > "$OUT/positive-test-evidence.json" 2>/dev/null

echo
echo "=============================================================="
if [ "$NEG" -eq 1 ] && [ "$POS" -eq 0 ]; then
  echo " ACCEPTANCE: PASS - blocked when unsafe, allowed when remediated"
else
  echo " ACCEPTANCE: FAIL - negative=$NEG (want 1)  positive=$POS (want 0)"
fi
echo " Evidence written to: ${OUT}"
echo "=============================================================="
[ "$NEG" -eq 1 ] && [ "$POS" -eq 0 ]
