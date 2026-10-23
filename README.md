# FaultMaven CI actions

Composite GitHub Actions shared by FaultMaven's repositories. Before this
repository existed, each repository carried its own copy of the logic here, and
every fix had to be found and made once per copy.

| Action | What it does |
|---|---|
| [`update-image-queue`](update-image-queue/action.yml) | Records a service's new image (`sha-<first 7 of the commit>`) on `faultmaven-enterprise-infra`'s `image-queue` branch, moving the queue only forward |
| [`lockfile-audit`](lockfile-audit/action.yml) | Audits `pnpm-lock.yaml` with `pnpm audit` at moderate and above, retrying only while npm's advisory endpoint is down |
| [`setup-js`](setup-js/action.yml) | Sets up pnpm and Node at the versions the repository's `package.json` declares, then installs the lockfile frozen |
| [`lint-workflows`](lint-workflows/action.yml) | Runs a checksum-verified actionlint, with shellcheck at `-S warning`, over the repository's workflows |

## `update-image-queue`

Call it after the job that pushed the image, on the default branch only:

```yaml
- name: Mint infra token (GitHub App)
  id: infra-token
  if: github.ref == 'refs/heads/main' && github.repository == 'FaultMaven/<repo>'
  uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510 # v3.3.0
  with:
    client-id: ${{ vars.INFRA_BOT_CLIENT_ID }}
    private-key: ${{ secrets.INFRA_BOT_PRIVATE_KEY }}
    owner: ${{ github.repository_owner }}
    repositories: faultmaven-enterprise-infra

- name: Update image queue
  if: github.ref == 'refs/heads/main' && github.repository == 'FaultMaven/<repo>'
  uses: FaultMaven/ci-actions/update-image-queue@<release commit sha> # vX.Y.Z
  with:
    service: <queue file name, e.g. faultmaven-dashboard>
    sha: <the full commit the image was built from>
    token: ${{ steps.infra-token.outputs.token }}
```

| Input | Required | Meaning |
|---|---|---|
| `service` | yes | The queue file's name under `available-images/staging/` (`a-z`, `0-9`, `-`) |
| `sha` | yes | The full 40-character commit the image was built from |
| `token` | yes | An installation token of the `faultmaven-infra-queue-bot` App, scoped to `faultmaven-enterprise-infra` |
| `github-token` | no | A token that reads this repository's commits, for the compare that orders the queue. The default is `github.token`, which needs the job's `contents: read` |
| `path` | no | Where to check out `image-queue`, relative to the workspace. The default is `.image-queue` |

**The caller mints the token**, so the App's private key never reaches this
action. The token can write `image-queue` and open pull requests; no ruleset
lets it bypass `main`.

**The job needs `contents: read`** (`permissions: contents: read` beside
whatever the image push needs) for the compare. Without it, in a private
repository the first write succeeds, because an empty entry needs no compare,
and every later one fails: `the compare … failed: Not Found (HTTP 404)`.

**The rule.** An entry is replaced only when the run's commit contains the
queued commit. The same commit, or an older one, is skipped with a notice. Each
of these is refused, and nothing is written:
- a diverged commit;
- an entry no commit can be read from;
- a missing queue file;
- an invalid input.

An unanswered compare is retried, never written. A push rejected by a race
(another writer moved `image-queue` before or during the push) re-reads
origin's entry and decides again; any other push failure fails the step. Every
refusal of the queue's state ends `GHCR holds <tag> but the queue does not name it.` The tag is always
`sha-<first 7 of sha>`, the image tag every caller pushes: the rule orders an
entry by its commit and refuses one whose tag names another commit.

## `lockfile-audit`

Call it in a checkout of the repository, after pnpm and Node are set up (no
install needed):

```yaml
- name: Audit lockfile
  uses: FaultMaven/ci-actions/lockfile-audit@<release commit sha> # vX.Y.Z
  with:
    on-unreachable: fail   # or warn
```

| Input | Required | Meaning |
|---|---|---|
| `on-unreachable` | yes | `fail` or `warn`: what to do when npm's advisory endpoint stays unreachable after every attempt, so that no audit ran |

Its output `result` is `clean`, `advisories`, `error` or `unreachable`, and every path writes one
job-summary block. An advisory fails the step at once. A transport error, or an answer
whose every HTTP status is 5xx, 408 or 429, is retried: four attempts, 90 seconds each,
20/40/60 seconds apart. Anything else fails at once. A repository's accepted
exceptions are its own `pnpm.auditConfig.ignoreGhsas`.

## `setup-js`

```yaml
- uses: actions/checkout@<sha> # vX
- uses: FaultMaven/ci-actions/setup-js@<release commit sha> # vX.Y.Z
  # with:
  #   install: 'false'   # pnpm and Node only (an audit)
  #   pnpm: 'false'      # Node only, with install: 'false' (a script with no pnpm command)
```

pnpm is the version `package.json`'s `packageManager` names; Node is the major
its `engines.node` names. Neither is ever written in a workflow. With
`install: true` (the default) it runs `pnpm install --frozen-lockfile`, with
pnpm's store cached.

## `lint-workflows`

```yaml
- uses: actions/checkout@<sha> # vX
- uses: FaultMaven/ci-actions/lint-workflows@<release commit sha> # vX.Y.Z
```

Downloads actionlint 1.7.7, refuses it unless it matches the release's
published checksum, and runs it over `.github/workflows/` with shellcheck at
`-S warning`. Note that actionlint checks a *remote* action's `with:` keys and
outputs only for an action pinned by a tag it has a record of; this
repository's own CI calls each of its actions locally so their inputs are
checked here.

## Versions

Releases are semver tags, published as immutable releases. Callers pin the
release's commit by its full sha, with the version in a comment. Their
`github-actions` Dependabot entries then propose upgrades, grouped by update
type like every other action.

## Changes

Every change goes through a pull request. It gets one adversarial review, one
fix commit for that review's findings, and delta reviews of only what changed
since. This repository's CI must be green:
- actionlint, which also checks the action's inputs at a call site;
- shellcheck at `-S warning`;
- `tests/test-update-image-queue.sh`, `tests/test-lockfile-audit.sh`,
  `tests/test-setup-js.sh` and `tests/test-lint-workflows.sh`, plus a
  `setup-js` job that sets up a fixture `package.json` for real.

A new release then reaches each caller as a sha bump, which runs that caller's
CI.

yq (`install-yq.sh`) and actionlint (`lint-workflows`) are release binaries pinned
with their published checksums; Dependabot does not track them, so they are
bumped by hand.

Run the tests locally with git and mikefarah yq v4 on `PATH`:

```bash
tests/test-update-image-queue.sh
tests/test-lockfile-audit.sh
tests/test-setup-js.sh
tests/test-lint-workflows.sh
```

Each runs its action's script exactly as `action.yml` does. The queue test runs
it against a local bare remote and a stub `gh`; the audit test against a stub
`pnpm`, `timeout` and `sleep`. Nothing reaches GitHub or npm.
