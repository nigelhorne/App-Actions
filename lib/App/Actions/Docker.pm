package App::Actions::Docker;

use strict;
use warnings;
use Carp qw(croak);

use File::Spec;

use App::Actions::Process;

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;

    my %secret_names;
    my %secret_values;
    if ($args{secrets}) {
        for my $name (keys %{ $args{secrets} }) {
            $secret_names{$name} = 1;
            my $value = $args{secrets}{$name};
            next unless defined $value && length $value;
            $secret_values{$value} = 1;
        }
    }

    my $bin = $args{bin} || $ENV{DOCKER} || 'docker';

    return bless {
        bin           => $bin,
        interpreter   => [ _interpreter_prefix($bin) ],
        dry_run       => $args{dry_run} ? 1 : 0,
        # A dry run can also be the one that reports containers rather than
        # commands: the report is the point, so the commands stay out of it.
        explain       => $args{explain} ? 1 : 0,
        verbose       => $args{verbose} ? 1 : 0,
        quiet         => $args{quiet} ? 1 : 0,
        platform      => $args{platform},
        secret_names  => \%secret_names,
        secret_values => \%secret_values,
    }, $class;
}

# The Docker command may be a wrapper script instead of a native executable.
# Windows cannot start a shebang script directly, and a script without the
# executable bit cannot be started on Unix either, so a Perl wrapper is run
# with the current interpreter.  Anything else is used as given.
sub _interpreter_prefix {
    my ($bin) = @_;

    return () unless defined $bin && length $bin && !ref $bin;
    return () unless -f $bin;
    return () if $bin =~ /\.(?:exe|com|bat|cmd)\z/i;
    return ($^X) if $bin =~ /\.pl\z/i;

    # Only the first line matters, and the command may be a large binary, so
    # read a bounded amount rather than a whole line.
    open my $handle, '<', $bin or return ();
    my $header = '';
    read($handle, $header, 256);
    close $handle;

    return () unless defined $header && $header =~ /^#!.*\bperl/;

    return ($^X);
}

sub _command {
    my ($self, @args) = @_;
    return (@{ $self->{interpreter} }, $self->{bin}, @args);
}

sub bin     { return $_[0]->{bin} }
sub dry_run { return $_[0]->{dry_run} }
sub explain { return $_[0]->{explain} }
sub verbose { return $_[0]->{verbose} }
sub quiet   { return $_[0]->{quiet} }

sub platform_args {
    my ($self) = @_;
    return (defined $self->{platform} && length $self->{platform}) ? ('--platform', $self->{platform}) : ();
}

sub check {
    my ($self) = @_;

    return 1 if $self->{dry_run};

    my ($version, $version_rc) = $self->capture_silent('--version');
    if ($version_rc != 0) {
        croak "Docker executable '$self->{bin}' was not found or is not usable";
    }
    print $version if $self->{verbose} && !$self->{quiet} && length $version;

    my (undef, $rc) = $self->{quiet}
        ? $self->capture_silent('info', '--format', '{{.ServerVersion}}')
        : $self->capture('info', '--format', '{{.ServerVersion}}');
    if ($rc != 0) {
        croak "Cannot connect to the Docker daemon. Is Docker running, and can this user access it?";
    }

    return 1;
}

sub image_exists {
    my ($self, $image) = @_;

    # A dry run starts nothing, so every image is as good as present.
    my $rc = $self->{dry_run} ? 0 : ($self->capture_silent('image', 'inspect', '--format', '{{.Id}}', $image))[1];

    return $rc == 0 ? 1 : 0;
}

# The size of an image in bytes, or undef when the daemon does not have it.
# This is what the image cache reports, so it must not be an error for the
# image to be absent: an image removed outside the tool is a fact to show, not
# a reason to fail.
sub image_size {
    my ($self, $image) = @_;

    return undef if $self->{dry_run};

    my ($output, $rc) = $self->capture_silent(
        'image', 'inspect', '--format', '{{.Size}}', $image,
    );
    return undef if $rc != 0;

    $output = '' unless defined $output;
    $output =~ s/\s+//g;

    return $output =~ /\A\d+\z/ ? $output + 0 : undef;
}

sub pull {
    my ($self, $image) = @_;

    my @args = ('pull');
    push @args, $self->platform_args;
    push @args, $image;

    my $rc = $self->run(@args);
    # die, not croak, and with a trailing newline: this is advice for the
    # reader, not a place to point at source lines.
    die "Failed to pull Docker image '$image' (exit $rc)\n" if $rc != 0;
    return 1;
}

# Pull several images at once and report the exit status of each.  Docker's
# own output goes straight to the terminal, so a slow image is still visible
# while the others finish.  The result is keyed by image name, which lets the
# caller say which images failed and what needed them.
sub pull_many {
    my ($self, $images, %options) = @_;

    croak 'No images given' unless ref $images eq 'ARRAY' && @$images;

    # A caller that is building a machine-readable report asks for silence:
    # docker's own progress lines would not be part of any document.
    my $quiet = $options{quiet} ? 1 : 0;

    if ($self->{dry_run}) {
        for my $image (@$images) {
            print "[dry-run] $self->{bin} ",
                $self->_display('pull', $self->platform_args, $image), "\n"
                unless $self->{quiet} || $quiet || $self->{explain};
        }
        return { map { $_ => 0 } @$images };
    }

    # The command lines are printed before anything starts, because the
    # children then write to the same terminal in no particular order.
    if ($self->{verbose} && !$self->{quiet} && !$quiet) {
        for my $image (@$images) {
            print "+ $self->{bin} ",
                $self->_display('pull', $self->platform_args, $image), "\n";
        }
    }

    my @commands = map {
        [ $self->_command('pull', $self->platform_args, $_) ]
    } @$images;

    my %redirect;
    if ($quiet) {
        my $devnull = File::Spec->devnull;
        %redirect = (stdout => $devnull, stderr => $devnull);
    }

    my $codes = App::Actions::Process::run_parallel(
        \@commands,
        concurrency => $options{concurrency} || 4,
        %redirect,
    );

    my %results;
    for my $index (0 .. $#$images) {
        $results{ $images->[$index] } = $codes->[$index];
    }

    return \%results;
}

sub image_remove {
    my ($self, $image) = @_;

    return $self->run_silent('image', 'rm', '-f', $image);
}

sub network_create {
    my ($self, $name) = @_;
    return $self->run_silent('network', 'create', $name);
}

sub network_remove {
    my ($self, $name) = @_;
    return $self->run_silent('network', 'rm', $name);
}

sub container_start {
    my ($self, @args) = @_;
    return $self->run_silent('run', '-d', @args);
}

# The same start, with what the daemon said kept rather than discarded.  A
# start that fails explains itself on standard error - the image it cannot
# use, the entrypoint the image does not have, the port already taken - and
# that text is the only account of the failure; the exit status alone leaves a
# reader comparing the command with the number.  Returns the output and the
# status, in the order capture uses.
sub container_start_captured {
    my ($self, @args) = @_;

    my ($output, $rc) = $self->capture_merged('run', '-d', @args);

    return (defined $output ? $output : '', $rc);
}

sub container_exec {
    my ($self, @args) = @_;
    return $self->run('exec', @args);
}

sub container_running {
    my ($self, $name) = @_;

    return 1 if $self->{dry_run};

    my ($output, $rc) = $self->capture_silent(
        'inspect', '--format', '{{.State.Running}}', $name,
    );
    return 1 if $rc == 0 && $output =~ /true/;
    return 0;
}

sub container_logs {
    my ($self, $name, $lines) = @_;

    $lines = 200 unless defined $lines;
    return $self->run('logs', '--tail', $lines, $name);
}

# The last lines a container printed, as text rather than streamed to the
# caller, with the container's standard error merged in: a container that
# stopped is as likely to have said why on one stream as the other, and a
# message that quotes it has room for both.
sub container_log_text {
    my ($self, $name, $lines) = @_;

    $lines = 10 unless defined $lines;

    return '' if $self->{dry_run};

    my ($output) = $self->capture_merged('logs', '--tail', $lines, $name);

    return defined $output ? $output : '';
}

# The status a container exited with, or undef when the daemon cannot say -
# the container may have been removed already, or the inspect may have raced a
# cleanup.
sub container_exit_code {
    my ($self, $name) = @_;

    # A dry run's containers all exit cleanly.
    my $output = $self->{dry_run} ? '0' : $self->_inspect_field($name, '{{.State.ExitCode}}');

    return defined $output && $output =~ /\A-?\d+\z/ ? $output + 0 : undef;
}

# The state the daemon reports for the container: running, restarting,
# exited, dead, or undef when the daemon cannot describe it.
sub container_status {
    my ($self, $name) = @_;

    # A dry run's containers are all running.
    my $output = $self->{dry_run} ? 'running' : $self->_inspect_field($name, '{{.State.Status}}');

    return defined $output && length $output ? $output : undef;
}

# How many times the restart policy has restarted the container, or undef when
# the daemon cannot say.  0 is the normal answer for one that has stayed up.
sub container_restart_count {
    my ($self, $name) = @_;

    # A dry run's containers never restart.
    my $output = $self->{dry_run} ? '0' : $self->_inspect_field($name, '{{.RestartCount}}');

    return defined $output && $output =~ /\A\d+\z/ ? $output + 0 : undef;
}

# _inspect_field
# Purpose:     Ask the daemon for one field of a container's inspect output.
# Entry:       $name - the container; $format - a Go template such as
#              '{{.State.Status}}'.
# Exit status: Returns the field with all white space removed, or undef when
#              the inspect failed (the container is gone, or the daemon is).
# Side effects: Runs docker inspect, with its standard error discarded.
sub _inspect_field {
    my ($self, $name, $format) = @_;

    my ($output, $rc) = $self->capture_silent('inspect', '--format', $format, $name);

    # Every field read this way is a single token, so white space is only
    # the trailing newline and any CR a Windows client adds.
    (my $field = defined $output ? $output : '') =~ s/\s+//g;

    return $rc == 0 ? $field : undef;
}

sub container_remove {
    my ($self, $name) = @_;
    return $self->run_silent('rm', '-f', $name);
}

sub run {
    my ($self, @args) = @_;

    return $self->_announce(@args)
        ? App::Actions::Process::stream([ $self->_command(@args) ])
        : 0;
}

sub run_silent {
    my ($self, @args) = @_;

    return $self->_announce(@args)
        ? App::Actions::Process::run_quiet([ $self->_command(@args) ])
        : 0;
}

# _announce
# Purpose:     Print the command about to run, the way the mode asks for.
# Entry:       @args - the Docker arguments.
# Exit status: Returns 1 when the command should be run, 0 in a dry run.
# Side effects: Prints "[dry-run] ..." in a dry run (unless quiet or
#              explaining) and "+ ..." when verbose (unless quiet).  Secrets
#              are redacted from what is printed, never from what is run.
sub _announce {
    my ($self, @args) = @_;

    my $display = $self->_display(@args);

    if ($self->{dry_run}) {
        print "[dry-run] $self->{bin} $display\n"
            unless $self->{quiet} || $self->{explain};
        return 0;
    }

    print "+ $self->{bin} $display\n" if $self->{verbose} && !$self->{quiet};

    return 1;
}

sub capture {
    my ($self, @args) = @_;
    return $self->_capture(0, 0, @args);
}

sub capture_silent {
    my ($self, @args) = @_;
    return $self->_capture(1, 0, @args);
}

# Capture both of the command's streams, as if it had been run with 2>&1.
sub capture_merged {
    my ($self, @args) = @_;
    return $self->_capture(1, 1, @args);
}

sub _capture {
    my ($self, $quiet_stderr, $merge_stderr, @args) = @_;

    return ('', 0) unless $self->_announce(@args);

    return App::Actions::Process::capture(
        [ $self->_command(@args) ],
        quiet_stderr => $quiet_stderr,
        merge_stderr => $merge_stderr,
    );
}

sub redact {
    my ($self, $text) = @_;

    return $text unless defined $text;

    # Longest first: when one secret contains another, replacing the shorter
    # one first would leave the rest of the longer one in the text ("abc" and
    # "abcdef" would print "***def").
    for my $secret (sort { length $b <=> length $a || $a cmp $b } keys %{ $self->{secret_values} }) {
        $text =~ s/\Q$secret\E/***/g;
    }

    return $text;
}

sub _display {
    my ($self, @args) = @_;

    my @copy = @args;
    for my $arg (@copy) {
        next unless defined $arg;
        if ($arg =~ /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s
            && $self->{secret_names}{$1}) {
            $arg = "$1=***";
            next;
        }
        $arg = $self->redact($arg);
    }

    return join ' ', map { _quote($_) } @copy;
}

sub _quote {
    my ($argument) = @_;

    # Empty becomes '', a safe word stays bare, and anything else is single
    # quoted with each embedded quote closed, escaped and reopened.
    my $copy = defined $argument ? $argument : '';

    return !length $copy ? q{''}
        : $copy =~ /\A[A-Za-z0-9_@%+=:,.\/-]+\z/ ? $copy
        : "'" . ($copy =~ s/'/'\\''/gr) . "'";
}

1;

__END__

=head1 NAME

App::Actions::Docker - a thin wrapper around the Docker command line

=head1 SYNOPSIS

    my $docker = App::Actions::Docker->new(verbose => 1);
    $docker->check;
    $docker->pull('perl:5.38');

=head1 DESCRIPTION

This module centralises the Docker command line calls used by
L<App::Actions::Runner>.  It also provides a dry-run mode and redacts known
secret values from the commands it prints.

The Docker command may be a wrapper script rather than the C<docker> binary.
If the wrapper is a Perl script (it starts with a C<perl> shebang), it is run
with the current Perl interpreter.  That also makes such wrappers usable on
Windows, where the operating system cannot start a shebang script directly.

=head1 METHODS

=head2 check

Verifies that the Docker executable exists and that the daemon is reachable.

=head2 image_exists

Returns true when an image is already available locally.

=head2 pull

Pulls an image, raising an exception if Docker fails.

=head2 run

Runs a Docker subcommand, streaming its output.  Returns the exit status.

=head2 capture

Runs a Docker subcommand and captures its standard output.  Returns the output
and the exit status as a list.

=head2 container_start, container_exec, container_running, container_logs, container_remove

Convenience wrappers for the corresponding Docker subcommands.

=head2 container_start_captured

    my ($output, $status) = $docker->container_start_captured(@args);

Starts a container detached like C<container_start>, but returns what the
daemon said as well as the status, with its standard error merged in.  A start
that fails says why on standard error, and that text is what distinguishes an
image the daemon could not use from an entrypoint the image does not have or a
port already taken; nothing is written to the caller's streams.

=head2 container_exit_code

    my $status = $docker->container_exit_code($name);

Returns the status the container exited with, or C<undef> when the daemon
cannot say, for example because the container has already been removed.

=head2 container_status

    my $state = $docker->container_status($name);

Returns the state the daemon reports for the container, such as C<running>,
C<restarting>, C<exited> or C<dead>, or C<undef> when it cannot say, for
example because the container has already been removed.

=head2 container_restart_count

    my $count = $docker->container_restart_count($name);

Returns how many times the container's restart policy has restarted it, or
C<undef> when the daemon cannot say.  A container that has stayed up reports
0; one that is being restarted reports 1 or more even while it is up between
attempts, which is what a running check alone cannot see.

=head2 container_log_text

    my $text = $docker->container_log_text($name, $lines);

Returns the last C<$lines> (default 10) lines the container printed, with its
standard error merged in, for quoting in an error message.  Unlike
C<container_logs>, nothing is written to the caller's streams.

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
