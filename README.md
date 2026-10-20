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
containers.  It understands the parts of a workflow that are useful for local
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
suite run on both.  Step scripts, the `sudo` and `apt` shims, and `event.json`
are written with LF line endings, which is what the container's shell expects.
Arguments are quoted for the Windows command line by
[App::Actions::Process](https://metacpan.org/pod/App%3A%3AActions%3A%3AProcess)
itself, because Perl's own Windows quoting gives up on any argument containing
a double quote and the C runtime then splits it at its spaces.

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
`pull`, `no_pull`, `strict_actions`, `skip_check`, `docker`, and `docker_bin`.

Before any job starts, the environment is probed exactly as `action-run check`
does: the daemon must be reachable and run Linux containers, and the project
directory must be readable through a bind mount.  The probe uses the image the
first runnable job will use, so a working setup needs no extra pull.  It says
nothing when it passes and prints the full report, with remedies, when it does
not, in which case no container is started.  `skip_check` (or `--skip-check`
on the command line) starts the workflow anyway.

The images needed by the selected jobs are then prepared: the job container
images, the service container images, and the images of `docker://` actions,
resolved from the matrix where the image is expression-driven.  A missing
image is pulled there and then, before the first container is created, so a
mistyped service image costs a message rather than a half-finished job; an
image whose name cannot be resolved yet is left to the step that uses it.
With `skip_check` the images are pulled when they are first needed.

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

## Checking the environment

```sh
action-run check [directory]
```

Reports the host platform, the Docker client and daemon versions and whether
the daemon runs Linux containers, then proves that Docker can bind-mount a
temporary directory by reading a marker file back from inside a short-lived
container.  The optional directory, which defaults to the current directory,
is mounted read-only and its entry count is compared with the host, which
catches a drive that Docker Desktop has not shared.  `--image` selects the
probe image (default `alpine:3.20`).  The exit status is 0 when the
environment is ready and 2 otherwise.

Every problem is followed by the step that fixes it, using the tools of the
host platform:

```
  problem   the daemon is not reachable; is Docker running and can this user access it?
  remedy    start Docker Desktop and wait until it is running, then try again
  remedy    if the engine will not start, run "wsl --shutdown" and start Docker Desktop again
```

On Windows the remedies name Docker Desktop's own controls: starting it,
switching it to Linux containers, and sharing the drive that holds the
temporary or project directory in Settings > Resources > File sharing.

A CI job that wants to assert on the environment rather than read prose can
ask for JSON:

```sh
action-run check --json | jq -e '.ready and .docker.containers == "linux"'
```

The top-level keys and the keys of `docker` are always present, with `null` for
anything that could not be discovered; each `mounts` entry carries `host`,
`container` and `ok`, and the project entry also carries `entries` and
`expected`.  The exit status is unchanged (0 ready, 2 not):

```json
{
  "ready": true,
  "problems": 0,
  "host": { "os": "linux", "name": "Linux", "perl": "5.40.0", "archname": "x86_64-linux" },
  "docker": { "bin": "docker", "client": "29.9.1", "daemon": "29.9.1", "containers": "linux" },
  "image": "alpine:3.20",
  "mounts": [
    { "host": "/tmp/action-run-check-XXXX", "container": "/action-run-check", "ok": true },
    { "host": "/src/project", "container": "/check-project", "entries": 17, "expected": 17, "ok": true }
  ],
  "issues": [ { "problem": "...", "remedies": [ "..." ] } ]
}
```

## Smoke test

```sh
action-run-smoke
```

Reports the Docker environment exactly as `action-run check` does, then runs
one small workflow against the real daemon: four steps in one container, where
a later step fails unless the `GITHUB_ENV` value and `GITHUB_OUTPUT` written by
earlier steps arrived through the bind mount, and unless the container is
Linux.  `--directory` picks the directory probed for bind mounts (the current
directory by default), `--image` the Linux image (`alpine:3.20`) and `--docker`
the Docker command.  The exit status is 0 when everything works, 1 when the
environment is fine but the workflow failed, and 2 when the environment itself
needs fixing.

On Windows this is the check to run against Docker Desktop:

```bat
C:\> action-run-smoke --directory C:\src\project
```

Docker Desktop must be running the Linux engine, so that
`docker info --format "{{.OSType}}"` reports `linux`; switch it to Linux
containers from the tray icon if it does not.  A failing mount check means the
drive is not shared; see Settings > Resources > File sharing.  Use `--docker`
when Docker is not on `PATH`:

```bat
C:\> action-run-smoke --docker "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
```

## Testing

The suite runs against a fake Docker command, so it needs neither Docker nor
a daemon:

```sh
prove -l t
```

One of its tests copies the suite into a temporary directory whose name
contains spaces and runs every test file there again, which is how paths with
spaces are covered on every platform.  That doubles the running time; set
`SPACE_PATH=0` to skip it:

```sh
SPACE_PATH=0 prove -l t          # Unix
set SPACE_PATH=0 && prove -l t   # Windows
```

The check can also be run on its own:

```sh
prove -l t/space-path.t
```

One small workflow can be run against a real Docker daemon instead:

```sh
REAL_DOCKER=1 prove -l t/real-docker.t
```

`REAL_DOCKER_IMAGE` overrides the image (the default is `alpine:3.20`) and
`DOCKER` overrides the Docker command.  The daemon must run Linux containers.
The same ground is covered by `action-run-smoke`, which does not need `prove`
and reports the environment before it runs anything; use it when Docker, not
the code, is in doubt.

The opt-in *Real Docker on Windows* workflow runs the same test on a Windows
host.  Dispatch it on a self-hosted Windows runner with Docker Desktop, or set
the `docker_host` input to a Linux daemon.  GitHub-hosted Windows runners only
run Windows containers, so the job stops there with an explanation.

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
