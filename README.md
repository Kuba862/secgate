# secgate — adversarial pre-push security review

A local gate that runs on `git push`. It sends the exact diff being pushed to
the **opposite** model, refuses the push while any unaccepted critical or high
finding stands, and writes a sanitized evidence record you can commit.

Claude wrote the code → Codex reviews it. Codex wrote it → Claude reviews it.

---

## Install

Requires `jq`, plus `claude` and `codex` on your PATH, both signed in.

```bash
brew install jq
~/Desktop/agents/secgate/install.sh /path/to/repo [/path/to/another ...]
```

This writes `.git/hooks/pre-push`, creates `.security-reviews/` and seeds an
empty `accepted.json`. An existing pre-push hook is backed up to
`pre-push.pre-secgate.bak`.

Commit `.security-reviews/` — the records are meant to be shared.

---

## Daily use

Nothing to run. Push as usual:

```bash
git push
```

The gate asks which model wrote the code, reviews, and either lets the push
through or stops it. To answer in advance:

```bash
SEC_DEV_MODEL=claude git push
```

Better, record it per commit so the answer is durable and auditable:

```
Add Google sign-in to the admin gate

Dev-Model: claude
```

The gate reads `Dev-Model:` trailers across the pushed range. If commits from
both models are present, **both** reviewers run and both must pass.

### Run it without pushing

```bash
sec-review.sh --staged                # review what is staged
sec-review.sh --range main..HEAD      # review an explicit range
sec-review.sh --range main..HEAD --record-only   # record, never exit non-zero
```

---

## When it blocks you

You get the findings, then a refusal. Two legitimate ways forward.

**Fix the finding.** Preferred. Push again.

**Record it as an accepted false positive.** Add an entry to
`.security-reviews/accepted.json`:

```json
[
  {
    "fingerprint": "redirect_ssrf:app/api/admin/login/route.js:POST",
    "severity": "high",
    "justification": "The URL is a server-side constant, not user input",
    "accepted_by": "jrejch@citizengo.org",
    "accepted_at": "2026-08-25",
    "expires_at": "2026-11-23"
  }
]
```

- `fingerprint` is `category:location`, copied from the reported finding.
  Deliberately not the title — models reword titles between runs.
- `expires_at` is **mandatory**, 90 days maximum. An acceptance that never
  expires is a silenced finding, which is what this control exists to prevent.
  An expired entry stops suppressing and the finding blocks again.
- A suppressed finding still appears in the evidence record, marked
  `accepted_false_positive`. It is subtracted from the decision, never from
  the record.

---

## What gets recorded

`.security-reviews/<UTC-timestamp>-<short-sha>.json`, metadata only:

repository, remote, range, head commit, timestamp, development model, review
model, checks performed, findings with severity and disposition, and the
pass/fail decision.

**No source code, diff hunks, prompts, tokens or credentials are ever
written.** The reviewer prompt forbids quoting code; findings point at
`file:symbol`. Diffs live in a `mktemp` directory outside the worktree and are
deleted when the run ends.

The record is produced *during* pre-push, so it is not inside the commits
being pushed — it lands one push behind. Commit it with your next change. The
alternative, amending commits from a hook, is worse.

---

## Where it fails closed

By design, all of these refuse the push rather than allowing it:

- the reviewer returns anything that is not a JSON object
- the JSON lacks a `findings` array or a `verdict` string
- the reviewer command is missing or exits non-zero
- the development model cannot be determined and there is no terminal to ask
- `accepted.json` is not a JSON array
- the diff cannot be computed
- the diff is larger than `SEC_MAX_DIFF_BYTES` (default 400000)

A review that cannot be read is not a review that passed.

Reviews are skipped, and the push allowed, only when the change contains no
executable code — docs, images and lockfiles alone.

---

## Troubleshooting

**`jq is required`** — `brew install jq`.

**`claude CLI not found` / `codex CLI not found`** — the gate needs both on
PATH because it always calls the opposite one. Check `claude auth status` and
`codex auth status`.

**It asks for the model on every push** — add `Dev-Model:` trailers to your
commits, or export `SEC_DEV_MODEL` in your shell profile for a repo you only
ever drive with one model.

**`did not return parseable JSON`** — the reviewer rambled instead of
answering. Re-run; if it repeats, the prompt in `prompts/security.md` needs
tightening for that model. Do not work around it by bypassing the gate.

**`diff is N bytes, over the limit`** — split the push into smaller pushes, or
raise `SEC_MAX_DIFF_BYTES` deliberately for a one-off large but low-risk
change, and say so in the commit message.

**It is slow** — two frontier models on a large diff takes minutes. Push less
often and in smaller pieces, which is good practice anyway.

**I need to push right now and the gate is broken** — `git push --no-verify`
bypasses it. This is a known and deliberate hole; see below. If you use it,
say so in the PR.

---

## Known limitation: `--no-verify`

Any client-side hook can be bypassed with `git push --no-verify`. This control
is therefore an honour-system gate, not an enforced one. It raises the cost of
skipping a review and makes skipping visible in the evidence trail, but it
cannot prevent a determined bypass.

Real enforcement belongs on the server: a GitHub Actions job that, for each
pushed SHA, looks for an evidence record with `decision: "pass"` covering that
commit and fails the check when there is none. That is the natural phase two
and is tracked as a rollout gap in `COVERAGE.md`.
