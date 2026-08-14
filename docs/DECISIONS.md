# Design Decisions

Every choice below is deliberate. This document records what was decided, what the
alternatives were, and why the alternative was rejected.

The brief named only a handful of tools (Python **or** Node.js, MongoDB **or** RethinkDB,
Docker, Docker Compose, Kubernetes, Kustomize, Ingress, a Kubernetes CronJob, GitHub).
Everything else on this page was our call.

---

## 1. Language: Python 3.12 + FastAPI

The brief allows Python or Node.js.

Python was chosen because the hardest requirement in this task — rotating database
credentials with zero downtime — depends on holding an **explicit, swappable database
client object**. `motor` (the async MongoDB driver) exposes the client lifecycle
directly, so a new connection pool can be built, verified, and swapped in while the old
one drains. FastAPI is async-native, so this happens without blocking request handling,
and it generates OpenAPI docs at `/docs` for free.

*Rejected:* Node.js would have worked equally well. This is a preference, not a
technical necessity, and it is worth saying so plainly.

## 2. Database: MongoDB 7

The brief allows MongoDB or RethinkDB. Three reasons MongoDB wins here, and the third is
the decisive one:

1. RethinkDB is effectively unmaintained — the project has had minimal activity for years.
2. MongoDB's official image is actively maintained and widely understood.
3. **MongoDB supports runtime user management** via `db.updateUser`. The entire rotation
   design depends on being able to change a password on a live database without
   restarting it.

There is a fourth property that makes zero downtime achievable at all: in MongoDB,
changing a user's password **does not terminate existing authenticated connections**.
Already-open pooled connections keep working; only *new* connections need the new
credential. That gives the application a grace period to swap clients on its own terms
rather than being forced into a hard cutover.

## 3. Upstream API: TMDB (The Movie Database)

The brief asks for "any public API that supports text-based queries" and separately asks
for a Kubernetes Secret holding the exposed API's credential.

TMDB satisfies both: it has a text search endpoint (`/search/movie?query=...`) and it
**requires an API key**, which gives the Secret requirement something real to hold. An
API with no key would have made that requirement vacuous.

*Rejected:* Wikipedia's API needs no key, so the Secret would have been theatre.
OpenWeatherMap is the more recognisable demo, but newly issued keys can take hours to
activate — an unacceptable risk on recording day.

## 4. Ingress controller: ingress-nginx

The brief says "install Ingress" but does not say which controller.

`ingress-nginx` behaves **identically on a local kind cluster and on GKE**, which means a
single set of base manifests works across all three environments and the overlays differ
only in hostname. That is what makes it possible to develop the entire solution locally
and treat GKE as nothing more than a different kubectl context.

*Rejected:* GKE's native Ingress (GCE) provisions an L7 load balancer in roughly five
minutes, behaves differently from anything runnable locally, and would have forced the
dev overlay to diverge structurally from staging and production.

## 5. Credential rotation: dual users + mounted Secret + hot client swap

This is the core design decision of the project.

**Two MongoDB users** (`app_a` and `app_b`) alternate. Each minute the CronJob reads which
user is currently active, generates a fresh password for *the other* user, applies it with
`db.updateUser`, and patches the Kubernetes Secret to point at it. A given credential
therefore stays valid for **two full cycles** before it is rotated again.

That overlap is not decoration — it is required. When a Secret is mounted as a volume, the
kubelet propagates changes on its sync loop, which can take **up to 60 seconds**. With a
60-second rotation schedule, propagation and rotation race each other. The two-cycle
overlap guarantees roughly two minutes of validity, so a pod that is slow to notice never
authenticates with a dead password.

**The Secret is mounted as a volume, not injected as environment variables.** Environment
variables are frozen at process start and *cannot* rotate — this is the single most common
mistake on this task.

**The application swaps clients rather than restarting.** On detecting a change it builds a
new client, pings it to confirm the credential works, atomically swaps the active
reference, and closes the old client after a grace delay so in-flight queries finish.
Readiness never flaps, so the Service never removes the pod, so no request fails.

*Rejected:* patching the Secret and running `kubectl rollout restart` every 60 seconds.
It is the obvious approach and it technically "works", but it restarts every pod every
minute forever — pods never reach steady state, and calling that zero downtime is a
stretch. It is worth demonstrating why it was rejected.

### Implementation note: watch the directory, not the file

The kubelet updates mounted Secrets by atomically swapping a `..data` symlink. A watcher
pointed at the individual file will never fire. The watcher must observe the **directory**
and debounce.

## 6. Resolving the env-var / mounted-file tension

Requirement 7 of the brief asks for the database connection to be established **using
environment variables**. Requirement 14 requires credentials to rotate, which environment
variables cannot do. These appear to conflict.

The resolution is a deliberate split:

- **Non-rotating configuration** — Mongo host, port, database name, the connection URL,
  and the server port — comes from **environment variables**, supplied by a ConfigMap that
  Kustomize varies per overlay. This satisfies requirement 7 and also satisfies the
  requirement to control "ports and connection URLs" through Kustomize.
- **Rotating credentials only** — username and password — come from a **mounted Secret**,
  because they must change without a restart.

The application assembles the final connection string from both sources at connect time.

## 7. Clusters: kind (dev) + two GKE Standard zonal clusters (staging, production)

The brief says "three different clusters", so it gets three real clusters rather than three
namespaces. Dev runs on kind locally, which makes the one-minute rotation cycle cheap to
iterate on; staging and production are separate GKE clusters, provisioned by Terraform and
destroyed after the demo.

## 8. Terraform owns cloud, Kustomize owns cluster

Terraform was **not** requested by the brief. It is included because defining the GKE
clusters, Artifact Registry, IAM and Workload Identity Federation as code is the expected
standard for a DevOps role — and because `terraform destroy` makes teardown reliable.

The boundary is strict: **Terraform stops at the cluster boundary.** Everything inside the
cluster is Kustomize. Managing Kubernetes objects with Terraform's Kubernetes provider
alongside Kustomize causes state conflicts and ordering problems, and is a well-known
anti-pattern.

## 9. CI: GitHub Actions with Workload Identity Federation

Also not requested. CI authenticates to GCP via **Workload Identity Federation**, so no
service account JSON key exists anywhere — not in the repo, not in GitHub secrets, not on
a laptop. Each workflow declares a minimal `permissions:` block, and images are tagged
with the commit SHA so a deployment always names an exact, immutable build.

One honest gap: third-party Actions are pinned to **version tags, not commit SHAs**. Tags
are mutable, so a compromised upstream Action could change under a tag that looks
unchanged — SHA pinning is the stricter practice and is what a production pipeline should
use. It is listed here rather than quietly omitted.

## 10. Proving zero downtime: k6

The brief says "strive to zero downtime". Striving is not evidence. A k6 run holding
constant load across five or more rotations, reporting `http_req_failed: 0.00%`, is.

---

## Ambiguities in the brief, and how they were read

Two requirements are genuinely ambiguous. Rather than guess silently, the interpretation
is recorded here.

**"Create a Kubernetes secret for the exposed API."** This is read as *the credential for
the upstream API being proxied* — the TMDB API key. It could alternatively mean
credentials protecting the API this service exposes. The first reading was chosen because
it is the only one that follows from "select any public API" earlier in the brief.

**"Set up a Kubernetes cluster ... configurations for three different clusters."** Read
literally as three distinct clusters, not three namespaces in one. The literal reading was
chosen because it cannot be faulted, and because Kustomize overlays are cluster-agnostic
anyway.
