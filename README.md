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
container's own to quote.  When a job finishes, its containers and network are
removed; the images the run pulled are kept, as the next run's cache, unless
`keep_images` is set to a false value.  The `GITHUB_ENV`, `GITHUB_PATH`,
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

Errors raised by this module, [App::Actions::Workflow](https://metacpan.org/pod/App%3A%3AActions%3A%3AWorkflow) and
[App::Actions::Action](https://metacpan.org/pod/App%3A%3AActions%3A%3AAction) come from the catalogue in [App::Actions::I18N](https://metacpan.org/pod/App%3A%3AActions%3A%3AI18N).
They are in English unless `ACTION_RUN_LANG` names another catalogue
(`fr`, `de` or `zh`).

## Methods

### New

Creates the object that runs one workflow.

#### Arguments

- `workflow_file` - required; the path of the workflow.
- `project_dir` - the repository the workflow runs against.  It may
be omitted when the workflow is inside a repository's `.github/workflows`
directory; the repository root is then used.
- Run options: `jobs`, `image`, `perl_image`, `platform`, `user`,
`env`, `secrets`, `dry_run`, `explain`, `verbose`, `quiet`, `keep`,
`keep_images`, `pull`, `no_pull`, `strict_actions`, `skip_check`,
`pull_concurrency`, `parallel`, `log_dir`, `cache_file`, `docker`, and
`docker_bin`.  Any other key is an error.

`parallel` says how many jobs of one matrix may run at the same time; it is
1 unless it is set, and `action-run` sets it to the number of processors
unless `--parallel` says otherwise.  `pull_concurrency` says how many images
may be pulled at the same time; it defaults to `ACTION_RUN_PULL_CONCURRENCY`
from the environment, and to four when that is not set or empty.  It must be
a positive integer.  `keep_images` defaults to true: the images a run pulls
stay behind as the next run's cache, and a false value removes the ones the
run itself pulled when it finishes.  The kept images are recorded by
[App::Actions::Cache](https://metacpan.org/pod/App%3A%3AActions%3A%3ACache), which is what `action-run cache` lists and
`action-run cache --prune` removes; the record lives in the user's cache
directory, and `cache_file` or `ACTION_RUN_CACHE_FILE` moves it.
`log_dir` says where the per-job logs of a parallel run are kept; it
defaults to `ACTION_RUN_LOG_DIR`, then to `action-run/logs` under that same
cache directory.  `action-run logs` reads that directory, with the sizes and
ages of the logs, `action-run logs --json` prints them, with the clock their
ages are measured from, as a versioned document, and
`action-run logs --prune` removes them.  `--older-than` filters that listing,
and with `--prune` removes only logs at least that old; a log is selected on
its own modification time, so newer logs in the same run stay.

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
script directly.  `docker` may instead be an object with the
[App::Actions::Docker](https://metacpan.org/pod/App%3A%3AActions%3A%3ADocker) interface, which is how the tests run without one.

#### Returns

An `App::Actions` object.

#### Side Effects

Reads and parses the workflow file.

#### Example

```perl
    # The repository root is found from the workflow's path.
    my $actions = App::Actions->new(
            workflow_file => 'project/.github/workflows/ci.yml',
            jobs          => [ 'test' ],
            dry_run       => 1,
    );
```

#### Api Specification

##### Input

```perl
    {
            workflow_file    => { type => 'string', min => 1 },
            project_dir      => { type => 'string', optional => 1 },
            jobs             => { type => 'arrayref', optional => 1 },
            env              => { type => 'hashref', optional => 1 },
            secrets          => { type => 'hashref', optional => 1 },
            docker           => { type => 'object', optional => 1 },
            image            => { type => 'string', optional => 1 },
            perl_image       => { type => 'string', optional => 1 },
            platform         => { type => 'string', optional => 1 },
            user             => { type => 'string', optional => 1 },
            log_dir          => { type => 'string', optional => 1 },
            cache_file       => { type => 'string', optional => 1 },
            docker_bin       => { type => 'string', optional => 1 },
            pull_concurrency => { type => 'string', optional => 1 },
            parallel         => { type => 'string', optional => 1 },
            dry_run          => { type => 'string', optional => 1 },
            explain          => { type => 'string', optional => 1 },
            verbose          => { type => 'string', optional => 1 },
            quiet            => { type => 'string', optional => 1 },
            keep             => { type => 'string', optional => 1 },
            keep_images      => { type => 'string', optional => 1 },
            pull             => { type => 'string', optional => 1 },
            no_pull          => { type => 'string', optional => 1 },
            strict_actions   => { type => 'string', optional => 1 },
            skip_check       => { type => 'string', optional => 1 },
    }
```

##### Output

```perl
    { type => 'object', isa => 'App::Actions' }
```

#### Messages

```
    +-----------------------------------+------------------------------+-------------------------------+
    | Message                           | Meaning                      | Resolution                    |
    +-----------------------------------+------------------------------+-------------------------------+
    | workflow_file is required         | No workflow was named        | Pass workflow_file            |
    | Workflow file 'F' does not exist  | No file at the path          | Check the path                |
    | project_dir is required when the  | The repository root cannot   | Pass project_dir              |
    | workflow is not inside            | be inferred                  |                               |
    | .github/workflows                 |                              |                               |
    | Project directory 'D' does not    | No directory at the path     | Check the path                |
    | exist                             |                              |                               |
    | Invalid arguments to              | An unknown option, or one of | Use the documented options    |
    | App::Actions::new: REASON         | the wrong type               |                               |
    +-----------------------------------+------------------------------+-------------------------------+
```

The messages of ["load" in App::Actions::Workflow](https://metacpan.org/pod/App%3A%3AActions%3A%3AWorkflow#load) apply to the workflow file.

#### Formal Specification

```
    ┌─ New ─────────────────────────────────────────────
    │ ΞFileSystem
    │ workflowFile? : optional PATH
    │ projectDir?   : optional PATH
    │ options?      : OPTION ⇸ VALUE
    │ actions!      : Actions
    ├───────────────────────────────────────────────────
    │ dom options? ⊆ RUNNER_OPTIONS
    │ workflowFile? = ⊥ ⇒ raises WorkflowFileRequired
    │ abs(workflowFile?) ∉ regularFiles ⇒ raises WorkflowFileMissing
    │ projectDir? = ⊥ ∧ abs(workflowFile?) ∉ (PATH ⁀ "/.github/workflows/" ⁀ NAME)
    │     ⇒ raises ProjectDirRequired
    │ let root == (projectDir? ≠ ⊥ ⇒ abs(projectDir?))
    │             ∧ (projectDir? = ⊥ ⇒ repository(abs(workflowFile?)))
    │ root ∉ directories ⇒ raises ProjectDirMissing
    │ actions!.workflow = Workflow.Load(abs(workflowFile?))
    │ actions!.project_dir = root
    │ actions!.options = options?
    └───────────────────────────────────────────────────
```

#### Pseudocode

```
    validate the arguments, refusing unknown options
    refuse a missing workflow_file, then one that does not exist
    take project_dir as given, or the repository root that holds .github/workflows
    refuse a project directory that does not exist
    load the workflow
    return the object holding the paths, the workflow and the options
```

### Workflow, Workflow\_File, Project\_Dir

```perl
    my $workflow = $actions->workflow;         # the App::Actions::Workflow
    my $file     = $actions->workflow_file;    # its absolute path
    my $root     = $actions->project_dir;      # the absolute project directory
```

Read-only accessors.

#### Api Specification

##### Input

```
    {}
```

##### Output

```perl
    workflow:                   { type => 'object', isa => 'App::Actions::Workflow' }
    workflow_file, project_dir: { type => 'string' }
```

#### Messages

None.

#### Example

```
    printf "%s from %s\n", $actions->workflow->name, $actions->project_dir;
```

#### Formal Specification

```
    ┌─ Accessor ────────────────────────────────────────
    │ ΞActions
    │ field? : {workflow, workflow_file, project_dir}
    │ value! : VALUE
    ├───────────────────────────────────────────────────
    │ value! = θActions.field?
    └───────────────────────────────────────────────────
```

### Run

Runs the selected jobs.

#### Arguments

Any of the run options of ["new"](#new), which override the object's for this run
only.

#### Returns

0 for success, 1 when a job fails, and 2 for a usage, Docker, or other
infrastructure error.

#### Side Effects

Starts and removes Docker containers and networks, pulls images, writes the
image cache record and, for a parallel run, the job logs; prints the run's
progress unless `quiet`.

#### Example

```perl
    my $exit = $actions->run(jobs => [ 'lint' ], verbose => 1);
    exit $exit;
```

#### Api Specification

##### Input

The option rules of ["new"](#new), all optional, without `workflow_file` and
`project_dir`.

##### Output

```perl
    { type => 'integer', memberof => [ 0, 1, 2 ] }
```

#### Messages

```
    +--------------------------+-------------------------------+--------------------------------+
    | Message                  | Meaning                       | Resolution                     |
    +--------------------------+-------------------------------+--------------------------------+
    | Invalid arguments to     | An unknown or mistyped        | Use the options of new         |
    | App::Actions::run: R     | override                      |                                |
    +--------------------------+-------------------------------+--------------------------------+
```

Failures of the run itself are printed by [App::Actions::Runner](https://metacpan.org/pod/App%3A%3AActions%3A%3ARunner) and
reported by the exit code rather than raised.

#### Formal Specification

```
    ┌─ Run ─────────────────────────────────────────────
    │ ΞActions
    │ overrides? : OPTION ⇸ VALUE
    │ exit!      : {0, 1, 2}
    ├───────────────────────────────────────────────────
    │ dom overrides? ⊆ RUNNER_OPTIONS
    │ exit! = Runner.Run(options ⊕ overrides?)
    └───────────────────────────────────────────────────
```

### Preflight

Makes the same checks as a run before its first job, then prepares the
images the selected jobs need, without starting anything.

#### Arguments

- `json` - optional; true to print nothing and return the document
`action-run preflight --json` prints.
- `schema_line` - optional; passed to the runner.
- Any run option of ["new"](#new), overriding the object's.

#### Returns

A hash of `exit` (0 or 2), `summary` and `error`.  `summary` is the report
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

#### Side Effects

Contacts the Docker daemon, starts a probe container and pulls images.

#### Example

```perl
    my $result = $actions->preflight(json => 1);
    print JSON::PP->new->canonical->encode($result->{summary}), "\n";
    exit $result->{exit};
```

#### Api Specification

##### Input

The option rules of ["new"](#new), all optional, plus

```perl
    {
            json        => { type => 'string', optional => 1 },
            schema_line => { type => 'string', optional => 1 },
    }
```

##### Output

```perl
    { type => 'hashref' }    # { exit => 0|2, summary => {...}, error => string|undef }
```

#### Messages

```
    +--------------------------+-------------------------------+--------------------------------+
    | Message                  | Meaning                       | Resolution                     |
    +--------------------------+-------------------------------+--------------------------------+
    | Invalid arguments to     | An unknown or mistyped option | Use the options of new         |
    | App::Actions::preflight  |                               |                                |
    | the action-run preflight | The document drifted from its | A bug in this distribution;    |
    | --json document does not | schema (an                    | report it                      |
    | match ...                | App::Actions::Schema::Invalid)|                                |
    +--------------------------+-------------------------------+--------------------------------+
```

#### Formal Specification

```
    ┌─ Preflight ───────────────────────────────────────
    │ ΞActions
    │ overrides? : OPTION ⇸ VALUE
    │ json?      : optional BOOLEAN
    │ result!    : Result
    ├───────────────────────────────────────────────────
    │ dom overrides? ⊆ RUNNER_OPTIONS
    │ result! = Runner.Preflight(options ⊕ overrides?, json?)
    │ result!.exit ∈ {0, 2}
    │ json? ⇒ valid(result!.summary, PreflightSchema)
    └───────────────────────────────────────────────────
```

### Json\_Schema

Returns the JSON schema of one of the machine-readable documents.

#### Arguments

- `$name` - `check`, `preflight`, `cache` or `logs`.

#### Returns

The schema as a hash reference, which is what `action-run schema` prints.
The schemas live in [App::Actions::Check](https://metacpan.org/pod/App%3A%3AActions%3A%3ACheck), [App::Actions::Runner](https://metacpan.org/pod/App%3A%3AActions%3A%3ARunner),
[App::Actions::Cache](https://metacpan.org/pod/App%3A%3AActions%3A%3ACache) and [App::Actions::Logs](https://metacpan.org/pod/App%3A%3AActions%3A%3ALogs), so the contract is
available from an installed distribution.

#### Side Effects

None.

#### Example

```perl
    my $schema = App::Actions->json_schema('check');
    print $schema->{title}, "\n";    # action-run check --json
```

#### Api Specification

##### Input

```perl
    { name => { type => 'string', optional => 1 } }
```

##### Output

```perl
    { type => 'hashref' }
```

#### Messages

```
    +--------------------------+-------------------------------+--------------------------------+
    | Message                  | Meaning                       | Resolution                     |
    +--------------------------+-------------------------------+--------------------------------+
    | A document name is       | The name was undef or empty   | Pass check, preflight, cache   |
    | required                 |                               | or logs                        |
    | Unknown document 'N';    | No such document              | Use one of the names listed    |
    | expected check,          |                               |                                |
    | preflight, cache or logs |                               |                                |
    +--------------------------+-------------------------------+--------------------------------+
```

#### Formal Specification

```
    DOCUMENT ::= check | preflight | cache | logs

    ┌─ JsonSchema ──────────────────────────────────────
    │ name?   : optional STRING
    │ schema! : KEY ⇸ VALUE
    ├───────────────────────────────────────────────────
    │ name? ∈ {⊥, ⟨⟩} ⇒ raises DocumentRequired
    │ name? ∉ DOCUMENT ⇒ raises DocumentUnknown(name?)
    │ name? ∈ DOCUMENT ⇒ schema! = owner(name?).json_schema
    └───────────────────────────────────────────────────
```

### List\_Jobs

Prints one line per expanded job: its id, a tab, and its display name.

#### Arguments

Any of the run options of ["new"](#new).  `dry_run` and `quiet` are always set,
because listing starts nothing and prints only the list.

#### Returns

0.

#### Side Effects

Prints to standard output.

#### Example

```perl
    $actions->list_jobs(jobs => [ 'test' ]);
    # test  test (perl=5.38)
    # test  test (perl=5.40)
```

#### Api Specification

##### Input

The option rules of ["new"](#new), all optional.

##### Output

```perl
    { type => 'integer', memberof => [ 0 ] }
```

#### Messages

```
    +--------------------------+-------------------------------+--------------------------------+
    | Message                  | Meaning                       | Resolution                     |
    +--------------------------+-------------------------------+--------------------------------+
    | Invalid arguments to     | An unknown or mistyped        | Use the options of new         |
    | App::Actions::list_jobs  | override                      |                                |
    +--------------------------+-------------------------------+--------------------------------+
```

#### Formal Specification

```
    ┌─ ListJobs ────────────────────────────────────────
    │ ΞActions
    │ overrides? : OPTION ⇸ VALUE
    │ exit!      : {0}
    ├───────────────────────────────────────────────────
    │ output' = output ⁀ ⟨ j : selected(jobs ⊕ overrides?) • j.base_id ⁀ TAB ⁀ j.display_name ⟩
    │ exit! = 0
    └───────────────────────────────────────────────────
```

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

`t/locales.t` covers the message catalogue: the country-to-language table
for GB, US, FR, DE and CN, and the error paths under the `en_US.UTF-8`,
`de_DE.UTF-8` and `ja_JP.UTF-8` POSIX locales.

The repository ships a pre-commit hook in `.githooks/` that runs the schema
checks and the live-knob check against the files a commit stages, so a version
bump applied to the schema or to the documents but not to both, or a live
test's knob added without its documentation or whitelist, is refused where it
happens rather than by CI afterwards.  Each check starts only when a staged
path can affect it.  It is off until a clone asks for it:

```
    git config core.hooksPath .githooks
```

A commit that touches nothing either check reads passes without a check being
run at all, and `git commit --no-verify` skips it for one commit.

The same checks can be run from the command line without attempting a commit:

```
    make check-staged    # against the index
    make check-worktree  # against the working tree, unstaged edits included
```

`check-worktree` always runs both checks, including files that are not tracked
yet, so a new fixture or live test is not skipped.  Both targets need the
`Makefile` that `perl Makefile.PL` writes.

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
`action-run schema` and `action-run validate` inside a Perl image for every
check and preflight document and every cache and logs fixture, including the
unready, unreachable, uncounted, empty and prune examples, so the tool is
exercised where it is being tested rather than only from the checkout that
started it.  All four sets are discovered from `t/fixtures/check*.json`,
`t/fixtures/preflight*.json`, `t/fixtures/cache*.json` and
`t/fixtures/logs*.json` rather than listed by name, so a new one is validated
without editing the workflow.  That image gets
the tool's dependencies only when it does not have them, so the fake run
stays off the network.  It is named by digest rather than by the
`perl:5.38` tag, so the live job pulls the same image every time instead of
whatever that tag points at on the day it runs.  The test says which half it
ran: with `LIVE_TESTING=1` it reports that the workflow is in a real
container, and without it that the steps ran against the fake and the
container path was not exercised.

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

Design weaknesses that remain:

- [App::Actions::Runner](https://metacpan.org/pod/App%3A%3AActions%3A%3ARunner) is a single 4,000-line class that plans the
run, talks to Docker, interprets steps, runs parallel jobs and writes logs.
Its private methods share state through one hash, so none of those concerns
can be tested or replaced alone.  It should be split, at least into a
planner (what to run), an executor (how to run one step) and a reporter.
- Errors are mostly strings.  Only schema drift has an exception class;
callers such as `bin/action-run` tell other failures apart by matching
their text, which a translation would break.  The catalogue keys are the
natural basis for an exception class carrying a stable code.
- Options are validated twice: their types here and their values in
the runner.  The runner's checks are the ones with the specific messages,
so the two cannot simply be merged without moving those messages.
- Unknown options are now an error.  A caller that passed an option
this module never forwarded (and which therefore had no effect) will now be
told so.
- The Runner, Check, Docker and command-line messages have not been
moved into the catalogue yet; see ["LIMITATIONS" in App::Actions::I18N](https://metacpan.org/pod/App%3A%3AActions%3A%3AI18N#LIMITATIONS).

## Author

Nigel Horne, `<njh at nigelhorne.com>`

## Licence and Copyright

Copyright 2010-2026 Nigel Horne.

Usage is subject to the GPL2 licence terms.
If you use it,
please let me know.
