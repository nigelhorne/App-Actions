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
`docker exec`, so files and installed modules persist between steps.  When a
job finishes, its containers and network are removed; images that this run
pulled are removed at the end as well.  The `GITHUB_ENV`, `GITHUB_PATH`,
`GITHUB_OUTPUT`, `GITHUB_STATE`, and `GITHUB_STEP_SUMMARY` files written by
steps are honoured.  If an image has no `sudo` and the container is running
as root, a small `sudo` shim is placed on `PATH` so that steps such as
`sudo apt update` work locally.

The host may run Unix or Windows; only the containers are Linux.  Command
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
`secrets`, `dry_run`, `verbose`, `quiet`, `keep`, `keep_images`,
`pull`, `no_pull`, `strict_actions`, `skip_check`, `docker`, and
`docker_bin`.

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
reported before any job has started rather than halfway through one.

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
spaces are covered on every platform.  That doubles the running time; set
`SPACE_PATH=0` to skip it, or run just that check with
`prove -l t/space-path.t`.

One small workflow can be run against a real Docker daemon instead:

```
REAL_DOCKER=1 prove -l t/real-docker.t
```

`REAL_DOCKER_IMAGE` overrides the image (the default is `alpine:3.20`) and
`DOCKER` overrides the Docker command.  The daemon must run Linux containers.
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

## Author

Nigel Horne, `njh@nigelhorne.com`

## License

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.
