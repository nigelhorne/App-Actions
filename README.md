# App::Actions

Run a GitHub Actions workflow locally with Docker.

`action-run` reads a workflow file and the directory containing the project to
test, then executes the workflow's Linux jobs in containers.  A typical run is:

```sh
action-run ~/src/njh/CGI-Info/.github/workflows/perl-ci.yml ~/src/njh/CGI-Info
```

The project directory is optional when the workflow lives in
`.github/workflows`, because the repository root can be inferred.

## Installation

The distribution uses `ExtUtils::MakeMaker`:

```sh
perl Makefile.PL
make
make test
make install
```

Docker must be installed and the current user must be able to talk to the
Docker daemon.  The code uses the `docker` command, so `DOCKER_HOST` and a
non-default binary work as usual:

```sh
action-run --docker /usr/local/bin/docker ...
```

## What is supported

* Jobs, `needs`, job-level `if`, `continue-on-error`, and `fail-fast`.
  Conditions that do not call a status function get the same implicit
  `success()` that GitHub applies, so `if: runner.os == 'Linux'` is skipped
  after an earlier step fails.
* `strategy.matrix`, including `include` and `exclude`.
* Linux `runs-on` values.  `ubuntu-latest` maps to `ubuntu:latest` and
  `ubuntu-24.04` maps to `ubuntu:24.04` when no job container is declared.
* `jobs.<id>.container` and service containers, including their environment,
  volumes, ports, and `options`.
* Workflow, job, and step `env`; `defaults.run.shell` and
  `defaults.run.working-directory`.
* `GITHUB_ENV`, `GITHUB_PATH`, `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY`, and
  `GITHUB_STATE` files written by steps.
* Common expression syntax: property access, comparisons, `&&`, `||`, `!`,
  `contains()`, `startsWith()`, `endsWith()`, `format()`, `join()`,
  `toJSON()`, `fromJSON()`, `success()`, `failure()`, `always()`, and
  `cancelled()`.
* `actions/checkout` and `shogo82148/actions-setup-perl` as local no-ops.  The
  repository is mounted at `/github/workspace`, and a `setup-perl` step chooses
  a `perl:<version>` image by default.
* `docker://...` actions.
* `actions/cache`, artifact, and Codecov actions as no-ops.
* Local actions (`uses: ./.github/actions/foo`).  Composite actions run their
  steps in the job container, with the `inputs` context, `github.action_path`,
  and `GITHUB_ACTION_PATH` set, and expose their declared `outputs`.  Nested
  local composites work.  JavaScript actions run `runs.pre`, `runs.main`, and
  `runs.post` with `node`, receive their inputs as `INPUT_*` variables, and
  can export variables, `PATH` entries, outputs, and step summaries through the
  usual `GITHUB_*` files.  Post steps run in reverse order when the job ends
  and honour `post-if`.

Each job gets its own Docker network and a long-lived job container.  Steps run
with `docker exec`, so files, build products, and installed modules persist
between steps.  Containers and networks are removed when the job finishes.
Images that this run pulled are removed at the end unless you ask to keep them.

## Options

```text
--job NAME          run only matching job ids or display names (repeatable)
--image IMAGE       fallback image for jobs with no container
--perl-image FORMAT image template for setup-perl (default: perl:%s)
--platform PLATFORM pass --platform to Docker
--user USER[:GROUP] run containers as this user
--env NAME=VALUE    set or override an environment variable (repeatable)
--secret NAME=VALUE make ${{ secrets.NAME }} available (repeatable)
--docker PATH       Docker executable to use (default: docker)
--pull              force an image pull
--no-pull           fail rather than pulling a missing image
--dry-run           print commands and scripts without running them
--list              list expanded jobs and exit
--keep              keep containers, networks, images, and the temp directory
--keep-images       keep pulled images
--strict-actions    fail on unsupported actions instead of skipping them
--verbose           print Docker commands and extra diagnostics
--quiet             suppress progress output
```

Examples:

```sh
# See what the workflow would do, without Docker
action-run --dry-run --verbose .github/workflows/perl-ci.yml .

# Run one matrix job with a specific fallback image
action-run --job test --image perl:5.40 .github/workflows/test.yml .

# Keep the containers around after a failure
action-run --keep .github/workflows/alpine.yml .
```

## Limitations

* Only Linux runners are emulated.  Windows and macOS matrix entries are
  skipped with a message.
* Remote actions, and local actions that use `runs.using: docker`, cannot be
  executed.  They are skipped with a warning; `--strict-actions` turns that
  into a failure.
* JavaScript actions need `node` in the job image; there is no download of a
  Node runtime.  Images such as `node:20` work out of the box.
* `hashFiles()` is not implemented, and `GITHUB_STATE` values are passed from
  `pre` to `main` and `post` within one action only.
* Job outputs, `needs.<job>.outputs`, and `timeout-minutes` are not
  implemented.
* Services are started on a private network.  A job container reaches a
  service by its service id, as on GitHub when the job itself runs in a
  container, rather than through `localhost`.
* Containers run as their image's default user, usually root.  Build products
  written into the mounted project directory may therefore be owned by root.
  Use `--user "$(id -u):$(id -g)"` when that matters, and keep in mind that
  steps which require root may then fail.
* When the image has no `sudo` and the container is running as root, a small
  `sudo` shim is put on `PATH`.  This makes steps such as `sudo apt update`
  work locally.  The shim ignores sudo's user and option flags, because the
  container is already root.  With `--user`, no shim is installed.
* `apt` and `apt-get` are shadowed by tiny shims that add `--yes` to
  installing and removing commands, and `DEBIAN_FRONTEND=noninteractive` is
  set.  Without a terminal, apt would otherwise abort at its "Do you want to
  continue?" prompt instead of installing like a hosted runner does.
* Images pulled by the run are deleted by default.  Use `--keep-images` if you
  want to keep Docker's cache warm between runs.

## Security

Only pass `--secret` values that you are comfortable exposing to the
workflow's containers.  `action-run` redacts secret values from the Docker
commands and dry-run scripts it prints, but it cannot redact output produced
by a program running inside a container.

## Development

```sh
perl Makefile.PL
make
prove -l t
```

The test suite includes a fake Docker executable, so the tests run without a
Docker daemon.  The runner has also been exercised manually against real
Alpine and Perl containers, service containers, cleanup, and failure paths.

## License

GPL.  See [LICENSE](LICENSE).
