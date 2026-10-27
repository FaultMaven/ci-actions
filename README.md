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
| [`move-branch-tags`](move-branch-tags/action.yml) | Points an image's branch tag, and `latest` for main, at a pushed digest, only while the commit it was built from is still the branch's tip |

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
whatever else the job needs) for the compare. Without it, in a private
repository the first write succeeds, because an empty entry needs no compare,
and every later run of any commit other than the queued one fails at once:
`github-token cannot read <repo>'s commits (…): the calling job needs
permissions: contents: read`.

**The rule.** An entry is replaced only when the run's commit contains the
queued commit. The same commit, or an older one, is skipped with a notice. Each
of these is refused, and nothing is written:
- a diverged commit;
- an entry no commit can be read from;
- a missing queue file;
- an invalid input.

An unanswered compare is retried, never written. A compare GitHub refuses is
not retried, because neither refusal passes: a token without `contents: read`
(403 "Resource not accessible by integration") and a commit the repository
does not hold, or cannot be seen with the token (404), each fail at once with
the cause named. A push rejected by a race
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

## `move-branch-tags`

Call it as the publish job's last step, once the image is pushed. The build
itself pushes only the commit's `sha-` tag, plus any semver tags: give
metadata-action no `latest` or branch tag, and `flavor: latest=false`.

```yaml
- name: Move latest and the branch tag
  if: ${{ !cancelled() && steps.build.outcome == 'success' }}
  uses: FaultMaven/ci-actions/move-branch-tags@<release commit sha> # vX.Y.Z
  with:
    image: ghcr.io/${{ github.repository_owner }}/<image name>
    digest: ${{ steps.build.outputs.digest }}
    sha: <the full commit the image was built from>
```

| Input | Required | Meaning |
|---|---|---|
| `image` | yes | The image repository the build pushed, with no tag or digest. It is lowercased, as metadata-action writes it, so `github.repository_owner` can be passed as it is |
| `digest` | yes | The pushed image's digest (`sha256:<64 hex>`), such as build-push-action's `digest` output |
| `sha` | yes | The full 40-character commit the image was **built from**. Under `workflow_run` that is `github.event.workflow_run.head_sha`, never `github.sha`, which there names the default branch's tip when the run starts: passing it would move the tags to an image of another commit, the bug this action exists to stop |
| `ref` | no | The ref the tags follow. The default is `github.ref`. Only a branch moves anything, and `latest` moves only for `refs/heads/main` |
| `github-token` | no | A token that reads this repository's refs, for the tip lookup. The default is `github.token`, which needs the job's `contents: read` |

| Output | Meaning |
|---|---|
| `moved` | `true` when the tags now name `digest`, otherwise `false` |
| `reason` | `moved`; `not-tip` (the branch has moved on); `not-branch` (the ref is a tag or a pull request); `branch-name` (the name makes no valid tag, such as one starting with `-` or longer than 128 characters, or git would refuse it); `lookup-failed`; `push-failed`; `invalid`; or `stopped` (a command failed unexpectedly) |

**The rule.** Immediately before moving anything, it reads the branch's tip
through the API. Only when the tip is `sha` does it point `<image>:<branch tag>`
at `<image>@<digest>`, and `<image>:latest` too on main. It uses `docker buildx
imagetools create --prefer-index=false`, so a single-manifest image (one with no
attestation) keeps its digest instead of being wrapped in a new index. The
branch tag is named the way metadata-action's `type=ref,event=branch` names it:
each run of characters outside `a-z A-Z 0-9 . _ -` becomes one `-`, so `feat/x`
is `:feat-x` and `fix+retry` is `:fix-retry`. The lookup percent-encodes the
name, so any branch name git allows is read as written.

Read at job start instead, the answer goes stale while the image builds. A
newer commit's publish can move the tags in that time, and the older build's
push then moves them back (FaultMaven/faultmaven#2347). What is left is the few
seconds between the lookup and the push: a registry offers no compare-and-set
on a tag.

The tags follow the tip, not the newest build. While the tip never publishes
(its CI failed, was skipped or was cancelled), they stay on the last tip that
did.

**Moving never fails the step.** The tags are informational: deploys pin `sha-`
tags through the image queue. A red publish would invite a re-run, which pushes
the queued `sha-` tag again under a new digest.
- A failed or hung lookup or push is retried: three attempts, each re-reading
  the tip, each lookup bounded at 30 s and each push at 120 s.
- After that the step passes, with `moved=false` and a `::warning::`. A failed
  push may have moved one of the two tags already: imagetools pushes one tag at
  a time.
- When the rule decides not to move (`not-tip`, `not-branch`), a `::notice::`
  says why.

**An invalid input fails the step,** with an `::error::`. It is a wiring error
that no re-run fixes, and passing it would leave the tags frozen without a sign.

**The job must be logged in to the registry,** with `packages: write` for GHCR,
and have docker buildx on `PATH`, as a job that has just pushed the image does.

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
  `tests/test-setup-js.sh`, `tests/test-lint-workflows.sh`,
  `tests/test-move-branch-tags.sh` and `tests/test-lib-annotate.sh`;
- a `setup-js` job that sets up a fixture `package.json` for real, and a
  `move-branch-tags` job that moves tags in a local registry for real.

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
tests/test-move-branch-tags.sh
tests/test-lib-annotate.sh
```

Each action's test runs its action's script exactly as `action.yml` does. The
queue test runs it against a local bare remote and a stub `gh`; the audit test
against a stub `pnpm`, `timeout` and `sleep`; the move-branch-tags test against
a stub `gh` and `docker`. Nothing reaches GitHub, npm or a registry.
`test-lib-annotate.sh` tests the shared library itself.

### `lib/annotate.sh`

The output helpers every action's script shares. Each script sources it from
its own directory's `../lib`, which a caller's
`uses: FaultMaven/ci-actions/<action>@<sha>` always fetches, since that fetch is
the whole repository; a script that cannot load it still says so. The runner
reads workflow commands from stdout and stderr alike, so:
- a value printed into a workflow command is escaped as GitHub decodes it
  (`%` as `%25`, CR as `%0D`, LF as `%0A`) by `annotate`;
- a value printed anywhere else stays on its line through `flat`;
- a tool's captured stderr is replayed with every line prefixed by the tool's
  name (`log_tool_output`), so no line of it can start a command.
