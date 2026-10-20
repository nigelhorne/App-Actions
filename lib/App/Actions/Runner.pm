package App::Actions::Runner;

use strict;
use warnings;
use Carp qw(croak);
use Cwd qw(abs_path);
use File::Basename qw(basename);
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Temp ();
use IO::Handle ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Text::ParseWords qw(shellwords);
use Time::HiRes qw(sleep);

use App::Actions::Action;
use App::Actions::Check;
use App::Actions::Docker;
use App::Actions::Expression;
use App::Actions::Process;

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;

    croak 'A workflow is required' unless $args{workflow};
    croak 'A project directory is required' unless defined $args{project_dir};

    my $project_dir = abs_path($args{project_dir});
    croak "Project directory '$args{project_dir}' does not exist"
        unless defined $project_dir && -d $project_dir;

    my $self = bless {
        workflow      => $args{workflow},
        project_dir   => $project_dir,
        jobs          => $args{jobs} || [],
        image         => $args{image},
        perl_image    => $args{perl_image} || 'perl:%s',
        platform      => $args{platform},
        user          => $args{user},
        env           => $args{env} || {},
        secrets       => $args{secrets} || {},
        dry_run       => $args{dry_run} ? 1 : 0,
        verbose       => $args{verbose} ? 1 : 0,
        quiet         => $args{quiet} ? 1 : 0,
        keep          => $args{keep} ? 1 : 0,
        keep_images   => $args{keep_images} ? 1 : 0,
        pull          => $args{pull} ? 1 : 0,
        no_pull       => $args{no_pull} ? 1 : 0,
        strict_actions => $args{strict_actions} ? 1 : 0,
        skip_check    => $args{skip_check} ? 1 : 0,
        expression    => App::Actions::Expression->new,
        run_id        => sprintf('%x%04x', time, $$ & 0xffff),
        pulled_images => {},
        containers    => [],
        networks      => [],
        summary       => [],
        name_counter  => 0,
        workflow_failed => 0,
        cleaned_up    => 0,
    }, $class;

    if (ref $args{docker}) {
        $self->{docker} = $args{docker};
    } else {
        $self->{docker} = App::Actions::Docker->new(
            bin      => $args{docker_bin},
            dry_run  => $self->{dry_run},
            verbose  => $self->{verbose},
            quiet    => $self->{quiet},
            platform => $self->{platform},
            secrets  => $self->{secrets},
        );
    }

    croak '--pull and --no-pull cannot be used together'
        if $self->{pull} && $self->{no_pull};

    return $self;
}

sub workflow { return $_[0]->{workflow} }

sub list_jobs {
    my ($self) = @_;

    my $instances = $self->{workflow}->expand_jobs;
    $self->_select_jobs($instances);

    for my $instance (@{ $self->{instances} }) {
        print $instance->{base_id}, "\t", $self->_redact($instance->{display_name}), "\n";
    }

    return 0;
}

sub run {
    my ($self) = @_;

    my $exit_code = 0;

    local $SIG{INT}  = sub { die "Interrupted\n" };
    local $SIG{TERM} = sub { die "Terminated\n" };

    eval {
        # Selecting the jobs first means the probes can use the image the run
        # is about to use, so a working setup needs no extra pull.
        my $instances = $self->{workflow}->expand_jobs;
        $self->_select_jobs($instances);

        $self->_check_environment($instances) unless $self->{dry_run};

        $self->_prepare_temp;
        $self->_build_base_env;

        $self->_run_groups;
        $self->_print_summary;

        $exit_code = $self->{workflow_failed} ? 1 : 0;
    };

    if ($@) {
        my $error = $@;
        $error =~ s/\s+$//;
        # Whatever the run printed belongs before the error, even when the two
        # are written through different buffers.
        STDOUT->flush;
        print STDERR "action-run: $error\n" unless $self->{quiet};
        $exit_code = 2;
    }

    $self->_cleanup;

    return $exit_code;
}

# Probe the host before starting anything: the daemon, the container type,
# and a real bind mount of the project directory.  Without this the first
# symptom of an unshared drive or a Windows-only daemon is a job that cannot
# see its own checkout.
sub _check_environment {
    my ($self, $instances) = @_;

    # --skip-check skips the probes, not the question "is Docker there?",
    # because a cryptic failure deeper in the run helps nobody.
    if ($self->{skip_check}) {
        $self->{docker}->check;
        return;
    }

    my $check = App::Actions::Check->new(
        docker_bin => $self->_docker_bin,
        image      => $self->_probe_image($instances),
        platform   => $self->{platform},
        directory  => $self->{project_dir},
        # Silent when everything works, a full report with remedies when not.
        quiet      => $self->{verbose} ? 0 : 1,
    );

    if ($check->run != 0) {
        # die, not croak, and with a trailing newline: the advice should read
        # as a sentence rather than end in " at <file> line <n>".
        die "the environment is not ready; fix what the report above asks for, or pass --skip-check to run anyway\n";
    }

    $self->_prepare_images($instances);
}

# Pull or verify every image the run will need, so that a mistyped service
# image fails now rather than halfway through a job with its containers up.
sub _prepare_images {
    my ($self, $instances) = @_;

    for my $entry ($self->_required_images($instances)) {
        my ($image, $source) = @$entry;

        print "  image     $image ($source)\n" if $self->{verbose} && !$self->{quiet};

        eval { $self->_ensure_image($image); 1 } or do {
            my $error = $@;
            $error =~ s/\s+$//;
            die "cannot prepare the image '$image', needed by $source: $error\n";
        };
    }

    return;
}

# The images of the job containers, of their service containers and of the
# docker:// actions, in the order the run will need them.
sub _required_images {
    my ($self, $instances) = @_;

    my @images;
    my %seen;

    for my $instance (@$instances) {
        my $runs_on = $self->{workflow}->runs_on_text(
            $instance->{'runs-on'}, $instance->{matrix} || {},
        );
        next unless $self->{workflow}->is_linux_runner($runs_on);

        my $name = defined $instance->{display_name}
            ? $instance->{display_name}
            : $instance->{base_id};
        my $context = $self->_preflight_context($instance);

        my $add = sub {
            my ($image, $source) = @_;

            return unless defined $image && length $image;
            return if $seen{$image}++;
            push @images, [ $image, $source ];

            return;
        };

        my $job_image = eval {
            $self->{workflow}->container_image(
                $instance, $runs_on,
                $self->{image} || 'ubuntu:latest',
                $self->{perl_image},
            );
        };
        $add->($job_image, "job '$name'");

        for my $id (sort keys %{ $instance->{services} || {} }) {
            my $service = $instance->{services}{$id};
            $service = { image => $service } unless ref $service eq 'HASH';
            my $image = eval {
                $self->{expression}->interpolate($service->{image}, $context);
            };
            $add->($image, "service '$id' of job '$name'");
        }

        for my $step (@{ $instance->{steps} || [] }) {
            $self->_collect_step_images(
                $step, $name, $context, $add, {}, 0, undef,
            );
        }
    }

    return @images;
}

# Walk one step's `uses`.  A docker:// image is added, and a local composite
# action is read here rather than when the step runs, so that the images in
# its steps are known before the first container exists.
sub _collect_step_images {
    my ($self, $step, $job_name, $context, $add, $ancestors, $depth, $via) = @_;

    return unless defined $step->{uses};

    my $action = eval {
        $self->{expression}->interpolate($step->{uses}, $context);
    };
    return unless defined $action && length $action;

    if ($action =~ m{^docker://(.+)$}) {
        my $source = defined $via
            ? "action '$action' in local action '$via' of job '$job_name'"
            : "action '$action' in job '$job_name'";
        $add->($1, $source);
        return;
    }

    return unless $action =~ m{^\.\.?/};

    # The run refuses to nest composite actions more than ten deep, so the
    # walk stops at the same point instead of descending forever.
    return if $depth >= 10;

    my $relative = eval { $self->_local_action_path($action) };
    return unless defined $relative;

    # An action may use itself, directly or through another one.
    return if $ancestors->{$relative};

    my $host_dir = File::Spec->catdir($self->{project_dir}, split m{/}, $relative);
    return unless -d $host_dir;

    my $loaded = eval { App::Actions::Action->load_from_dir($host_dir) };
    return unless $loaded && $loaded->is_composite;

    # Inputs usually decide the image ("uses: docker://${{ inputs.image }}").
    # A missing required input is the run's error to report, not the
    # preflight's, so it only leaves the image to be discovered at use time.
    my $inputs = eval { $self->_action_inputs($loaded, $step, $action, $context, undef) };
    $inputs = {} unless ref $inputs eq 'HASH';

    my %nested = %$context;
    $nested{inputs} = $inputs;
    $nested{steps}  = {};
    $nested{github} = {
        %{ $context->{github} || {} },
        action_path => "/github/workspace/$relative",
        action      => $action,
    };

    my %deeper = (%$ancestors, $relative => 1);
    for my $nested_step (@{ $loaded->steps || [] }) {
        $self->_collect_step_images(
            $nested_step, $job_name, \%nested, $add, \%deeper, $depth + 1, $action,
        );
    }

    return;
}

# Enough of a context to resolve an image name: matrix values are the reason
# an image is usually expression-driven.  Anything that needs the full run
# context is left alone, and its image is pulled when it is used.
sub _preflight_context {
    my ($self, $instance) = @_;

    return {
        matrix  => $instance->{matrix} || {},
        env     => { %{ $self->{env} || {} } },
        secrets => $self->{secrets} || {},
        vars    => {},
        inputs  => {},
        steps   => {},
        needs   => {},
        job     => {},
        github  => {},
        strategy => {},
        runner  => $self->_runner_context,
    };
}

# Probe with the image the first runnable job will use: it costs no extra pull
# and it exercises the image the run actually needs.
sub _probe_image {
    my ($self, $instances) = @_;

    for my $instance (@$instances) {
        my $runs_on = $self->{workflow}->runs_on_text(
            $instance->{'runs-on'}, $instance->{matrix} || {},
        );
        next unless $self->{workflow}->is_linux_runner($runs_on);

        my $image = eval {
            $self->{workflow}->container_image(
                $instance, $runs_on,
                $self->{image} || 'ubuntu:latest',
                $self->{perl_image},
            );
        };
        next unless defined $image && length $image;

        return $image;
    }

    return $self->{image} || 'alpine:3.20';
}

# The Docker command to probe with; a caller may have supplied its own Docker
# object, which need not expose the binary name.
sub _docker_bin {
    my ($self) = @_;

    my $bin = eval { $self->{docker}->bin };

    return defined $bin && length $bin ? $bin : undef;
}

sub _select_jobs {
    my ($self, $instances) = @_;

    my @filters = @{ $self->{jobs} };
    my @selected;

    if (@filters) {
        my %matched;
        for my $filter (@filters) {
            my $found = 0;
            for my $index (0 .. $#$instances) {
                my $instance = $instances->[$index];
                next unless $instance->{base_id} eq $filter
                    || $instance->{display_name} eq $filter;
                $matched{$index} = 1;
                $found = 1;
            }
            croak "No job matched '$filter'" unless $found;
        }
        @selected = map { $instances->[$_] } sort { $a <=> $b } keys %matched;
    } else {
        @selected = @$instances;
    }

    my %groups;
    my @order;
    my %seen;
    for my $instance (@selected) {
        my $id = $instance->{base_id};
        push @{ $groups{$id} }, $instance;
        push @order, $id unless $seen{$id}++;
    }

    $self->{instances} = \@selected;
    $self->{job_groups} = \%groups;
    $self->{job_order} = \@order;

    return \@selected;
}

# Scripts and other files that the container reads must keep LF line endings.
# On Windows a text-mode handle would write CRLF, and bash rejects a script
# whose lines end in "\r" ("$'\r': command not found").
sub _write_container_file {
    my ($self, $path, $contents, $description) = @_;

    open my $handle, '>', $path
        or croak "Unable to write $description: $!";
    binmode $handle;
    print {$handle} $contents;
    close $handle
        or croak "Unable to write $description: $!";

    return;
}

sub _prepare_temp {
    my ($self) = @_;

    my $temp = File::Temp->newdir('app-actions-XXXXXX', TMPDIR => 1, CLEANUP => 0);
    $self->{tempdir} = $temp;
    $self->{temp_path} = "$temp";

    # The temp directory contains scripts and environment files, which may
    # contain secrets.  Keep it private unless the caller explicitly asked for
    # a different container user.
    my $directory_mode = defined $self->{user} ? 0777 : 0700;
    chmod $directory_mode, $self->{temp_path};

    for my $directory (qw(_temp _tool home scripts env output summary path event bin aptbin)) {
        my $path = "$self->{temp_path}/$directory";
        make_path($path);
        chmod $directory_mode, $path;
    }

    my $sudo = "$self->{temp_path}/bin/sudo";
    my $sudo_shim = <<'SH';
#!/bin/sh
# action-run sudo shim.  The job container is already running as root, so
# privilege escalation is unnecessary.  Ignore the common sudo options.
while [ "$#" -gt 0 ]; do
    case "$1" in
        -E|-H|-n) shift ;;
        -u) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done
exec "$@"
SH
    $self->_write_container_file($sudo, $sudo_shim, 'the sudo shim');
    chmod 0755, $sudo;

    $self->_install_apt_shims;

    return;
}

sub _install_apt_shims {
    my ($self) = @_;

    # GitHub-hosted runners configure apt with assume-yes, so unattended
    # installs work.  Without a terminal, apt aborts at its "Continue?"
    # prompt, which breaks any workflow that runs "apt install" under sudo.
    for my $name (qw(apt apt-get)) {
        my $path = "$self->{temp_path}/aptbin/$name";
        my $shim = <<"SH";
#!/bin/sh
# action-run $name shim: answer "yes" to mutating package commands so
# unattended installs behave like the GitHub-hosted runners.
subcommand=
assume_yes=
for arg in "\$@"; do
    case "\$arg" in
        --) break ;;
        -y|--yes|--assume-yes|-yq|-qy) assume_yes=1 ;;
        -*) ;;
        *) subcommand=\$arg; break ;;
    esac
done
case "\$subcommand" in
    install|remove|purge|upgrade|full-upgrade|dist-upgrade|autoremove|autoclean|build-dep)
        [ -n "\$assume_yes" ] || set -- "\$@" --yes
        ;;
esac
exec /usr/bin/$name "\$@"
SH
        $self->_write_container_file($path, $shim, "the $name shim");
        chmod 0755, $path;
    }

    return;
}

sub _build_base_env {
    my ($self) = @_;

    my $project = $self->{project_dir};
    my $remote = _trim($self->_git('config', '--get', 'remote.origin.url'));
    my $repository;

    if ($remote =~ m{github\.com[:/]([^/]+)/(.+?)(?:\.git)?/?$}) {
        $repository = "$1/$2";
        $repository =~ s/\.git$//;
    } else {
        $repository = basename($project);
    }

    my $branch = _trim($self->_git('symbolic-ref', '--short', '-q', 'HEAD'));
    $branch = 'main' unless length $branch;

    my $sha = _trim($self->_git('rev-parse', 'HEAD'));
    $sha = '0' x 40 unless length $sha;

    my $actor = $ENV{GITHUB_ACTOR} || $ENV{USER} || 'local';
    my $run_id = sprintf('%d%05d', time, $$ % 100000);
    my ($owner) = split m{/}, $repository, 2;
    $owner = $actor unless defined $owner && length $owner;

    my $event = {
        repository => {
            full_name => $repository,
            name      => (split m{/}, $repository)[-1],
            owner     => { login => $owner },
        },
        ref        => "refs/heads/$branch",
        after      => $sha,
        before     => '0' x 40,
        pusher     => { name => $actor },
    };

    my $json = JSON::PP->new->canonical;
    my $event_path = "$self->{temp_path}/event.json";
    $self->_write_container_file($event_path, $json->encode($event), 'event.json');
    chmod(defined $self->{user} ? 0666 : 0600, $event_path);

    $self->{event} = $event;
    $self->{base_env} = {
        CI                    => 'true',
        DEBIAN_FRONTEND       => 'noninteractive',
        GITHUB_ACTIONS        => 'true',
        GITHUB_ACTION         => '',
        GITHUB_ACTOR          => $actor,
        GITHUB_API_URL        => 'https://api.github.com',
        GITHUB_BASE_REF       => '',
        GITHUB_ENV            => '',
        GITHUB_EVENT_NAME     => 'push',
        GITHUB_EVENT_PATH     => '/github/actions-runner/event.json',
        GITHUB_GRAPHQL_URL    => 'https://api.github.com/graphql',
        GITHUB_HEAD_REF       => '',
        GITHUB_JOB            => '',
        GITHUB_OUTPUT         => '',
        GITHUB_PATH           => '',
        GITHUB_REF            => "refs/heads/$branch",
        GITHUB_REF_NAME       => $branch,
        GITHUB_REF_TYPE       => 'branch',
        GITHUB_REPOSITORY     => $repository,
        GITHUB_REPOSITORY_OWNER => $owner,
        GITHUB_RUN_ATTEMPT    => '1',
        GITHUB_RUN_ID         => $run_id,
        GITHUB_RUN_NUMBER     => '1',
        GITHUB_SERVER_URL     => 'https://github.com',
        GITHUB_SHA            => $sha,
        GITHUB_STATE          => '',
        GITHUB_STEP_SUMMARY   => '',
        GITHUB_TOKEN          => '',
        GITHUB_WORKFLOW       => $self->{workflow}->name,
        GITHUB_WORKSPACE      => '/github/workspace',
        HOME                  => defined $self->{user} ? '/github/actions-runner/home' : '/root',
        RUNNER_ARCH           => 'X64',
        RUNNER_NAME           => 'local',
        RUNNER_OS             => 'Linux',
        RUNNER_TEMP           => '/github/actions-runner/_temp',
        RUNNER_TOOL_CACHE     => '/github/actions-runner/_tool',
        RUNNER_WORKSPACE      => '/github',
    };

    if ($self->{verbose}) {
        $self->{base_env}{RUNNER_DEBUG} = '1';
        $self->{base_env}{ACTIONS_STEP_DEBUG} = 'true';
    }

    return;
}

sub _git {
    my ($self, @args) = @_;

    # Not fork() plus a piped open, which Windows does not reliably support.
    my ($output) = App::Actions::Process::capture(
        [ 'git', '-C', $self->{project_dir}, @args ],
        quiet_stderr => 1,
    );

    return defined $output ? $output : '';
}

sub _run_groups {
    my ($self) = @_;

    my %results;
    my %visited;
    my %running;

    for my $base_id (@{ $self->{job_order} }) {
        $self->_run_base_job($base_id, \%results, \%visited, \%running);
    }

    return \%results;
}

sub _run_base_job {
    my ($self, $base_id, $results, $visited, $running) = @_;

    return $results->{$base_id} if $visited->{$base_id};
    croak "Dependency cycle involving job '$base_id'" if $running->{$base_id};

    my $instances = $self->{job_groups}{$base_id};
    croak "Unknown job '$base_id'" unless $instances && @$instances;

    $running->{$base_id} = 1;

    my @needs = @{ $instances->[0]{needs} || [] };
    for my $need (@needs) {
        next unless exists $self->{job_groups}{$need};
        $self->_run_base_job($need, $results, $visited, $running);
    }

    my %need_results;
    for my $need (@needs) {
        if (exists $results->{$need}) {
            $need_results{$need} = $results->{$need};
        } else {
            print STDERR "action-run: job '$base_id' needs '$need', which was not selected; assuming it succeeded\n"
                unless $self->{quiet};
            $need_results{$need} = { result => 'success', outputs => {} };
        }
    }

    my $needs_failed = 0;
    for my $need (keys %need_results) {
        $needs_failed = 1 if $need_results{$need}{result} ne 'success';
    }

    my $fail_fast = 1;
    if (exists $instances->[0]{strategy}{'fail-fast'}) {
        $fail_fast = _truthy_scalar($instances->[0]{strategy}{'fail-fast'});
    }

    my $group_result = 'skipped';
    my $skipped_remaining = 0;

    for my $instance (@$instances) {
        my $matrix = $instance->{matrix} || {};
        my $display_name = $self->_redact($instance->{display_name});
        my $github = $self->_github_context($instance);
        my $strategy = {
            'fail-fast'   => $fail_fast,
            'job-index'   => $instance->{matrix_index},
            'job-total'   => $instance->{matrix_total},
            'max-parallel' => $instance->{strategy}{'max-parallel'},
        };
        my $context = {
            github   => $github,
            matrix   => $matrix,
            needs    => \%need_results,
            secrets  => $self->{secrets},
            vars     => {},
            inputs   => {},
            runner   => $self->_runner_context,
            strategy => $strategy,
            env      => {},
            job      => { status => $needs_failed ? 'failure' : 'success' },
            steps    => {},
        };
        my $status = {
            success   => $needs_failed ? 0 : 1,
            failure   => $needs_failed ? 1 : 0,
            cancelled => 0,
        };

        my $should_run;
        if (defined $instance->{if}) {
            my $condition = eval {
                $self->{expression}->condition($instance->{if}, $context, $status);
            };
            if ($@) {
                my $error = $@;
                $error =~ s/\s+$//;
                print STDERR "action-run: unable to evaluate if for '$display_name': $error\n"
                    unless $self->{quiet};
                $group_result = 'failure';
                $self->{workflow_failed} = 1;
                push @{ $self->{summary} }, {
                    name   => $instance->{display_name},
                    result => 'failure',
                };
                next;
            }
            $should_run = $condition;
            # An `if` without a status function gets an implicit success().
            $should_run = 0 if $should_run && $needs_failed
                && !_has_status_function($instance->{if});
        } else {
            $should_run = $needs_failed ? 0 : 1;
        }

        if (!$should_run) {
            print "==> Job: $display_name (skipped)\n"
                unless $self->{quiet};
            push @{ $self->{summary} }, {
                name   => $instance->{display_name},
                result => 'skipped',
            };
            next;
        }

        if ($skipped_remaining) {
            print "==> Job: $display_name (skipped by fail-fast)\n"
                unless $self->{quiet};
            push @{ $self->{summary} }, {
                name   => $instance->{display_name},
                result => 'skipped',
            };
            next;
        }

        $instance->{needs_results} = \%need_results;
        $instance->{context} = $context;

        my $result = $self->_run_instance($instance, $context);

        my $continue_on_error = 0;
        if (defined $instance->{'continue-on-error'}) {
            $continue_on_error = eval {
                $self->_boolean_value(
                    $instance->{'continue-on-error'},
                    $context,
                    { success => 1, failure => 0, cancelled => 0 },
                );
            };
            if ($@) {
                my $error = $@;
                $error =~ s/\s+$//;
                print STDERR "action-run: unable to evaluate continue-on-error for '$display_name': $error\n"
                    unless $self->{quiet};
            }
        }

        if ($result->{result} eq 'failure') {
            $group_result = 'failure';
            if ($continue_on_error) {
                print "!! Job failed but continue-on-error is set: $display_name\n"
                    unless $self->{quiet};
            } else {
                $self->{workflow_failed} = 1;
            }
            $skipped_remaining = 1 if $fail_fast;
        } elsif ($result->{result} eq 'success') {
            $group_result = 'success' if $group_result eq 'skipped';
        }

        push @{ $self->{summary} }, {
            name   => $instance->{display_name},
            result => $result->{result},
        };
    }

    my $entry = {
        result   => $group_result,
        outputs  => {},
        instances => $instances,
    };
    $results->{$base_id} = $entry;
    $visited->{$base_id} = 1;
    delete $running->{$base_id};

    return $entry;
}

sub _run_instance {
    my ($self, $job, $context) = @_;

    my $matrix = $job->{matrix} || {};
    my $display_name = $self->_redact($job->{display_name});
    my $runs_on = $self->{workflow}->runs_on_text($job->{'runs-on'}, $matrix);

    if (!$self->{workflow}->is_linux_runner($runs_on)) {
        print "==> Job: $display_name (skipped: runs-on '$runs_on' is not Linux)\n"
            unless $self->{quiet};
        return { result => 'skipped', reason => "unsupported runner: $runs_on" };
    }

    my $image = $self->{workflow}->container_image(
        $job,
        $runs_on,
        $self->{image} || 'ubuntu:latest',
        $self->{perl_image},
    );

    if (!defined $image || $image =~ /^\s*$/) {
        croak "Unable to determine a container image for job '$display_name'";
    }

    print "\n==> Job: $display_name\n" unless $self->{quiet};
    print "    image: $image\n" unless $self->{quiet};

    $self->_ensure_image($image);

    my $network = $self->_resource_name('net', $job);
    my @containers;

    my $result;
    my $error;

    eval {
        my $rc = $self->{docker}->network_create($network);
        if ($rc != 0) {
            die "Failed to create Docker network '$network' (exit $rc)\n";
        }
        push @{ $self->{networks} }, $network;

        $self->_start_services($job, $network, $context, \@containers);

        my $job_env = $self->_resolve_env(
            [
                $self->{base_env},
                $self->{workflow}->env,
                $job->{env},
                (ref $job->{container} eq 'HASH' ? $job->{container}{env} : undef),
                $self->{env},
            ],
            $context,
        );

        $job_env->{GITHUB_JOB} = $job->{base_id};
        $job_env->{GITHUB_WORKSPACE} = '/github/workspace';

        my $container = $self->_start_job_container($job, $network, $job_env, $context);
        push @containers, $container;
        push @{ $self->{containers} }, $container;

        my ($base_path, $has_bash, $has_node) = $self->_inspect_container($container);

        $result = $self->_execute_steps(
            $job, $container, $network, $base_path, $has_bash, $has_node, $job_env, $context,
        );
    };
    $error = $@;

    $self->_cleanup_job($network, \@containers);

    die $error if $error;

    return $result || { result => 'failure', reason => 'job did not run' };
}

sub _start_services {
    my ($self, $job, $network, $context, $containers) = @_;

    my $services = $job->{services} || {};
    return unless %$services;

    for my $id (sort keys %$services) {
        my $service = $services->{$id};
        $service = { image => $service } unless ref $service eq 'HASH';
        croak "Service '$id' must be a mapping" unless ref $service eq 'HASH';

        my $image = $service->{image};
        croak "Service '$id' has no image" unless defined $image && length $image;
        $image = $self->{expression}->interpolate($image, $context);

        $self->_ensure_image($image);

        my $name = $self->_resource_name('svc', $job, $id);
        my $service_env = $self->_resolve_env([$service->{env}], $context);

    my @args = ($self->_platform_args);

    if (defined $service->{options}) {
        my $options = $self->{expression}->interpolate("$service->{options}", $context);
        push @args, shellwords($options);
    }

    push @args, '--name', $name;
    push @args, '--network', $network;
    push @args, '--network-alias', $id;

    if (defined $self->{user}) {
        push @args, '--user', $self->{user};
    }

        for my $volume (@{ _as_array($service->{volumes}) }) {
            my $value = $self->{expression}->interpolate("$volume", $context);
            push @args, '-v', $value;
        }

        for my $key (sort keys %$service_env) {
            push @args, '-e', "$key=$service_env->{$key}";
        }

        for my $port (@{ _as_array($service->{ports}) }) {
            my $value = $self->{expression}->interpolate("$port", $context);
            push @args, '-p', $value;
        }

        if (defined $service->{credentials}) {
            print STDERR "action-run: service '$id' credentials are not supported; using the local Docker login\n"
                unless $self->{quiet};
        }

        push @args, $image;

        my $rc = $self->{docker}->container_start(@args);
        push @{ $self->{containers} }, $name;
        push @$containers, $name;

        if ($rc != 0) {
            die "Failed to start service '$id' (exit $rc)\n";
        }

        if (!$self->{docker}->container_running($name)) {
            $self->{docker}->container_logs($name);
            die "Service '$id' did not stay running\n";
        }
    }

    return;
}

sub _start_job_container {
    my ($self, $job, $network, $job_env, $context) = @_;

    my $container = $self->_resource_name('job', $job);
    my $image = $self->{workflow}->container_image(
        $job,
        $self->{workflow}->runs_on_text($job->{'runs-on'}, $job->{matrix} || {}),
        $self->{image} || 'ubuntu:latest',
        $self->{perl_image},
    );

    my @args = ($self->_platform_args);

    if (ref $job->{container} eq 'HASH' && defined $job->{container}{options}) {
        my $options = $self->{expression}->interpolate(
            "$job->{container}{options}", $context,
        );
        push @args, shellwords($options);
    }

    push @args, '--name', $container;
    push @args, '--network', $network;
    push @args, '--hostname', _hostname($job->{base_id});

    if (defined $self->{user}) {
        push @args, '--user', $self->{user};
    }

    push @args, '-v', "$self->{project_dir}:/github/workspace";
    push @args, '-v', "$self->{temp_path}:/github/actions-runner";

    if (ref $job->{container} eq 'HASH') {
        for my $volume (@{ _as_array($job->{container}{volumes}) }) {
            my $value = $self->{expression}->interpolate("$volume", $context);
            push @args, '-v', $value;
        }
        for my $port (@{ _as_array($job->{container}{ports}) }) {
            my $value = $self->{expression}->interpolate("$port", $context);
            push @args, '-p', $value;
        }
    }

    push @args, '-w', '/github/workspace';

    for my $key (sort keys %$job_env) {
        push @args, '-e', "$key=$job_env->{$key}";
    }

    push @args, '--entrypoint', '/bin/sh';
    push @args, $image;
    push @args, '-c', 'while :; do sleep 3600; done';

    my $rc = $self->{docker}->container_start(@args);
    if ($rc != 0) {
        $self->{docker}->container_remove($container);
        die "Failed to start the job container '$container' (exit $rc)\n";
    }

    if (!$self->{docker}->container_running($container)) {
        $self->{docker}->container_logs($container);
        $self->{docker}->container_remove($container);
        die "The job container '$container' did not stay running\n";
    }

    return $container;
}

sub _inspect_container {
    my ($self, $container) = @_;

    my $default_path = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
    my ($path, $path_rc) = $self->{docker}->capture_silent(
        'exec', $container, 'sh', '-c', 'printf %s "$PATH"',
    );
    $path = $default_path if $path_rc != 0 || !defined $path || !length $path;

    $path = "/github/actions-runner/aptbin:$path";

    my (undef, $bash_rc) = $self->{docker}->capture_silent(
        'exec', $container, 'sh', '-c', 'command -v bash >/dev/null 2>&1',
    );

    my (undef, $node_rc) = $self->{docker}->capture_silent(
        'exec', $container, 'sh', '-c', 'command -v node >/dev/null 2>&1',
    );

    if (!defined $self->{user}) {
        my (undef, $sudo_rc) = $self->{docker}->capture_silent(
            'exec', $container, 'sh', '-c', 'command -v sudo >/dev/null 2>&1',
        );
        $path = "/github/actions-runner/bin:$path" if $sudo_rc != 0;
    }

    return ($path, $bash_rc == 0 ? 1 : 0, $node_rc == 0 ? 1 : 0);
}

sub _execute_steps {
    my ($self, $job, $container, $network, $base_path, $has_bash, $has_node, $job_env, $context) = @_;

    my %ctx = %$context;
    $ctx{env} = $job_env;
    $ctx{job} = { status => 'success' };

    my $state = {
        job            => $job,
        container      => $container,
        network        => $network,
        base_path      => $base_path,
        has_bash       => $has_bash,
        has_node       => $has_node,
        job_env        => $job_env,
        path_additions => [],
        ctx            => \%ctx,
        counter        => { value => 0 },
        post_actions   => [],
        depth          => 0,
        failed         => 0,
    };

    for my $step (@{ $job->{steps} }) {
        $self->_execute_step($state, $step);
    }

    $self->_run_post_actions($state);

    return {
        result => $state->{failed} ? 'failure' : 'success',
        env    => $job_env,
    };
}

# Run one step in the given scope.  A scope holds the container, the job-level
# environment, the expression context, and the accumulated PATH additions, so
# that composite action steps can reuse the same machinery as workflow steps.
sub _execute_step {
    my ($self, $state, $step) = @_;

    my $ctx = $state->{ctx};
    my $job_env = $state->{job_env};
    my $prefix = '  ' x ($state->{depth} || 0);

    my $step_number = ++$state->{counter}{value};
    my $step_id = $step->{id};
    my $internal_id = defined $step_id ? $step_id : "__step_$step_number";

    my $step_env = eval {
        $self->_resolve_env([$job_env, $step->{env}], $ctx);
    };
    if ($@) {
        my $error = $@;
        $error =~ s/\s+$//;
        print STDERR "action-run: unable to evaluate environment for step '$internal_id': $error\n"
            unless $self->{quiet};
        $state->{failed} = 1;
        $ctx->{job}{status} = 'failure';
        if (defined $step_id) {
            $ctx->{steps}{$step_id} = {
                outputs    => {},
                outcome    => 'failure',
                conclusion => 'failure',
            };
        }
        return 'failure';
    }

    my $status = {
        success   => $state->{failed} ? 0 : 1,
        failure   => $state->{failed} ? 1 : 0,
        cancelled => 0,
    };

    my %condition_context = (%$ctx, env => $step_env);
    my $should_run = 1;

    if (defined $step->{if}) {
        my $condition = eval {
            $self->{expression}->condition($step->{if}, \%condition_context, $status);
        };
        if ($@) {
            my $error = $@;
            $error =~ s/\s+$//;
            print STDERR "action-run: unable to evaluate if for step '$internal_id': $error\n"
                unless $self->{quiet};
            $state->{failed} = 1;
            $ctx->{job}{status} = 'failure';
            return 'failure';
        }
        $should_run = $condition;
        # An `if` without a status function gets an implicit success().
        $should_run = 0 if $should_run && $state->{failed}
            && !_has_status_function($step->{if});
    } else {
        $should_run = $state->{failed} ? 0 : 1;
    }

    my $step_name = $self->_redact($self->_step_name($step, $step_number, \%condition_context));

    if (!$should_run) {
        print "${prefix}--- Step: $step_name (skipped)\n" unless $self->{quiet};
        if (defined $step_id) {
            $ctx->{steps}{$step_id} = {
                outputs    => {},
                outcome    => 'skipped',
                conclusion => 'skipped',
            };
        }
        return 'skipped';
    }

    print "${prefix}--- Step: $step_name\n" unless $self->{quiet};

    my $result;
    my $step_error;

    eval {
        if (defined $step->{run}) {
            $result = $self->_run_script_step(
                $state, $step, $step_number,
                $step_env, \%condition_context, $status,
            );
        } else {
            $result = $self->_run_uses_step(
                $state, $step, $step_number,
                $step_env, \%condition_context, $status,
            );
        }
    };
    if ($@) {
        $step_error = $@;
        $step_error =~ s/\s+$//;
        print STDERR "action-run: $step_error\n" unless $self->{quiet};
        $result = { outcome => 'failure', error => $step_error };
    }

    my $continue_on_error = 0;
    if (defined $step->{'continue-on-error'}) {
        $continue_on_error = eval {
            $self->_boolean_value($step->{'continue-on-error'}, \%condition_context, $status);
        };
        if ($@) {
            my $error = $@;
            $error =~ s/\s+$//;
            print STDERR "action-run: unable to evaluate continue-on-error: $error\n"
                unless $self->{quiet};
        }
    }

    my $outcome = $result->{outcome} || 'success';
    my $conclusion = $outcome;

    if ($outcome eq 'failure') {
        if ($continue_on_error) {
            $conclusion = 'success';
            print "${prefix}!! Step failed but continue-on-error is set\n"
                unless $self->{quiet};
        } else {
            $conclusion = 'failure';
            $state->{failed} = 1;
            my $message = $result->{error} || 'step failed';
            print STDERR "!! $message\n" unless $self->{quiet};
        }
    }

    if ($result->{env}) {
        for my $key (keys %{ $result->{env} }) {
            $job_env->{$key} = $result->{env}{$key};
        }
    }

    if ($result->{path} && @{ $result->{path} }) {
        unshift @{ $state->{path_additions} }, @{ $result->{path} };
    }

    $ctx->{env} = $job_env;
    $ctx->{job}{status} = $state->{failed} ? 'failure' : 'success';

    if (defined $step_id) {
        $ctx->{steps}{$step_id} = {
            outputs    => $result->{outputs} || {},
            outcome    => $outcome,
            conclusion => $conclusion,
        };
    }

    if (defined $result->{summary} && $result->{summary} =~ /\S/) {
        print "${prefix}--- Step summary ---\n$result->{summary}\n" unless $self->{quiet};
    }

    return $outcome;
}

# JavaScript actions can defer a post step until the job finishes.  Posts run
# in reverse order, as they do on GitHub.
sub _run_post_actions {
    my ($self, $state) = @_;

    my $post_actions = $state->{post_actions} || [];
    return unless @$post_actions;

    my $ctx = $state->{ctx};
    my $status = {
        success   => $state->{failed} ? 0 : 1,
        failure   => $state->{failed} ? 1 : 0,
        cancelled => 0,
    };

    for my $post (reverse @$post_actions) {
        my %post_ctx = (%$ctx, inputs => $post->{inputs}, env => $state->{job_env});
        $post_ctx{github} = {
            %{ $ctx->{github} || {} },
            action_path => $post->{action_path},
        };

        my $should_run = eval {
            $self->{expression}->condition($post->{condition}, \%post_ctx, $status);
        };
        if ($@) {
            my $error = $@;
            $error =~ s/\s+$//;
            print STDERR "action-run: unable to evaluate the post condition for '$post->{uses}': $error\n"
                unless $self->{quiet};
            next;
        }
        next unless $should_run;

        print "--- Step: Post $post->{uses}\n" unless $self->{quiet};

        my $rc = eval {
            my $files = $self->_prepare_step_files((++$state->{counter}{value}) . '-post');
            my %post_env = (%{ $state->{job_env} }, %{ $files->{vars} });
            for my $key (keys %{ $post->{state} || {} }) {
                $post_env{"STATE_$key"} = $post->{state}{$key};
            }
            $self->_run_node_script(
                $state, $post->{script}, \%post_env,
                $post->{step_id}, $post->{action_path}, $post->{inputs},
            );
        };

        if ($@) {
            my $error = $@;
            $error =~ s/\s+$//;
            print STDERR "action-run: post step for '$post->{uses}' failed: $error\n"
                unless $self->{quiet};
            $state->{failed} = 1;
            $status = { success => 0, failure => 1, cancelled => 0 };
            next;
        }

        if ($rc != 0) {
            print STDERR "!! post step for '$post->{uses}' exited with status $rc\n"
                unless $self->{quiet};
            $state->{failed} = 1;
            $status = { success => 0, failure => 1, cancelled => 0 };
        }
    }

    return;
}

sub _run_script_step {
    my ($self, $state, $step, $step_number, $env, $context, $status) = @_;

    my $job = $state->{job};
    my $has_bash = $state->{has_bash};
    my $base_path = $state->{base_path};
    my $path_additions = $state->{path_additions};
    my $container = $state->{container};

    my $shell = $self->_shell_for($step, $job, $context, $status, $has_bash);

    if ($shell->{requires_bash} && !$has_bash) {
        return {
            outcome => 'failure',
            error   => "Shell '$shell->{name}' is not available in the container",
        };
    }

    my @path = @$path_additions;
    my $script = $self->{expression}->interpolate($step->{run}, $context, $status);
    $script .= "\n" unless $script =~ /\n\z/;

    my $files = $self->_prepare_step_files($step_number);
    my %exec_env = (%$env, %{ $files->{vars} });

    my $path_base = defined $exec_env{PATH} ? $exec_env{PATH} : $base_path;
    $exec_env{PATH} = join(':', @path, $path_base);

    my $workdir = $self->_working_directory($step, $job, $context, $status);
    my $script_name = "step-$step_number$shell->{extension}";
    my $host_script = "$self->{temp_path}/scripts/$script_name";
    my $container_script = "/github/actions-runner/scripts/$script_name";

    $self->_write_container_file(
        $host_script, $script, "the step script '$host_script'",
    );
    chmod(defined $self->{user} ? 0666 : 0600, $host_script);

    my $command = $shell->{command};
    my $quoted_script = _shell_quote($container_script);
    if ($command =~ /\{0\}/) {
        $command =~ s/\{0\}/$quoted_script/g;
    } else {
        $command .= " $quoted_script";
    }

    $exec_env{GITHUB_ACTION} = defined $step->{id} ? $step->{id} : "__step_$step_number";
    $exec_env{GITHUB_ACTION_PATH} = defined $context->{github}{action_path}
        ? $context->{github}{action_path} : '';

    if ($self->{dry_run} && $self->{verbose}) {
        my $display_script = $self->_redact($script);
        print "--- script ---\n$display_script--- end script ---\n";
    }

    my @args = ('-w', $workdir);
    for my $key (sort keys %exec_env) {
        push @args, '-e', "$key=$exec_env{$key}";
    }
    push @args, $container, 'sh', '-c', $command;

    my $rc = $self->{docker}->container_exec(@args);

    my ($env_updates, $outputs, $paths, $summary) = $self->_collect_step_files($files, 0);

    return {
        outcome  => $rc == 0 ? 'success' : 'failure',
        exit_code => $rc,
        env      => $env_updates,
        outputs  => $outputs,
        path     => $paths,
        summary  => $summary,
        error    => $rc == 0 ? undef : "step exited with status $rc",
    };
}

sub _run_uses_step {
    my ($self, $state, $step, $step_number, $env, $context, $status) = @_;

    my $uses = $step->{uses};
    my $action = $self->{expression}->interpolate($uses, $context, $status);

    if ($action =~ m{^actions/checkout@}i) {
        if (defined $step->{with}{path} && length $step->{with}{path}) {
            print STDERR "action-run: actions/checkout 'path' is ignored; the repository is mounted at /github/workspace\n"
                unless $self->{quiet};
        }
        if (defined $step->{with}{submodules} && $step->{with}{submodules} ne 'false') {
            print STDERR "action-run: actions/checkout submodules are not fetched; using the checkout as-is\n"
                unless $self->{quiet};
        }
        if (defined $step->{with}{ref} || defined $step->{with}{repository}) {
            print STDERR "action-run: actions/checkout ref/repository is ignored; using the local checkout\n"
                unless $self->{quiet};
        }
        return $self->_noop_result('repository already mounted at /github/workspace');
    }

    if ($action =~ m{^(?:shogo82148/actions-setup-perl|perl-actions/setup-perl)@}i) {
        my $version = $step->{with}{'perl-version'};
        if (defined $version) {
            $version = $self->{expression}->interpolate($version, $context, $status);
        }
        return $self->_noop_result(
            'using container image for Perl' . (defined $version ? " $version" : ''),
        );
    }

    if ($action =~ m{^(?:actions/cache(?:/restore|/save)?|actions/upload-artifact|actions/download-artifact|codecov/codecov-action)@}i) {
        return $self->_noop_result('caching, artifacts, and coverage uploads are not implemented');
    }

    if ($action =~ m{^docker://(.+)$}) {
        return $self->_run_docker_action(
            $state, $step, $step_number, $1,
            $env, $context, $status,
        );
    }

    if ($action =~ m{^\.\.?/}) {
        return $self->_run_local_action(
            $state, $step, $step_number, $action, $env, $context, $status,
        );
    }

    return $self->_unsupported_action($action, 'remote JavaScript and composite actions are not supported');
}

sub _run_docker_action {
    my ($self, $state, $step, $step_number, $image, $env, $context, $status) = @_;

    my $job = $state->{job};
    my $network = $state->{network};
    my $base_path = $state->{base_path};
    my $path_additions = $state->{path_additions};

    $image = $self->{expression}->interpolate($image, $context, $status);
    croak "Docker action '$step->{uses}' has no image name" unless length $image;

    $self->_ensure_image($image);

    my $files = $self->_prepare_step_files($step_number);
    my %exec_env = (%$env, %{ $files->{vars} });

    my $path_base = defined $exec_env{PATH} ? $exec_env{PATH} : $base_path;
    $exec_env{PATH} = join(':', @$path_additions, $path_base);

    $exec_env{GITHUB_ACTION} = defined $step->{id} ? $step->{id} : "__step_$step_number";
    $exec_env{GITHUB_ACTION_PATH} = defined $context->{github}{action_path}
        ? $context->{github}{action_path} : '';

    my $workdir = $self->_working_directory($step, $job, $context, $status);

    my @args = ('run', '--rm');
    push @args, $self->_platform_args;
    push @args, '--network', $network;
    push @args, '-v', "$self->{project_dir}:/github/workspace";
    push @args, '-v', "$self->{temp_path}:/github/actions-runner";
    push @args, '-w', $workdir;

    if (defined $self->{user}) {
        push @args, '--user', $self->{user};
    }

    if (defined $step->{with}{entrypoint}) {
        my $entrypoint = $self->{expression}->interpolate(
            "$step->{with}{entrypoint}", $context, $status,
        );
        push @args, '--entrypoint', $entrypoint;
    }

    for my $key (sort keys %exec_env) {
        push @args, '-e', "$key=$exec_env{$key}";
    }

    push @args, $image;

    my $arguments = $step->{with}{args};
    if (defined $arguments) {
        $arguments = $self->{expression}->interpolate("$arguments", $context, $status);
        push @args, shellwords($arguments);
    }

    my $rc = $self->{docker}->run(@args);

    my ($env_updates, $outputs, $paths, $summary) = $self->_collect_step_files($files, 0);

    return {
        outcome   => $rc == 0 ? 'success' : 'failure',
        exit_code => $rc,
        env       => $env_updates,
        outputs   => $outputs,
        path      => $paths,
        summary   => $summary,
        error     => $rc == 0 ? undef : "docker action exited with status $rc",
    };
}

# Run an action that lives inside the project, e.g. "uses: ./.github/actions/test".
sub _run_local_action {
    my ($self, $state, $step, $step_number, $uses, $env, $context, $status) = @_;

    my $relative = $self->_local_action_path($uses);

    my $host_dir = File::Spec->catdir($self->{project_dir}, split m{/}, $relative);
    croak "Local action '$uses' does not exist (looked in $host_dir)"
        unless -d $host_dir;

    my $action = eval { App::Actions::Action->load_from_dir($host_dir) };
    if ($@) {
        my $error = $@;
        $error =~ s/\s+$//;
        croak $error;
    }

    my $container_path = "/github/workspace/$relative";
    my $inputs = $self->_action_inputs($action, $step, $uses, $context, $status);

    if ($action->is_composite) {
        return $self->_run_composite_action(
            $state, $action, $step, $step_number, $container_path,
            $inputs, $env, $context, $status,
        );
    }

    if ($action->is_javascript) {
        return $self->_run_javascript_action(
            $state, $action, $step, $step_number, $container_path,
            $inputs, $env, $context, $status,
        );
    }

    return $self->_unsupported_action(
        $uses,
        "local actions that use '$action->{using}' are not supported",
    );
}

# Resolve "./path/to/action" to a path relative to the project, or explain why
# it cannot be used.  Both the run and the preflight resolve references the
# same way, so an action is read from one place whichever finds it first.
sub _local_action_path {
    my ($self, $uses) = @_;

    my $relative = $uses;
    $relative =~ s{^\./}{};
    $relative =~ s{^/+}{};
    $relative =~ s{/+$}{};

    croak "Local action '$uses' does not name a directory inside the project"
        unless length $relative;
    croak "Local action '$uses' must not escape the project directory"
        if $relative =~ m{(?:^|/)\.\.(?:/|$)};

    return $relative;
}

# Resolve the action's inputs from defaults and the calling step's `with`.
sub _action_inputs {
    my ($self, $action, $step, $uses, $context, $status) = @_;

    my $declared = $action->inputs || {};
    my $with = ref $step->{with} eq 'HASH' ? $step->{with} : {};

    my %inputs;
    for my $name (keys %$declared) {
        my $default = $declared->{$name}{default};
        $inputs{$name} = defined $default && length $default
            ? $self->{expression}->interpolate($default, $context, $status)
            : '';
    }

    for my $name (keys %$with) {
        my $value = $with->{$name};
        $value = $self->{expression}->interpolate(_stringify($value), $context, $status)
            unless ref $value;
        $inputs{$name} = _stringify($value);
    }

    for my $name (sort keys %$declared) {
        next unless $declared->{$name}{required};
        next if defined $inputs{$name} && length $inputs{$name};
        croak "Action '$uses' requires the input '$name'";
    }

    return \%inputs;
}

sub _run_composite_action {
    my ($self, $state, $action, $step, $step_number, $container_path, $inputs, $env, $context, $status) = @_;

    my $uses = $step->{uses};
    my $depth = $state->{depth} || 0;
    croak "Composite action '$uses' is nested more than 10 levels deep" if $depth >= 10;

    my %nested_ctx = %$context;
    $nested_ctx{inputs} = $inputs;
    $nested_ctx{steps} = {};
    $nested_ctx{job} = { status => $state->{failed} ? 'failure' : 'success' };
    $nested_ctx{github} = {
        %{ $context->{github} || {} },
        action_path => $container_path,
        action      => $uses,
    };

    my $nested = {
        %$state,
        ctx     => \%nested_ctx,
        job_env => { %$env },
        depth   => $depth + 1,
        failed  => 0,
    };

    for my $nested_step (@{ $action->steps }) {
        $self->_execute_step($nested, $nested_step);
    }

    my %outputs;
    my $declared = $action->outputs || {};
    my %output_ctx = (%nested_ctx, env => $nested->{job_env});
    for my $name (keys %$declared) {
        my $value = $declared->{$name}{value};
        $outputs{$name} = $self->{expression}->interpolate($value, \%output_ctx);
    }

    # Variables exported inside the action belong to the caller's job env.
    for my $key (keys %{ $nested->{job_env} }) {
        next if exists $env->{$key} && "$env->{$key}" eq "$nested->{job_env}{$key}";
        $state->{job_env}{$key} = $nested->{job_env}{$key};
    }

    return {
        outcome   => $nested->{failed} ? 'failure' : 'success',
        env       => {},
        outputs   => \%outputs,
        path      => [],
        summary   => '',
        error     => $nested->{failed} ? "composite action '$uses' failed" : undef,
    };
}

sub _run_javascript_action {
    my ($self, $state, $action, $step, $step_number, $container_path, $inputs, $env, $context, $status) = @_;

    my $runs = $action->runs;
    my $uses = $step->{uses};

    croak "JavaScript action '$uses' needs Node.js, but 'node' was not found in the job container"
        unless $state->{has_node};

    my $step_id = defined $step->{id} ? $step->{id} : "__step_$step_number";

    my %state_values;
    my %all_env;
    my %all_outputs;
    my @all_paths;
    my $summary = '';

    my $pre = $runs->{pre};
    if (defined $pre && length "$pre") {
        my $condition = defined $runs->{'pre-if'} ? $runs->{'pre-if'} : 'always()';
        my $should_run = eval {
            $self->{expression}->condition($condition, $context, $status);
        };
        if ($@) {
            my $error = $@;
            $error =~ s/\s+$//;
            print STDERR "action-run: unable to evaluate pre-if for '$uses': $error\n"
                unless $self->{quiet};
            $should_run = 0;
        }

        if ($should_run) {
            my $files = $self->_prepare_step_files("$step_number-pre");
            my %pre_env = (%$env, %{ $files->{vars} });
            my $rc = $self->_run_node_script(
                $state, "$container_path/$pre", \%pre_env, $step_id, $container_path, $inputs,
            );
            my ($env_updates, $outputs, $paths, $pre_summary, $saved)
                = $self->_collect_step_files($files, 1);

            %all_env     = (%all_env, %$env_updates);
            %all_outputs = (%all_outputs, %$outputs);
            push @all_paths, @$paths;
            $summary .= $pre_summary if length $pre_summary;
            $state_values{$_} = $saved->{$_} for keys %$saved;

            if ($rc != 0) {
                return {
                    outcome   => 'failure',
                    exit_code => $rc,
                    env       => \%all_env,
                    outputs   => \%all_outputs,
                    path      => \@all_paths,
                    summary   => $summary,
                    error     => "pre step of JavaScript action '$uses' exited with status $rc",
                };
            }
        }
    }

    my $files = $self->_prepare_step_files($step_number);
    my %exec_env = (%$env, %{ $files->{vars} });
    for my $key (keys %state_values) {
        $exec_env{"STATE_$key"} = $state_values{$key};
    }

    my $rc = $self->_run_node_script(
        $state, "$container_path/$runs->{main}", \%exec_env, $step_id, $container_path, $inputs,
    );

    my ($env_updates, $outputs, $paths, $step_summary, $saved)
        = $self->_collect_step_files($files, 1);

    %all_env     = (%all_env, %$env_updates);
    %all_outputs = (%all_outputs, %$outputs);
    push @all_paths, @$paths;
    $summary .= $step_summary if length $step_summary;
    $state_values{$_} = $saved->{$_} for keys %$saved;

    my $post = $runs->{post};
    if (defined $post && length "$post") {
        push @{ $state->{post_actions} }, {
            uses        => $uses,
            script      => "$container_path/$post",
            condition   => defined $runs->{'post-if'} ? $runs->{'post-if'} : 'always()',
            inputs      => $inputs,
            action_path => $container_path,
            step_id     => $step_id,
            state       => { %state_values },
        };
    }

    return {
        outcome   => $rc == 0 ? 'success' : 'failure',
        exit_code => $rc,
        env       => \%all_env,
        outputs   => \%all_outputs,
        path      => \@all_paths,
        summary   => $summary,
        error     => $rc == 0 ? undef : "JavaScript action '$uses' exited with status $rc",
    };
}

# Execute a JavaScript action entry point with the job environment, its inputs
# as INPUT_* variables, and GITHUB_ACTION_PATH pointing at the action.
sub _run_node_script {
    my ($self, $state, $script, $env, $step_id, $action_path, $inputs) = @_;

    my %exec_env = %$env;
    my $path_base = defined $exec_env{PATH} ? $exec_env{PATH} : $state->{base_path};
    $exec_env{PATH} = join(':', @{ $state->{path_additions} }, $path_base);

    $exec_env{GITHUB_ACTION} = $step_id;
    $exec_env{GITHUB_ACTION_PATH} = $action_path;

    for my $name (sort keys %$inputs) {
        (my $key = uc $name) =~ s/[^A-Z0-9_]/_/g;
        $exec_env{"INPUT_$key"} = $inputs->{$name};
    }

    my @args = ('-w', '/github/workspace');
    for my $key (sort keys %exec_env) {
        push @args, '-e', "$key=$exec_env{$key}";
    }
    push @args, $state->{container}, 'node', $script;

    return $self->{docker}->container_exec(@args);
}

sub _noop_result {
    my ($self, $message) = @_;

    print "    ($message)\n" unless $self->{quiet};

    return {
        outcome => 'success',
        env     => {},
        outputs => {},
        path    => [],
        summary => '',
    };
}

sub _unsupported_action {
    my ($self, $action, $reason) = @_;

    my $message = "action '$action' skipped: $reason";
    if ($self->{strict_actions}) {
        print STDERR "action-run: $message\n" unless $self->{quiet};
        return {
            outcome => 'failure',
            env     => {},
            outputs => {},
            path    => [],
            summary => '',
            error   => $message,
        };
    }

    print STDERR "action-run: $message\n" unless $self->{quiet};
    print "    (skipped: $reason)\n" unless $self->{quiet};

    return {
        outcome => 'skipped',
        env     => {},
        outputs => {},
        path    => [],
        summary => '',
    };
}

sub _shell_for {
    my ($self, $step, $job, $context, $status, $has_bash) = @_;

    my $shell = $step->{shell};
    $shell = $job->{defaults}{run}{shell} unless defined $shell;
    $shell = $self->{workflow}->defaults->{run}{shell} unless defined $shell;

    if (!defined $shell) {
        return {
            name          => 'bash',
            command       => 'bash -e {0}',
            extension     => '.sh',
            requires_bash => 1,
        } if $self->{dry_run} || $has_bash;

        return {
            name          => 'sh',
            command       => 'sh -e {0}',
            extension     => '.sh',
            requires_bash => 0,
        };
    }

    $shell = $self->{expression}->interpolate("$shell", $context, $status);
    my $lower = lc $shell;
    $lower =~ s/^\s+|\s+$//g;

    my %known = (
        bash => {
            name          => 'bash',
            command       => 'bash --noprofile --norc -eo pipefail {0}',
            extension     => '.sh',
            requires_bash => 1,
        },
        sh => {
            name          => 'sh',
            command       => 'sh -e {0}',
            extension     => '.sh',
            requires_bash => 0,
        },
        perl => {
            name          => 'perl',
            command       => 'perl {0}',
            extension     => '.pl',
            requires_bash => 0,
        },
        python => {
            name          => 'python',
            command       => 'python {0}',
            extension     => '.py',
            requires_bash => 0,
        },
        pwsh => {
            name          => 'pwsh',
            command       => 'pwsh -File {0}',
            extension     => '.ps1',
            requires_bash => 0,
        },
        powershell => {
            name          => 'powershell',
            command       => 'powershell -File {0}',
            extension     => '.ps1',
            requires_bash => 0,
        },
    );

    return $known{$lower} if exists $known{$lower};

    return {
        name          => 'custom',
        command       => $shell =~ /\{0\}/ ? $shell : "$shell {0}",
        extension     => '.sh',
        requires_bash => 0,
    };
}

sub _working_directory {
    my ($self, $step, $job, $context, $status) = @_;

    my $workdir = $step->{'working-directory'};
    $workdir = $job->{defaults}{run}{'working-directory'} unless defined $workdir;
    $workdir = $self->{workflow}->defaults->{run}{'working-directory'} unless defined $workdir;
    $workdir = '/github/workspace' unless defined $workdir && length $workdir;

    $workdir = $self->{expression}->interpolate("$workdir", $context, $status);
    $workdir = '/github/workspace' unless length $workdir;
    $workdir = "/github/workspace/$workdir" unless $workdir =~ m{^/};

    return $workdir;
}

sub _step_name {
    my ($self, $step, $number, $context) = @_;

    my $name = $step->{name};
    $name = $step->{uses} if !defined $name && defined $step->{uses};
    if (!defined $name && defined $step->{run}) {
        $name = $step->{run};
        $name =~ s/\s+/ /g;
        $name =~ s/^\s+|\s+$//g;
        $name = substr($name, 0, 77) . '...' if length $name > 80;
    }
    $name = "Step $number" unless defined $name && length $name;

    my $value = eval {
        $self->{expression}->interpolate($name, $context);
    };
    return $@ ? $name : $value;
}

sub _prepare_step_files {
    my ($self, $step_number) = @_;

    my $prefix = "step-$step_number";
    my %host = (
        env     => "$self->{temp_path}/env/$prefix.env",
        output  => "$self->{temp_path}/output/$prefix.out",
        path    => "$self->{temp_path}/path/$prefix.path",
        summary => "$self->{temp_path}/summary/$prefix.md",
        state   => "$self->{temp_path}/env/$prefix.state",
    );
    my %vars = (
        GITHUB_ENV          => "/github/actions-runner/env/$prefix.env",
        GITHUB_OUTPUT       => "/github/actions-runner/output/$prefix.out",
        GITHUB_PATH         => "/github/actions-runner/path/$prefix.path",
        GITHUB_STEP_SUMMARY => "/github/actions-runner/summary/$prefix.md",
        GITHUB_STATE        => "/github/actions-runner/env/$prefix.state",
    );

    for my $key (keys %host) {
        open my $handle, '>', $host{$key}
            or croak "Unable to create step file '$host{$key}': $!";
        close $handle;
        chmod(defined $self->{user} ? 0666 : 0600, $host{$key});
    }

    return { host => \%host, vars => \%vars };
}

sub _collect_step_files {
    my ($self, $files, $keep_state) = @_;

    my $env     = $self->_parse_kv_file($files->{host}{env});
    my $outputs = $self->_parse_kv_file($files->{host}{output});
    my $paths   = $self->_read_lines($files->{host}{path});
    my $summary = $self->_read_file($files->{host}{summary});
    my $state   = $keep_state
        ? $self->_parse_kv_file($files->{host}{state})
        : {};

    my %remove = %{ $files->{host} };
    delete $remove{state} if $keep_state;
    unlink grep { defined && -e $_ } values %remove;

    return ($env, $outputs, $paths, $summary, $state);
}

sub _parse_kv_file {
    my ($self, $path) = @_;

    my %values;
    return \%values unless defined $path && -f $path;

    open my $handle, '<', $path or return \%values;

    while (defined(my $line = <$handle>)) {
        $line =~ s/\r?\n$//;
        next if $line eq '';

        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s) {
            $values{$1} = $2;
            next;
        }

        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)<<(\S+)$/) {
            my ($name, $delimiter) = ($1, $2);
            my @lines;
            while (defined(my $body = <$handle>)) {
                $body =~ s/\r?\n$//;
                last if $body eq $delimiter;
                push @lines, $body;
            }
            $values{$name} = join("\n", @lines);
        }
    }

    close $handle;

    return \%values;
}

sub _read_lines {
    my ($self, $path) = @_;

    my @lines;
    return \@lines unless defined $path && -f $path;

    open my $handle, '<', $path or return \@lines;
    while (defined(my $line = <$handle>)) {
        $line =~ s/\r?\n$//;
        $line =~ s/^\s+|\s+$//g;
        push @lines, $line if length $line;
    }
    close $handle;

    return \@lines;
}

sub _read_file {
    my ($self, $path) = @_;

    return '' unless defined $path && -f $path;

    open my $handle, '<', $path or return '';
    local $/;
    my $contents = <$handle>;
    close $handle;

    return defined $contents ? $contents : '';
}

sub _resolve_env {
    my ($self, $layers, $context) = @_;

    my %env;
    for my $layer (@$layers) {
        next unless defined $layer && ref $layer eq 'HASH';
        for my $key (keys %$layer) {
            $env{$key} = _stringify($layer->{$key});
        }
    }

    for my $pass (1 .. 10) {
        my %with_env = (%$context, env => { %env });
        my $changed = 0;
        for my $key (keys %env) {
            my $value = eval {
                $self->{expression}->interpolate($env{$key}, \%with_env);
            };
            if ($@) {
                my $error = $@;
                $error =~ s/\s+$//;
                croak "Unable to evaluate environment variable '$key': $error";
            }
            if ($value ne $env{$key}) {
                $env{$key} = $value;
                $changed = 1;
            }
        }
        last unless $changed;
    }

    return \%env;
}

sub _boolean_value {
    my ($self, $value, $context, $status) = @_;

    return $value ? 1 : 0 if ref $value;
    return 0 unless defined $value;

    my $text = "$value";
    $text =~ s/^\s+|\s+$//g;
    return 0 if $text eq '';
    return 1 if $text =~ /^(?:true|yes|1)$/i;
    return 0 if $text =~ /^(?:false|no|0)$/i;

    return $self->{expression}->condition($text, $context, $status);
}

sub _github_context {
    my ($self, $job) = @_;

    my $env = $self->{base_env} || {};
    my $job_id = ref $job eq 'HASH' ? $job->{base_id} : $job;

    return {
        event_name      => $env->{GITHUB_EVENT_NAME},
        event           => $self->{event} || {},
        event_path      => '/github/actions-runner/event.json',
        ref             => $env->{GITHUB_REF},
        ref_name        => $env->{GITHUB_REF_NAME},
        ref_type        => $env->{GITHUB_REF_TYPE},
        sha             => $env->{GITHUB_SHA},
        repository      => $env->{GITHUB_REPOSITORY},
        repository_owner => $env->{GITHUB_REPOSITORY_OWNER},
        workflow        => $self->{workflow}->name,
        job             => $job_id,
        run_id          => $env->{GITHUB_RUN_ID},
        run_number      => $env->{GITHUB_RUN_NUMBER},
        run_attempt     => $env->{GITHUB_RUN_ATTEMPT},
        actor           => $env->{GITHUB_ACTOR},
        server_url      => $env->{GITHUB_SERVER_URL},
        api_url         => $env->{GITHUB_API_URL},
        graphql_url     => $env->{GITHUB_GRAPHQL_URL},
        workspace       => '/github/workspace',
        token           => '',
        head_ref        => '',
        base_ref        => '',
    };
}

sub _runner_context {
    my ($self) = @_;

    return {
        os          => 'Linux',
        arch        => 'X64',
        name        => 'local',
        temp        => '/github/actions-runner/_temp',
        tool_cache  => '/github/actions-runner/_tool',
        workspace   => '/github/workspace',
    };
}

sub _ensure_image {
    my ($self, $image) = @_;

    return 1 if $self->{dry_run};

    my $exists = $self->{docker}->image_exists($image);

    if ($self->{pull} || !$exists) {
        if ($self->{no_pull}) {
            die "Docker image '$image' is not available locally (--no-pull)\n";
        }
        print "Pulling image $image...\n" unless $self->{quiet};
        $self->{docker}->pull($image);
        $self->{pulled_images}{$image} = 1 unless $exists;
    }

    return 1;
}

sub _platform_args {
    my ($self) = @_;

    return () unless defined $self->{platform} && length $self->{platform};
    return ('--platform', $self->{platform});
}

sub _resource_name {
    my ($self, $kind, $job, $suffix) = @_;

    my $counter = ++$self->{name_counter};
    my $short_id = substr($self->{run_id}, -8);
    my $base = $job->{base_id};
    $base =~ s/[^A-Za-z0-9_.-]/-/g;
    $base = substr($base, 0, 20);

    my $name = "action-run-$short_id-$counter-$kind-$base-$job->{matrix_index}";
    $name .= "-$suffix" if defined $suffix && length $suffix;
    $name =~ s/[^A-Za-z0-9_.-]/-/g;

    return substr($name, 0, 63);
}

sub _cleanup_job {
    my ($self, $network, $containers) = @_;

    return if $self->{keep};

    for my $container (reverse @$containers) {
        $self->{docker}->container_remove($container);
        @{ $self->{containers} } = grep { $_ ne $container } @{ $self->{containers} };
    }

    $self->{docker}->network_remove($network);
    @{ $self->{networks} } = grep { $_ ne $network } @{ $self->{networks} };

    return;
}

sub _cleanup {
    my ($self) = @_;

    return if $self->{cleaned_up}++;

    if ($self->{keep}) {
        if (@{ $self->{containers} } || @{ $self->{networks} } || $self->{temp_path}) {
            print "Kept Docker resources:\n" unless $self->{quiet};
            print "  container $_\n" for @{ $self->{containers} };
            print "  network $_\n" for @{ $self->{networks} };
            print "  temporary directory $self->{temp_path}\n" if $self->{temp_path};
        }
        return;
    }

    for my $container (reverse @{ $self->{containers} }) {
        $self->{docker}->container_remove($container);
    }
    for my $network (reverse @{ $self->{networks} }) {
        $self->{docker}->network_remove($network);
    }

    if (!$self->{keep_images}) {
        for my $image (sort keys %{ $self->{pulled_images} }) {
            $self->{docker}->image_remove($image);
        }
    }

    if ($self->{temp_path} && -d $self->{temp_path}) {
        eval { remove_tree($self->{temp_path}); };
    }

    return;
}

sub _print_summary {
    my ($self) = @_;

    return if $self->{quiet};

    print "\n=== Workflow summary ===\n";
    if (!@{ $self->{summary} }) {
        print "  No jobs were run.\n";
    } else {
        for my $entry (@{ $self->{summary} }) {
            printf "  %-50s %s\n", $self->_redact($entry->{name}), $entry->{result};
        }
    }
    print 'Workflow ', ($self->{workflow_failed} ? 'FAILED' : 'succeeded'), "\n";

    return;
}

sub _as_array {
    my ($value) = @_;

    return [] unless defined $value;
    return $value if ref $value eq 'ARRAY';
    return [$value];
}

sub _has_status_function {
    my ($condition) = @_;

    return 0 unless defined $condition;
    return $condition =~ /\b(?:success|failure|always|cancelled)\s*\(/ ? 1 : 0;
}

sub _truthy_scalar {
    my ($value) = @_;

    return $value ? 1 : 0 if ref $value;
    return 0 unless defined $value;
    return 0 if $value =~ /^(?:false|no|0)$/i;
    return 1;
}

sub _stringify {
    my ($value) = @_;

    return '' unless defined $value;
    if (blessed($value) && $value->isa('JSON::PP::Boolean')) {
        return $value ? 'true' : 'false';
    }
    return "$value" unless ref $value;
    return JSON::PP->new->canonical->encode($value);
}

sub _hostname {
    my ($value) = @_;

    $value = 'local' unless defined $value && length $value;
    $value =~ s/[^A-Za-z0-9.-]/-/g;
    $value = substr($value, 0, 63);
    $value = 'local' unless length $value;

    return $value;
}

sub _shell_quote {
    my ($value) = @_;

    $value = '' unless defined $value;
    $value =~ s/'/'\\''/g;
    return "'$value'";
}

sub _redact {
    my ($self, $text) = @_;

    return $text unless defined $text;
    return $self->{docker}->redact($text) if $self->{docker}->can('redact');
    return $text;
}

sub _trim {
    my ($value) = @_;

    return '' unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    return $value;
}

1;

__END__

=head1 NAME

App::Actions::Runner - run a GitHub Actions workflow in Docker

=head1 SYNOPSIS

    use App::Actions;
    use App::Actions::Runner;

    my $runner = App::Actions::Runner->new(
        workflow    => $workflow,
        project_dir => '/home/njh/src/njh/CGI-Info',
        image       => 'ubuntu:latest',
    );
    my $exit = $runner->run;

=head1 DESCRIPTION

This module executes the jobs in a workflow.  Each job gets its own Docker
network, its own service containers, and a long-lived job container.  Steps
are executed with C<docker exec>, so filesystem changes persist between
steps while each step gets a fresh shell, just as on GitHub.

Containers, networks, and any images that this run pulled are removed when the
job or run finishes.  Use C<keep> for debugging.

=head1 METHODS

=head2 run

Runs every selected job and returns an exit status: 0 for success, 1 for a
workflow failure, 2 for a usage or Docker error.

=head2 list_jobs

Prints the expanded jobs and returns 0.

=head1 LIMITATIONS

Only Linux C<runs-on> runners are supported.  JavaScript actions cannot be
executed locally; well-known actions such as checkout and setup-perl become
no-ops, and other actions are skipped with a warning unless C<strict_actions>
is set.  Local composite actions, job outputs, C<needs.*.outputs>, and
C<timeout-minutes> are not implemented.  C<hashFiles()> is not implemented.

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
