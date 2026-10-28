# ArchScan architecture gate

Fails a pull request that adds a dependency across a service boundary (a new external system, a new
call into another service, or a new Kafka or AMQP edge) and keeps ArchScan's report in one pull request
comment. Scans run in the public ArchScan Docker image; this repository holds only the action.

## Usage

```yaml
name: Architecture gate
on: pull_request
permissions:
  contents: read
  pull-requests: write   # for the comment
jobs:
  archscan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: 21
          cache: gradle   # the base and the head are both built
      - uses: InomjonKadirov/archscan-action@v0
        with:
          build-command: ./gradlew classes
```

The repository needs an `archscan.yaml` (at the root, or name it with `config`). ArchScan's default
`BYTECODE` phase reads compiled classes, so `build-command` builds the base and the head before each
scan (cache the build, as above, to keep the second one fast); with `phase: SOURCE` no build is needed.

## How it works

1. The pull request's base commit is checked out in a git worktree, built with `build-command` and
   scanned.
2. Your checkout is built and scanned, with its own `archscan.yaml` or, under `policy: base`, the base
   commit's.
3. `archscan diff` compares the two snapshots. The policy, the `diff:` block, comes from the pull
   request's own `archscan.yaml`, or from the base commit's with `policy: base`.
4. The report goes to the job summary, and the pull request's comment for this `working-directory`
   and config is kept current.
5. The step fails when the gate finds violations (exit code 1) or anything else goes wrong (2): then
   `gate` is `error`, and the annotation, the job summary and an earlier comment say why.

Scans run in `ghcr.io/inomjonkadirov/archscan` with its own Java 21; your build keeps your JDK. The
first pull request that adds `archscan.yaml` is skipped, since its base has nothing to compare against,
and so is a push that creates a branch.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `config` | `archscan.yaml` | ArchScan's config, relative to `working-directory`. |
| `working-directory` | `.` | The checkout to scan (`actions/checkout`'s `path`). |
| `base` | the pull request's base | The commit to compare against, e.g. `${{ github.event.before }}` on `push` (a push that creates a branch has none and is skipped). |
| `baseline-file` | | A committed `model.json` to compare against instead of scanning `base`, relative to `working-directory`. It is read from the base commit, so a pull request cannot edit its own baseline (from the checkout when there is no base commit). |
| `build-command` | | Runs before each scan, in the head and in the base checkout. |
| `policy` | `head` | Whose `archscan.yaml` sets the gate: `head` (the pull request can add its own allow entry, visible in review) or `base` (an allow entry must merge first, and the base's config also decides what is scanned; a pull request that changes the file gets a warning, and its change takes effect once it merges). |
| `gate` | `config` | `config` follows `diff.gate`, `on` enforces the gate anyway, `off` only reports. |
| `comment` | `on-change` | `on-change` comments when the diff has changes and keeps an earlier comment current, `always` comments on every run, `never` leaves comments alone. Each `working-directory` and config keeps its own comment. |
| `image` | this release's image | The ArchScan image to scan and diff with. |

## Outputs

| Output | Value |
|---|---|
| `gate` | `passed`, `failed`, `disabled`, `skipped` (nothing to compare against yet) or `error` (the step failed; the job summary says why) |
| `exit-code` | The exit code of `archscan diff`: 0 passed or disabled, 1 violations, 2 error, also for a failure of the step itself |
| `report` | Path of the Markdown report |
| `json` | Path of the JSON result |

## The gate

By default a pull request fails when it adds an external system, a call over HTTP or Feign into another
service, or a Kafka or AMQP edge, unless an allow rule accepts it. Everything else is reported, never
fails. The rules live in `archscan.yaml`:

```yaml
diff:
  gate: true
  failOn: [newExternalSystem, newCrossServiceEdge, newAsyncEdge]
  allow:
    - externalSystem: payments-gateway
    - edge: { source: "com.acme.order.*", target: kafka, type: KAFKA_PUBLISH }
```

The report lists the exact `allow` entries that would accept each violation.

## What a pull request can change

With `policy: head` a pull request can accept its own new dependency, through an `allow` entry or a
narrower scan in its `archscan.yaml`, visibly in review. With `policy: base` the base commit's
`archscan.yaml` decides both, and a pull request that changes the file gets a warning: its change takes
effect once it merges, so review it like any policy change (code that a wider scan newly covers then
joins the baseline). `baseline-file` is read from the base commit whenever there is one. The workflow
file and the build come from the pull request too (`build-command` runs its build scripts, whose output
the `BYTECODE` phase reads), so for a gate its author cannot turn off, require code-owner review of
`.github/workflows/` and the build files, and make the job a required status check.

## Pull requests from forks

A `pull_request` workflow gets a read-only token for a fork's pull request. The gate still runs and the
report is in the job summary, but no comment is posted; a warning says so. The action refuses to run
under `pull_request_target`: that event has a write token, and building a pull request's code with it
hands the token to that code.

## Versions

`@v0` follows the latest 0.x release; pin a release such as `@v0.12.0` to keep one ArchScan version.
Each release pins its own image, and `image` overrides it.

## Requirements

A Linux runner with Docker, git, jq and the GitHub CLI; `ubuntu-latest` has all of them.

---

This repository is published by ArchScan's release workflow; changes arrive with ArchScan releases.
