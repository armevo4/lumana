# Secret management

This system handles two secrets with **completely different lifecycles**, and they are
managed differently for that reason. Treating them the same would break one of them.

| | Upstream API key | Database credentials |
|---|---|---|
| Changes | Almost never | Every 60 seconds |
| Source of truth | **GCP Secret Manager** | The rotator CronJob |
| Reaches the pod as | Environment variable | **Mounted file** |
| Synced by | External Secrets Operator | Nothing — written directly |

---

## Why the API key belongs in Secret Manager

A Kubernetes Secret is only base64-encoded, not encrypted. Anyone with `get secrets` in
the namespace can read it, and by default it sits in etcd in the clear. For a long-lived
credential that is not good enough. Secret Manager gives it versioning, IAM-scoped
access, audit logging of every access, and encryption with a key you control.

**But the brief explicitly requires a Kubernetes Secret** ("Create a Kubernetes secret for
the exposed API"), so this is not a choice between the two. The correct pattern uses both:

    GCP Secret Manager  (source of truth, versioned, audited)
            |
            |  External Secrets Operator, authenticating via Workload Identity
            v
    Kubernetes Secret  (what the brief asks for, what the pod consumes)
            |
            v
    api pod  (APP_TMDB_API_KEY via secretKeyRef)

Secret Manager holds the truth; the Kubernetes Secret is a projection of it. The
requirement is satisfied and the secret is properly governed. No service account key file
exists anywhere in this chain — the operator authenticates through Workload Identity.

## Why the database credentials deliberately do NOT work this way

This is the important part, and it is the kind of detail that separates a design from a
diagram.

The rotator patches the `mongodb-app-credentials` Secret every minute. If External Secrets
Operator were also managing that Secret, the two would fight: ESO reconciles on its own
interval, sees the Secret no longer matches Secret Manager, and reverts it. The
application would be handed a credential that had already been rotated away, and the
rotation would appear to randomly fail.

So the rotating credential is **Kubernetes-native and owned by exactly one writer** — the
rotator. Nothing else reconciles it.

The general rule: *a secret can have one owner.* Static secrets are owned by Secret
Manager and projected in. Dynamically rotated secrets are owned by whatever rotates them.
Mixing the two produces a fight that shows up as intermittent, hard-to-debug failures.

## Defence in depth for the rotating credential

Because the database credential does not get Secret Manager's protections, it gets others:

- **A 60-second lifetime.** A leaked credential is worthless almost immediately — far
  stronger than any storage control.
- **Application-layer encryption at rest.** GKE is configured with Cloud KMS envelope
  encryption, so Secrets are encrypted in etcd rather than merely base64-encoded.
- **Tight RBAC.** The rotator's Role is namespaced, pinned to that single Secret by
  `resourceNames`, and limited to `get` and `patch`. It has no `list` or `watch`, which
  would ignore `resourceNames` and expose every Secret in the namespace.
- **No token on the app pod.** The API sets `automountServiceAccountToken: false`; it
  reads the credential from a mounted file and has no Kubernetes API access at all.

## What a larger deployment would do instead

Rotating a shared credential is a good answer for this exercise, but at scale the better
pattern is **dynamic per-workload credentials** — HashiCorp Vault's database secrets
engine, or Secret Manager with a rotation function, issuing a distinct short-lived
credential to each consumer rather than rotating one shared user. Then a leaked credential
identifies its holder, and revocation is per-consumer instead of global.

That was out of scope here: it needs a Vault deployment and would have obscured the
mechanism the brief actually asks to see.

## Local development

Compose uses a gitignored `.env` and a `local/` credential directory, both generated with
random values by `scripts/bootstrap-local.sh`. No secret is ever committed. `.env.example`
documents the variable names with empty values.
