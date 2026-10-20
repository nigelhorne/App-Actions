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
suite run on both.

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
`pull`, `no_pull`, `strict_actions`, `docker`, and `docker_bin`.

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
