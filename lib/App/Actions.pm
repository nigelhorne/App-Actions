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
containers.  It understands the parts of a workflow that are useful for local
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
C<pull>, C<no_pull>, C<strict_actions>, C<docker>, and C<docker_bin>.

=head2 run

    my $exit_code = $actions->run;

Returns 0 for success, 1 when a job fails, and 2 for a usage, Docker, or other
infrastructure error.

=head2 list_jobs

Prints one line per expanded job and returns 0.

=head2 workflow

Returns the loaded L<App::Actions::Workflow> object.

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
