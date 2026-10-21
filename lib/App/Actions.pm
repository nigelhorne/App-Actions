package App::Actions;

use strict;
use warnings;
use Carp qw(croak);
use Cwd qw(abs_path);
use File::Spec;

use App::Actions::Check;
use App::Actions::Workflow;
use App::Actions::Runner;

our $VERSION = '0.01';

sub new {
	my ($class, %args) = @_;

	croak 'workflow_file is required' unless defined $args{workflow_file};

    my $workflow_file = abs_path($args{workflow_file});
    croak "Workflow file '$args{workflow_file}' does not exist"
        unless defined $workflow_file && -f $workflow_file;

    my $project_dir = $args{project_dir};
    if (!defined $project_dir) {
        if ($workflow_file =~ m{^(.*)/\.github/workflows/[^/]+$}) {
            $project_dir = $1;
        } else {
            croak 'project_dir is required when the workflow is not inside .github/workflows';
        }
    }
    $project_dir = abs_path($project_dir);
    croak "Project directory '$args{project_dir}' does not exist"
        unless defined $project_dir && -d $project_dir;

    my $workflow = App::Actions::Workflow->load($workflow_file);

    return bless {
        %args,
        workflow_file => $workflow_file,
        project_dir   => $project_dir,
        workflow      => $workflow,
        jobs          => $args{jobs} || [],
    }, $class;
}

sub workflow     { return $_[0]->{workflow} }
sub workflow_file { return $_[0]->{workflow_file} }
sub project_dir  { return $_[0]->{project_dir} }

sub run {
    my ($self, %overrides) = @_;

    return $self->_runner(%overrides)->run;
}

# Probe the environment and prepare the images without starting a job.  The
# result is a hash of exit, summary (the check's report with one record per
# image added) and error, so a caller can print it as text or as JSON.
sub preflight {
    my ($self, %overrides) = @_;

    my $json        = delete $overrides{json};
    my $schema_line = delete $overrides{schema_line};

    return $self->_runner(%overrides)->preflight(
        json        => $json,
        schema_line => $schema_line,
    );
}

# The JSON schema of one of the machine-readable documents, as a hash that a
# caller can print.  The schemas live in the modules that own the documents,
# so the contract is available from an installed distribution rather than only
# from the test directory.
sub json_schema {
    my ($class, $name) = @_;

    croak 'A document name is required' unless defined $name && length $name;

    return App::Actions::Check->json_schema       if $name eq 'check';
    return App::Actions::Runner->json_schema      if $name eq 'preflight';

    croak "Unknown document '$name'; expected check or preflight";
}

sub _runner {
    my ($self, %overrides) = @_;

    my $runner = App::Actions::Runner->new(
        workflow      => $self->{workflow},
        project_dir   => $self->{project_dir},
        jobs          => exists $overrides{jobs} ? $overrides{jobs} : $self->{jobs},
        image         => exists $overrides{image} ? $overrides{image} : $self->{image},
        perl_image    => exists $overrides{perl_image} ? $overrides{perl_image} : $self->{perl_image},
        platform      => exists $overrides{platform} ? $overrides{platform} : $self->{platform},
        user          => exists $overrides{user} ? $overrides{user} : $self->{user},
        env           => exists $overrides{env} ? $overrides{env} : $self->{env},
        secrets       => exists $overrides{secrets} ? $overrides{secrets} : $self->{secrets},
        dry_run       => exists $overrides{dry_run} ? $overrides{dry_run} : $self->{dry_run},
        explain       => exists $overrides{explain} ? $overrides{explain} : $self->{explain},
        verbose       => exists $overrides{verbose} ? $overrides{verbose} : $self->{verbose},
        quiet         => exists $overrides{quiet} ? $overrides{quiet} : $self->{quiet},
        keep          => exists $overrides{keep} ? $overrides{keep} : $self->{keep},
        keep_images   => exists $overrides{keep_images} ? $overrides{keep_images} : $self->{keep_images},
        pull          => exists $overrides{pull} ? $overrides{pull} : $self->{pull},
        no_pull       => exists $overrides{no_pull} ? $overrides{no_pull} : $self->{no_pull},
        strict_actions => exists $overrides{strict_actions} ? $overrides{strict_actions} : $self->{strict_actions},
        skip_check    => exists $overrides{skip_check} ? $overrides{skip_check} : $self->{skip_check},
        pull_concurrency => exists $overrides{pull_concurrency}
            ? $overrides{pull_concurrency}
            : $self->{pull_concurrency},
        docker        => $overrides{docker} || $self->{docker},
        docker_bin    => exists $overrides{docker_bin} ? $overrides{docker_bin} : $self->{docker_bin},
    );

    return $runner;
}

sub list_jobs {
    my ($self, %overrides) = @_;

    my $runner = App::Actions::Runner->new(
        workflow    => $self->{workflow},
        project_dir => $self->{project_dir},
        jobs        => exists $overrides{jobs} ? $overrides{jobs} : $self->{jobs},
        image       => $self->{image},
        perl_image  => $self->{perl_image},
        dry_run     => 1,
        quiet       => 1,
    );

    return $runner->list_jobs;
}

1;

__END__

=head1 NAME

App::Actions - run GitHub Actions workflows locally with Docker

=head1 SYNOPSIS

    use App::Actions;

    my $actions = App::Actions->new(
        workflow_file => "$ENV{HOME}/src/njh/CGI-Info/.github/workflows/perl-ci.yml",
        project_dir   => "$ENV{HOME}/src/njh/CGI-Info",
    );

    exit $actions->run;

=head1 DESCRIPTION

App::Actions runs a GitHub Actions workflow on a local machine using Docker
containers, allowing troublesome issues to be more easily debugged.
It understands the parts of a workflow that are useful for local
testing: jobs, matrix expansion, container images, service containers,
environment files, working directories, shells, and C<if> conditions.

Each job gets a private Docker network, its own service containers, and a
long-lived job container.  Steps are executed in that container with
C<docker exec>, so files and installed modules persist between steps.  A
service must stay up: one that stops, or that a restart policy keeps bringing
back, stops the run with the state and restart count the daemon reports and
the last lines the container printed.  A container the daemon refuses to start
is reported the same way: its message is quoted and the image, entrypoint or
published port it names is called out, because there is nothing of the
container's own to quote.  When a job finishes, its containers and
network are removed; images that this run pulled are removed at the end as
well.  The C<GITHUB_ENV>, C<GITHUB_PATH>,
C<GITHUB_OUTPUT>, C<GITHUB_STATE>, and C<GITHUB_STEP_SUMMARY> files written by
steps are honoured.  If an image has no C<sudo> and the container is running
as root, a small C<sudo> shim is placed on C<PATH> so that steps such as
C<sudo apt update> work locally.

The host may run UNIX or Windows; only the containers are Linux.  Command
output is captured without C<fork> or a piped C<open>, and paths, volumes and
permissions are handled in a platform-neutral way, so the same code and test
suite run on both.  Step scripts, the C<sudo> and C<apt> shims, and
C<event.json> are written with LF line endings, which is what the container's
shell expects.  Arguments are quoted for the Windows command line by
L<App::Actions::Process> itself, because Perl's own Windows quoting gives up
on any argument containing a double quote and the C runtime then splits it at
its spaces.

Run C<action-run check> to diagnose the host before running a workflow.  It
reports the platform, the Docker client and daemon versions, whether the
daemon runs Linux containers, and whether Docker can bind-mount a temporary
directory and the project directory.  Each problem it finds is followed by the
step that fixes it, such as starting Docker Desktop, switching it to Linux
containers, or sharing the drive that holds the project.  See L<action-run>
for the details.

=head1 METHODS

=head2 new

    my $actions = App::Actions->new(
        workflow_file => $path,
        project_dir   => $directory,
        %options,
    );

C<project_dir> may be omitted when the workflow is inside a repository's
C<.github/workflows> directory; the repository root is then used.

Options include C<jobs>, C<image>, C<perl_image>, C<platform>, C<user>, C<env>,
C<secrets>, C<dry_run>, C<explain>, C<verbose>, C<quiet>, C<keep>,
C<keep_images>, C<pull>, C<no_pull>, C<strict_actions>, C<skip_check>,
C<pull_concurrency>, C<docker>, and C<docker_bin>.  C<pull_concurrency> says
how many images may be pulled at the same time; it defaults to
C<ACTION_RUN_PULL_CONCURRENCY> from the environment, and to four when that is
not set or empty.  It must be a positive integer.

C<explain> is a dry run whose output is the containers rather than the Docker
commands: nothing is started and no daemon is contacted, and one block per
container says what it would be told to run, which is how a service that stops
on start-up can be diagnosed without running it.

Before any job starts, the environment is probed exactly as C<action-run>
C<check> does: the daemon must be reachable and run Linux containers, and the
project directory must be readable through a bind mount.  The probe uses the
image the first runnable job will use, so a working setup needs no extra pull.
It says nothing when it passes and prints the full report, with remedies, when
it does not, in which case no container is started.  C<skip_check> starts the
workflow anyway, and is what C<action-run --skip-check> sets.

The images the run needs are then prepared before the first container:
job images, service images and C<docker://> action images, with matrix values
resolved.  A missing image is pulled at that point, so a mistyped image is
reported before any job has started rather than halfway through one.  Local
composite actions are read up front for the same reason, including actions
used inside other actions, so an image named within one is known before its
first step; only an image whose name the run alone can resolve is left until
it is used.  Presence is checked first, then the missing images are pulled
C<pull_concurrency> at a time (four by default), so a wide matrix does not sit
through one download after another; a failure is still reported against the
image and the job, service or action that needed it, whichever pull finished
first.

C<pull> refreshes the images even when they are present locally, and each
image is pulled once per run, however many jobs, services or steps use it: the
check a job makes of its own image reuses what the run has already fetched.

C<docker> and C<docker_bin> name the Docker command.  It may also be a wrapper
script; a wrapper written in Perl is run with the current Perl interpreter, so
it works on Windows too, where the operating system cannot start a shebang
script directly.

=head2 run

    my $exit_code = $actions->run;

Returns 0 for success, 1 when a job fails, and 2 for a usage, Docker, or other
infrastructure error.

=head2 preflight

    my $result = $actions->preflight(%options);

Makes the same checks as a run before its first job, then prepares the images
the selected jobs need, without starting anything.  Returns a hash of C<exit>
(0 or 2), C<summary> and C<error>.  C<summary> is the report
L<App::Actions::Check> produces as data, with an C<images> array added; each
entry is C<< { image, source, status, error } >>, and C<status> is C<pulled>,
C<present>, C<failed>, C<skipped> or C<deferred>.  A deferred entry could not
be named from the values available before the run, because a job has not
produced it yet; it carries C<expression> instead of C<image>, and the job
prepares it with its own values before it starts.  C<summary> also carries
C<schema_version>, which is
L<App::Actions::Runner/preflight_schema_version>; the schema and the
checked-in examples in F<t/fixtures/> are validated in F<t/schema.t>, which
also fails when a key, an enum value or a null variant the schema names
appears in none of them.  With C<json =E<gt> 1> nothing is
printed, so the caller's output can be a single document; C<ready> is then a
JSON boolean and the summary is the document C<action-run preflight --json>
prints, already validated against that schema, so a mismatch dies with an
L<App::Actions::Schema::Invalid|App::Actions::Schema/App::Actions::Schema::Invalid>
exception naming the first key at fault rather than being returned; the
command gives that exit 70.

=head2 json_schema

    my $schema = App::Actions->json_schema('check');
    my $schema = App::Actions->json_schema('preflight');

Returns the JSON schema of one of the machine-readable documents as a hash,
which is what C<action-run schema> prints.  The name is C<check> or
C<preflight>; anything else is an error naming the two that exist.  The
schemas live in L<App::Actions::Check> and L<App::Actions::Runner>, so the
contract is available from an installed distribution.

=head2 list_jobs

Prints one line per expanded job and returns 0.

=head2 workflow

Returns the loaded L<App::Actions::Workflow> object.

=head1 TESTING

The suite runs against a fake Docker command, so it needs neither Docker nor
a daemon:

    prove -l t

One of its tests copies the suite into a temporary directory whose name
contains spaces and runs every test file there again, which is how paths with
spaces are covered on every platform.  The copy is made from F<MANIFEST>, so it
holds exactly what the distribution ships and a test that reads a new file
finds it there as soon as that file is listed.  That doubles the running time;
set C<SPACE_PATH=0> to skip it, or run just that check with
C<prove -l t/space-path.t>.

The repository ships a pre-commit hook in F<.githooks/> that runs the schema
checks against the files a commit stages, so a version bump applied to the
schema or to the documents but not to both is refused where it happens rather
than by CI afterwards.  It is off until a clone asks for it:

    git config core.hooksPath .githooks

A commit that touches nothing which can move a schema version passes without
the checks being run at all, and C<git commit --no-verify> skips it for one
commit.

The tests that need a real Docker daemon sit behind one switch,
C<LIVE_TESTING>: C<make test LIVE_TESTING=1> runs them all.  C<t/real-docker.t>
runs one small workflow end to end with C<action-run check> and the smoke
script, C<t/real-docker-preflight.t> the preflight including an image that
cannot be pulled, and C<t/self_test.t> the command a user runs -
C<bin/action-run t/lib/self_test.yml .> - in a real container rather than the
fake one it uses by default.  One of them on its own is C<LIVE_TESTING=1
prove -l t/real-docker.t>.

The I<Live Docker> workflow sets the switch and runs C<t/self_test.t> on every
push, so the command a user runs is exercised on a daemon in CI rather than
only on a machine that has one.  The two daemon-specific files stay where a
particular daemon is the point: a local C<LIVE_TESTING=1> run, and the
I<Real Docker on Windows> workflow.

The fake Docker executes step scripts with the host's shell, mapping the paths
C<docker exec> was given back to the host, so a step's output and the files it
writes to C<GITHUB_ENV> and C<GITHUB_OUTPUT> are exercised without a daemon.
It runs the command of a C<docker://> action the same way, so what a one-shot
container prints, and the status it exits with, are what the run sees.

The self test runs two workflows the distribution ships: the one above, which
proves the command surface, and F<t/lib/self_test_cli.yml>, which runs
C<action-run schema> and C<action-run validate> inside a Perl image, so the
tool is exercised where it is being tested rather than only from the checkout
that started it.  That image gets the tool's dependencies only when it does
not have them, so the fake run stays off the network.  It is named by digest
rather than by the C<perl:5.38> tag, so the live job pulls the same image
every time instead of whatever that tag points at on the day it runs.  The
test says which half it ran: with C<LIVE_TESTING=1> it reports that the
workflow is in a real container, and without it that the steps ran against the
fake and the container path was not exercised.

The live tests read two variables and both carry the C<LIVE_TESTING>
prefix, so there is one name to remember: C<LIVE_TESTING> turns them on and
C<LIVE_TESTING_IMAGE> names the image they start, C<alpine:3.20> by default.
C<DOCKER> overrides the Docker command.  The daemon must run Linux containers.
C<t/live-knobs.t> holds the tests, the documentation and the workflow to that
prefix, so a rename that misses one of them fails the ordinary suite.
The same ground is covered by C<action-run-smoke>, which does not need C<prove>
and reports the environment before it runs anything; use it when Docker, not
the code, is in doubt.  On Windows it is the check to run against Docker
Desktop, whose Linux engine C<action-run-smoke> verifies before it starts a
container.

The opt-in I<Real Docker on Windows> workflow runs the same test on a Windows
host.  Dispatch it on a self-hosted Windows runner with Docker Desktop, or set
the C<docker_host> input to a Linux daemon.  GitHub-hosted Windows runners
only run Windows containers, so the job stops there with an explanation.

=head1 LIMITATIONS

Only Linux runners can be emulated.  Windows and macOS jobs are skipped.
Local composite and JavaScript actions are run; remote actions and local
C<docker> actions cannot be run.  Checkout, setup-perl, cache, artifact, and
Codecov actions are treated as no-ops.  Use C<strict_actions> to turn unknown
actions into failures instead of skips.  JavaScript actions need C<node> in
the job image.  Job outputs, C<needs.*.outputs>, and C<timeout-minutes> are
not implemented.

Images are pulled concurrently only where C<fork()> is reliable; on Windows
they are pulled one at a time, because Perl's emulation of C<fork()> shares the
parent's handles with the child.

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
