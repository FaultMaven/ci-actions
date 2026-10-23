# FaultMaven CI actions

Composite GitHub Actions shared by FaultMaven's repositories. Before this
repository existed, each repository carried its own copy of the logic here, and
every fix had to be found and made once per copy.

| Action | What it does |
|---|---|
| [`update-image-queue`](update-image-queue/action.yml) | Records a service's new image tag on `faultmaven-enterprise-infra`'s `image-queue` branch, moving the queue only forward |

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
| `tag` | no | The image tag to record. Empty means `sha-<first 7 characters of sha>` |
| `token` | yes | An installation token of the `faultmaven-infra-queue-bot` App, scoped to `faultmaven-enterprise-infra` |
| `github-token` | no | A token that reads this repository's commits, for the compare that orders the queue. The default is `github.token` |
| `path` | no | Where to check out `image-queue`, relative to the workspace. The default is `.image-queue` |

**The caller mints the token**, so the App's private key never reaches this
action. The token can write `image-queue` and open pull requests; no ruleset
lets it bypass `main`.

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
red exit ends `GHCR holds <tag> but the queue does not name it.`

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
- `tests/test-update-image-queue.sh`.

A new release then reaches each caller as a sha bump, which runs that caller's
CI.

Run the tests locally with git and mikefarah yq v4 on `PATH`:

```bash
tests/test-update-image-queue.sh
```

They run `update.sh` exactly as `action.yml` does (`bash --noprofile --norc
-eo pipefail`), against a local bare remote and a stub `gh`. Nothing reaches
GitHub.
