## Name

App::Actions - run GitHub Actions workflows locally with Docker

## Synopsis

```perl
use App::Actions;

my $actions = App::Actions->new(
    workflow_file => "$ENV{HOME}/src/njh/CGI-Info/.github/workflows/perl-ci.yml",
    project_dir   => "$ENV{HOME}/src/njh/CGI-Info",
);

exit $actions->run;
```

## Description

App::Actions runs a GitHub Actions workflow on a local machine using Docker
containers, allowing troublesome issues to be more easily debugged.
It understands the parts of a workflow that are useful for local
testing: jobs, matrix expansion, container images, service containers,
environment files, working directories, shells, and `if` conditions.

Each job gets a private Docker network, its own service containers, and a
long-lived job container.  Steps are executed in that container with
`docker exec`, so files and installed modules persist between steps.  A
service must stay up: one that stops, or that a restart policy keeps bringing
back, stops the run with the state and restart count the daemon reports and
the last lines the container printed.  A container the daemon refuses to start
is reported the same way: its message is quoted and the image, entrypoint or
published port it names is called out, because there is nothing of the
container's own to quote.  When a job finishes, its containers and
network are removed; images that this run pulled are removed at the end as
well.  The `GITHUB_ENV`, `GITHUB_PATH`,
`GITHUB_OUTPUT`, `GITHUB_STATE`, and `GITHUB_STEP_SUMMARY` files written by
steps are honoured.  If an image has no `sudo` and the container is running
as root, a small `sudo` shim is placed on `PATH` so that steps such as
`sudo apt update` work locally.

The host may run UNIX or Windows; only the containers are Linux.  Command
output is captured without `fork` or a piped `open`, and paths, volumes and
permissions are handled in a platform-neutral way, so the same code and test
suite run on both.  Step scripts, the `sudo` and `apt` shims, and
`event.json` are written with LF line endings, which is what the container's
shell expects.  Arguments are quoted for the Windows command line by
[App::Actions::Process](https://metacpan.org/pod/App%3A%3AActions%3A%3AProcess) itself, because Perl's own Windows quoting gives up
on any argument containing a double quote and the C runtime then splits it at
its spaces.

Run `action-run check` to diagnose the host before running a workflow.  It
reports the platform, the Docker client and daemon versions, whether the
daemon runs Linux containers, and whether Docker can bind-mount a temporary
directory and the project directory.  Each problem it finds is followed by the
step that fixes it, such as starting Docker Desktop, switching it to Linux
containers, or sharing the drive that holds the project.  See [action-run](https://metacpan.org/pod/action-run)
for the details.

## Methods

### New

```perl
my $actions = App::Actions->new(
    workflow_file => $path,
    project_dir   => $directory,
    %options,
);
```

`project_dir` may be omitted when the workflow is inside a repository's
`.github/workflows` directory; the repository root is then used.

Options include `jobs`, `image`, `perl_image`, `platform`, `user`, `env`,
`secrets`, `dry_run`, `explain`, `verbose`, `quiet`, `keep`,
`keep_images`, `pull`, `no_pull`, `strict_actions`, `skip_check`,
`pull_concurrency`, `docker`, and `docker_bin`.  `pull_concurrency` says
how many images may be pulled at the same time; it defaults to
`ACTION_RUN_PULL_CONCURRENCY` from the environment, and to four when that is
not set or empty.  It must be a positive integer.

`explain` is a dry run whose output is the containers rather than the Docker
commands: nothing is started and no daemon is contacted, and one block per
container says what it would be told to run, which is how a service that stops
on start-up can be diagnosed without running it.

Before any job starts, the environment is probed exactly as `action-run`
`check` does: the daemon must be reachable and run Linux containers, and the
project directory must be readable through a bind mount.  The probe uses the
image the first runnable job will use, so a working setup needs no extra pull.
It says nothing when it passes and prints the full report, with remedies, when
it does not, in which case no container is started.  `skip_check` starts the
workflow anyway, and is what `action-run --skip-check` sets.

The images the run needs are then prepared before the first container:
job images, service images and `docker://` action images, with matrix values
resolved.  A missing image is pulled at that point, so a mistyped image is
reported before any job has started rather than halfway through one.  Local
composite actions are read up front for the same reason, including actions
used inside other actions, so an image named within one is known before its
first step; only an image whose name the run alone can resolve is left until
it is used.  Presence is checked first, then the missing images are pulled
`pull_concurrency` at a time (four by default), so a wide matrix does not sit
through one download after another; a failure is still reported against the
image and the job, service or action that needed it, whichever pull finished
first.

`pull` refreshes the images even when they are present locally, and each
image is pulled once per run, however many jobs, services or steps use it: the
check a job makes of its own image reuses what the run has already fetched.

`docker` and `docker_bin` name the Docker command.  It may also be a wrapper
script; a wrapper written in Perl is run with the current Perl interpreter, so
it works on Windows too, where the operating system cannot start a shebang
script directly.

### Run

```perl
my $exit_code = $actions->run;
```

Returns 0 for success, 1 when a job fails, and 2 for a usage, Docker, or other
infrastructure error.

### Preflight

```perl
my $result = $actions->preflight(%options);
```

Makes the same checks as a run before its first job, then prepares the images
the selected jobs need, without starting anything.  Returns a hash of `exit`
(0 or 2), `summary` and `error`.  `summary` is the report
[App::Actions::Check](https://metacpan.org/pod/App%3A%3AActions%3A%3ACheck) produces as data, with an `images` array added; each
entry is `{ image, source, status, error }`, and `status` is `pulled`,
`present`, `failed`, `skipped` or `deferred`.  A deferred entry could not
be named from the values available before the run, because a job has not
produced it yet; it carries `expression` instead of `image`, and the job
prepares it with its own values before it starts.  `summary` also carries
`schema_version`, which is
["preflight\_schema\_version" in App::Actions::Runner](https://metacpan.org/pod/App%3A%3AActions%3A%3ARunner#preflight_schema_version); the schema and the
checked-in examples in `t/fixtures/` are validated in `t/schema.t`, which
also fails when a key, an enum value or a null variant the schema names
appears in none of them.  With `json => 1` nothing is
printed, so the caller's output can be a single document; `ready` is then a
JSON boolean and the summary is the document `action-run preflight --json`
prints, already validated against that schema, so a mismatch dies with an
[App::Actions::Schema::Invalid](https://metacpan.org/pod/App%3A%3AActions%3A%3ASchema#App::Actions::Schema::Invalid)
exception naming the first key at fault rather than being returned; the
command gives that exit 70.

### Json\_Schema

```perl
my $schema = App::Actions->json_schema('check');
my $schema = App::Actions->json_schema('preflight');
```

Returns the JSON schema of one of the machine-readable documents as a hash,
which is what `action-run schema` prints.  The name is `check` or
`preflight`; anything else is an error naming the two that exist.  The
schemas live in [App::Actions::Check](https://metacpan.org/pod/App%3A%3AActions%3A%3ACheck) and [App::Actions::Runner](https://metacpan.org/pod/App%3A%3AActions%3A%3ARunner), so the
contract is available from an installed distribution.

### List\_Jobs

Prints one line per expanded job and returns 0.

### Workflow

Returns the loaded [App::Actions::Workflow](https://metacpan.org/pod/App%3A%3AActions%3A%3AWorkflow) object.

## Testing

The suite runs against a fake Docker command, so it needs neither Docker nor
a daemon:

```
prove -l t
```

One of its tests copies the suite into a temporary directory whose name
contains spaces and runs every test file there again, which is how paths with
spaces are covered on every platform.  The copy is made from `MANIFEST`, so it
holds exactly what the distribution ships and a test that reads a new file
finds it there as soon as that file is listed.  That doubles the running time;
set `SPACE_PATH=0` to skip it, or run just that check with
`prove -l t/space-path.t`.

The repository ships a pre-commit hook in `.githooks/` that runs the schema
checks against the files a commit stages, so a version bump applied to the
schema or to the documents but not to both is refused where it happens rather
than by CI afterwards.  It is off until a clone asks for it:

```
git config core.hooksPath .githooks
```

A commit that touches nothing which can move a schema version passes without
the checks being run at all, and `git commit --no-verify` skips it for one
commit.

The tests that need a real Docker daemon sit behind one switch,
`LIVE_TESTING`: `make test LIVE_TESTING=1` runs them all.  `t/real-docker.t`
runs one small workflow end to end with `action-run check` and the smoke
script, `t/real-docker-preflight.t` the preflight including an image that
cannot be pulled, and `t/self_test.t` the command a user runs -
`bin/action-run t/lib/self_test.yml .` - in a real container rather than the
fake one it uses by default.  One of them on its own is `LIVE_TESTING=1
prove -l t/real-docker.t`.

The _Live Docker_ workflow sets the switch and runs `t/self_test.t` on every
push, so the command a user runs is exercised on a daemon in CI rather than
only on a machine that has one.  The two daemon-specific files stay where a
particular daemon is the point: a local `LIVE_TESTING=1` run, and the
_Real Docker on Windows_ workflow.

The fake Docker executes step scripts with the host's shell, mapping the paths
`docker exec` was given back to the host, so a step's output and the files it
writes to `GITHUB_ENV` and `GITHUB_OUTPUT` are exercised without a daemon.
It runs the command of a `docker://` action the same way, so what a one-shot
container prints, and the status it exits with, are what the run sees.

The self test runs two workflows the distribution ships: the one above, which
proves the command surface, and `t/lib/self_test_cli.yml`, which runs
`action-run schema` and `action-run validate` inside a Perl image, so the
tool is exercised where it is being tested rather than only from the checkout
that started it.  That image gets the tool's dependencies only when it does
not have them, so the fake run stays off the network.  The
test says which half it ran: with `LIVE_TESTING=1` it reports that the
workflow is in a real container, and without it that the steps ran against the
fake and the container path was not exercised.

The live tests read two variables and both carry the `LIVE_TESTING`
prefix, so there is one name to remember: `LIVE_TESTING` turns them on and
`LIVE_TESTING_IMAGE` names the image they start, `alpine:3.20` by default.
`DOCKER` overrides the Docker command.  The daemon must run Linux containers.
`t/live-knobs.t` holds the tests, the documentation and the workflow to that
prefix, so a rename that misses one of them fails the ordinary suite.
The same ground is covered by `action-run-smoke`, which does not need `prove`
and reports the environment before it runs anything; use it when Docker, not
the code, is in doubt.  On Windows it is the check to run against Docker
Desktop, whose Linux engine `action-run-smoke` verifies before it starts a
container.

The opt-in _Real Docker on Windows_ workflow runs the same test on a Windows
host.  Dispatch it on a self-hosted Windows runner with Docker Desktop, or set
the `docker_host` input to a Linux daemon.  GitHub-hosted Windows runners
only run Windows containers, so the job stops there with an explanation.

## Limitations

Only Linux runners can be emulated.  Windows and macOS jobs are skipped.
Local composite and JavaScript actions are run; remote actions and local
`docker` actions cannot be run.  Checkout, setup-perl, cache, artifact, and
Codecov actions are treated as no-ops.  Use `strict_actions` to turn unknown
actions into failures instead of skips.  JavaScript actions need `node` in
the job image.  Job outputs, `needs.*.outputs`, and `timeout-minutes` are
not implemented.

Images are pulled concurrently only where `fork()` is reliable; on Windows
they are pulled one at a time, because Perl's emulation of `fork()` shares the
parent's handles with the child.

## Author

Nigel Horne, `njh@nigelhorne.com`

## License

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.
