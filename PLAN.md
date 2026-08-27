# Implementation plan — adversarial pre-push security review

Asana: JR: Operationalize adversarial pre-push security reviews (due Fri 28 Aug 2026)
Owner: Jakub Rejch
Status: plan, not yet built

---

## 1. What we are building

A local gate called **secgate** that runs on `git push`, sends the exact
diff being pushed to the *opposite* model, and refuses the push while any
unaccepted critical or high finding stands.

It is a **new tool**, not an extension of `cross-review.sh`. They answer
different questions:

| | `cross-review.sh` | `secgate` |
|---|---|---|
| Question | is this change good yet? | is this change safe to publish? |
| Shape | implement/review loop, 2+2 rounds | one pass, one verdict |
| Writes code | yes | never |
| Output | reviews and a diff, for a human | a machine-readable record |
| Failure | tells you and stops | blocks the push |

`cross-review.sh` stays as it is. `secgate` borrows its security prompt
checklist and its OAuth-only invocation style, nothing else.

---

## 2. Layout

Tool, kept once, installed into many repos:

```
~/Desktop/agents/secgate/
  sec-review.sh          the control
  hooks/pre-push         thin wrapper that calls sec-review.sh
  install.sh             installs the hook into a target repo
  prompts/security.md    the reviewer prompt (single source of truth)
  README.md              usage + troubleshooting  [required evidence]
  COVERAGE.md            which repos are covered, what is not  [required evidence]
```

Per covered repo, committed:

```
<repo>/.security-reviews/
  accepted.json          accepted false positives, with justification
  2026-08-27TournalT09-14-02Z-a1b2c3d.json   one evidence record per review
```

Diffs and reviewer transcripts are written to `mktemp -d` **outside the
worktree** and deleted on exit. They are never committed and never linger.

---

## 3. Flow

```
git push
  └─ .git/hooks/pre-push
       1. read the ref list from stdin, compute the exact range
       2. resolve which model wrote the code
       3. pick the opposite model as reviewer
       4. dump the range diff to a temp dir outside the repo
       5. run the reviewer read-only, demand strict JSON
       6. parse; unparseable = FAIL
       7. subtract accepted false positives
       8. any unaccepted critical/high  →  exit 1, push blocked
       9. write the sanitized evidence record
```

### 3.1 The exact range

`pre-push` receives `<local_ref> <local_sha> <remote_ref> <remote_sha>` on
stdin. Review `remote_sha..local_sha`. When `remote_sha` is all zeros the
branch is new upstream — fall back to `git rev-list local_sha --not --remotes`
so we review only what is genuinely new, not the whole branch history.

### 3.2 Which model wrote the code

Git does not know this, so it must be declared. Resolution order:

1. `SEC_DEV_MODEL=claude|codex` in the environment
2. `Dev-Model:` commit trailers across the pushed range
   (`git log --format='%(trailers:key=Dev-Model,valueonly)'`)
3. an interactive prompt read from `/dev/tty`
4. nothing found and no tty → **fail closed**, do not guess

If the range contains commits from **both** models, run **both** reviewers
and require both to pass. That is the honest reading of "materially
assisted".

### 3.3 The reviewer call

OAuth only, no API keys, matching the existing setup:

```bash
# reviewer = claude
claude -p "$(cat prompts/security.md)" --model claude-fable-5 \
       --allowedTools Read,Grep,Glob

# reviewer = codex
codex exec --sandbox read-only --ask-for-approval never "$(cat prompts/security.md)"
```

---

## 4. The JSON contract — the heart of it

Free text cannot be gated on. The prompt demands exactly one JSON object:

```json
{
  "checks_performed": ["injection","authz","secrets","ssrf","csrf",
                       "deserialization","logging","dependencies",
                       "validation","configuration"],
  "findings": [
    {
      "id": "F1",
      "severity": "critical",
      "category": "injection",
      "location": "apps/frontend/app/api/admin/login/route.js:POST",
      "title": "User input interpolated into an upstream URL",
      "rationale": "one or two sentences, no code",
      "remediation": "one sentence"
    }
  ],
  "verdict": "fail"
}
```

Three rules baked into the prompt:

- **Never quote source, secrets, tokens or the diff.** Point at
  `file:symbol`. This is what makes the evidence safe to commit, and it is
  cheaper than sanitising afterwards.
- Severity from `critical | high | medium | low | info`.
- `verdict` is `fail` if any finding is critical or high.

**Unparseable output fails the push.** A model that rambles instead of
answering is not a pass. This is the single most important line in the
whole tool — it is what satisfies "a failing review cannot be silently
treated as passing".

---

## 5. Accepted false positives

`.security-reviews/accepted.json`, committed and reviewable:

```json
[
  {
    "fingerprint": "injection:apps/frontend/app/api/admin/login/route.js:POST",
    "severity": "high",
    "justification": "URL is built from a server-side constant, not user input",
    "accepted_by": "jrejch@citizengo.org",
    "accepted_at": "2026-08-27",
    "expires_at": "2026-11-27"
  }
]
```

- Fingerprint = `category:location`. Deliberately not the title, because
  models reword titles between runs.
- Expiry is mandatory, max 90 days. An acceptance that never expires is a
  silenced finding, which is exactly what the task forbids.
- A suppressed finding still appears in the evidence record, marked
  `disposition: "accepted_false_positive"`. It is subtracted from the
  blocking decision, never from the record.

---

## 6. Evidence record

One file per review, metadata only, safe to commit:

```json
{
  "repository": "citizengo-ultra-monorepo",
  "remote": "git@github.com:CitizenGO-Org/citizengo-ultra-monorepo.git",
  "range": "a1b2c3d..e4f5g6h",
  "head_commit": "e4f5g6h",
  "reviewed_at": "2026-08-27T09:14:02Z",
  "development_model": "claude",
  "review_model": "codex",
  "checks_performed": ["..."],
  "findings": [{ "...": "...", "disposition": "remediated|accepted_false_positive|open" }],
  "decision": "pass"
}
```

Maps one-to-one onto the task's required fields: repository, reviewed
commit, development model, independent review model, timestamp, checks,
findings and severity, disposition, final decision.

**Known wrinkle:** the record is produced *during* pre-push, so it is not
inside the commits being pushed. It therefore lands one push behind.
Documented in the README; the alternative (amending commits from a hook)
is worse. `secgate --record-only` regenerates a record without pushing.

---

## 7. The two required tests

Both run in a throwaway repo, not in a product repo.

**Negative — must block.** A route handler that interpolates a query
parameter straight into an upstream URL and echoes an upstream error body
back to the client. Expected: at least one critical or high finding,
`exit 1`, push refused, evidence `decision: "fail"`.

**Positive — must pass.** The same branch with the input validated against
an allowlist and the error body replaced by a fixed message. Expected:
no critical or high findings, `exit 0`, push proceeds, evidence
`decision: "pass"`.

Keep both evidence records. They are two of the five required artifacts.

The third artifact is a real review from a covered repo — take the next
genuine change you push this week.

---

## 8. Two gaps to declare, not hide

**`git push --no-verify` bypasses any client-side hook.** The task demands
that a failing review cannot pass silently, and a local hook is honour
system. Name this in the README and in COVERAGE.md rather than letting a
reviewer find it.

The real fix is a server-side backstop: a GitHub Actions job that, for each
pushed SHA, looks for an evidence record with `decision: "pass"` covering
that commit and fails the check when there is none. Propose it as phase 2
in the Asana comment. It is out of scope for Friday but it is the answer to
the question the task is really asking.

**Two frontier models on every push is slow and burns quota.** Mitigate by
skipping the review when the range touches no code (docs, `.md`, lockfiles
only) and by capping diff size, above which the gate fails closed and asks
for a manual review rather than truncating silently.

---

## 9. Schedule

Today is Tue 25 Aug. Due Fri 28 Aug.

| Day | Deliverable |
|---|---|
| **Tue** | Scaffold the folder. Write `prompts/security.md` with the JSON contract, lifting the checklist from `cross-review.sh`. Run it by hand against a real diff until the JSON comes back clean on both models. |
| **Wed** | `sec-review.sh`: range detection, model resolution, reviewer invocation, `jq` parsing, fail-closed paths, acceptance subtraction, evidence writer. Then `hooks/pre-push` and `install.sh`. |
| **Thu** | Build the throwaway repo, run the negative and positive tests, keep both records. Run one real review on a genuine change. Write `COVERAGE.md` across your 16 Desktop repos. |
| **Fri** | `README.md` with usage and troubleshooting. Install into the repos you own. Post the evidence to Asana and flag the `--no-verify` gap plus the phase-2 proposal. |

The riskiest item is Tuesday's, not Wednesday's. If a model will not
reliably emit clean JSON, everything downstream changes. Prove that first.

---

## 10. Open decisions for you

1. **Which repos count as "yours"?** There are 16 git repos on your Desktop
   plus the monorepo. COVERAGE.md needs a defensible line between covered
   and out of scope.
2. **Evidence in the product repo or in a separate evidence repo?** In-repo
   wins on traceability, which the acceptance criteria mention explicitly.
   Recommended, and assumed above.
3. **Enforce the `Dev-Model:` trailer with a `commit-msg` hook?** More
   reliable, more friction. Suggest starting with the env var plus prompt,
   and adding the trailer hook only if you find yourself answering the
   prompt every time.
