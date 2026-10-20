package App::Actions;

use strict;
use warnings;
use Carp qw(croak);
use Cwd qw(abs_path);
use File::Spec;

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
        verbose       => exists $overrides{verbose} ? $overrides{verbose} : $self->{verbose},
        quiet         => exists $overrides{quiet} ? $overrides{quiet} : $self->{quiet},
        keep          => exists $overrides{keep} ? $overrides{keep} : $self->{keep},
        keep_images   => exists $overrides{keep_images} ? $overrides{keep_images} : $self->{keep_images},
        pull          => exists $overrides{pull} ? $overrides{pull} : $self->{pull},
        no_pull       => exists $overrides{no_pull} ? $overrides{no_pull} : $self->{no_pull},
        strict_actions => exists $overrides{strict_actions} ? $overrides{strict_actions} : $self->{strict_actions},
        skip_check    => exists $overrides{skip_check} ? $overrides{skip_check} : $self->{skip_check},
        docker        => $overrides{docker} || $self->{docker},
        docker_bin    => exists $overrides{docker_bin} ? $overrides{docker_bin} : $self->{docker_bin},
    );

    return $runner->run;
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
C<docker exec>, so files and installed modules persist between steps.  When a
job finishes, its containers and network are removed; images that this run
pulled are removed at the end as well.  The C<GITHUB_ENV>, C<GITHUB_PATH>,
C<GITHUB_OUTPUT>, C<GITHUB_STATE>, and C<GITHUB_STEP_SUMMARY> files written by
steps are honoured.  If an image has no C<sudo> and the container is running
as root, a small C<sudo> shim is placed on C<PATH> so that steps such as
C<sudo apt update> work locally.

The host may run Unix or Windows; only the containers are Linux.  Command
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
C<secrets>, C<dry_run>, C<verbose>, C<quiet>, C<keep>, C<keep_images>,
C<pull>, C<no_pull>, C<strict_actions>, C<skip_check>, C<docker>, and
C<docker_bin>.

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
it is used.

C<docker> and C<docker_bin> name the Docker command.  It may also be a wrapper
script; a wrapper written in Perl is run with the current Perl interpreter, so
it works on Windows too, where the operating system cannot start a shebang
script directly.

=head2 run

    my $exit_code = $actions->run;

Returns 0 for success, 1 when a job fails, and 2 for a usage, Docker, or other
infrastructure error.

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
spaces are covered on every platform.  That doubles the running time; set
C<SPACE_PATH=0> to skip it, or run just that check with
C<prove -l t/space-path.t>.

One small workflow can be run against a real Docker daemon instead:

    REAL_DOCKER=1 prove -l t/real-docker.t

C<REAL_DOCKER_IMAGE> overrides the image (the default is C<alpine:3.20>) and
C<DOCKER> overrides the Docker command.  The daemon must run Linux containers.
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

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
