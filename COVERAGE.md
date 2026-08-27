# Coverage and rollout gaps

Which repositories are behind the pre-push security gate, and what is not.
Regenerate the inventory with:
`find ~/Desktop -maxdepth 2 -name .git -type d | sed 's|/.git$||'`

## Covered

| Repository | Hook installed | First evidence record |
|---|---|---|
| `citizengo-ultra-monorepo` | ☐ | |
| `data-campaign-copilot` | ☐ | |
| `next` | ☐ | |
| `soft-backend-fastapi` | ☐ | |
| `soft-chat_backend` | ☐ | |
| `soft-chat_frontend` | ☐ | |
| `soft-iterable_redirect` | ☐ | |
| `soft-landing_backend` | ☐ | |
| `soft-landing_docker` | ☐ | |
| `soft-landing_frontend` | ☐ | |
| `soft-meta_webhook_receive_msg` | ☐ | |
| `soft-signature_generator` | ☐ | |
| `soft-twilioConnector_queueSystem` | ☐ | |
| `soft-url_shortcut` | ☐ | |
| `soft-whatsapp_chat` | ☐ | |
| `soft-whatsapp_management_app` | ☐ | |

## Out of scope

| Repository | Why |
|---|---|
| | |

## Rollout gaps

1. **`git push --no-verify` bypasses the gate.** Any client-side hook can be
   skipped. This control raises the cost of skipping a review and makes a skip
   visible in the evidence trail, but it cannot prevent a deliberate bypass.
   *Proposed phase two:* a GitHub Actions job that, for each pushed SHA, looks
   for an evidence record with `decision: "pass"` covering that commit and
   fails the check when there is none. That moves enforcement server-side,
   where it cannot be bypassed locally.

2. **Evidence lands one push behind.** The record is written during pre-push,
   so it is not part of the commits being pushed. It is committed with the
   next change. Amending commits from inside a hook would be worse.

3. **Repositories cloned outside `~/Desktop` are not inventoried.** The list
   above is generated from one directory. A machine-wide sweep is needed
   before claiming full coverage.

4. **Shared repositories are only as covered as their least-equipped
   contributor.** The hook is per-clone, not per-repository. A teammate who
   has not installed it pushes unreviewed. Server-side enforcement fixes this
   too.
