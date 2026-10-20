package App::Actions::Docker;

use strict;
use warnings;
use Carp qw(croak);
use File::Spec;

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

    return bless {
        bin           => $args{bin} || $ENV{DOCKER} || 'docker',
        dry_run       => $args{dry_run} ? 1 : 0,
        verbose       => $args{verbose} ? 1 : 0,
        quiet         => $args{quiet} ? 1 : 0,
        platform      => $args{platform},
        secret_names  => \%secret_names,
        secret_values => \%secret_values,
    }, $class;
}

sub bin     { return $_[0]->{bin} }
sub dry_run { return $_[0]->{dry_run} }
sub verbose { return $_[0]->{verbose} }
sub quiet   { return $_[0]->{quiet} }

sub platform_args {
    my ($self) = @_;
    return () unless defined $self->{platform} && length $self->{platform};
    return ('--platform', $self->{platform});
}

sub check {
    my ($self) = @_;

    return 1 if $self->{dry_run};

    my ($version, $version_rc) = $self->capture_silent('--version');
    if ($version_rc != 0) {
        croak "Docker executable '$self->{bin}' was not found or is not usable";
    }
    print $version if $self->{verbose} && !$self->{quiet} && length $version;

    my ($info, $rc) = $self->{quiet}
        ? $self->capture_silent('info', '--format', '{{.ServerVersion}}')
        : $self->capture('info', '--format', '{{.ServerVersion}}');
    if ($rc != 0) {
        croak "Cannot connect to the Docker daemon. Is Docker running, and can this user access it?";
    }

    return 1;
}

sub image_exists {
    my ($self, $image) = @_;

    return 1 if $self->{dry_run};

    my (undef, $rc) = $self->capture_silent('image', 'inspect', '--format', '{{.Id}}', $image);
    return $rc == 0 ? 1 : 0;
}

sub pull {
    my ($self, $image) = @_;

    my @args = ('pull');
    push @args, $self->platform_args;
    push @args, $image;

    my $rc = $self->run(@args);
    croak "Failed to pull Docker image '$image' (exit $rc)" if $rc != 0;
    return 1;
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

sub container_remove {
    my ($self, $name) = @_;
    return $self->run_silent('rm', '-f', $name);
}

sub run {
    my ($self, @args) = @_;

    my $display = $self->_display(@args);

    if ($self->{dry_run}) {
        print "[dry-run] $self->{bin} $display\n" unless $self->{quiet};
        return 0;
    }

    print "+ $self->{bin} $display\n" if $self->{verbose} && !$self->{quiet};

    system($self->{bin}, @args);
    return _exit_code($?);
}

sub run_silent {
    my ($self, @args) = @_;

    my $display = $self->_display(@args);

    if ($self->{dry_run}) {
        print "[dry-run] $self->{bin} $display\n" unless $self->{quiet};
        return 0;
    }

    print "+ $self->{bin} $display\n" if $self->{verbose} && !$self->{quiet};

    my $pid = fork;
    croak "Unable to fork for '$self->{bin}': $!" unless defined $pid;

    if ($pid == 0) {
        open STDOUT, '>', File::Spec->devnull;
        open STDERR, '>', File::Spec->devnull;
        exec $self->{bin}, @args;
        exit 127;
    }

    waitpid($pid, 0);
    return _exit_code($?);
}

sub capture {
    my ($self, @args) = @_;
    return $self->_capture(0, @args);
}

sub capture_silent {
    my ($self, @args) = @_;
    return $self->_capture(1, @args);
}

sub _capture {
    my ($self, $quiet_stderr, @args) = @_;

    my $display = $self->_display(@args);

    if ($self->{dry_run}) {
        print "[dry-run] $self->{bin} $display\n" unless $self->{quiet};
        return ('', 0);
    }

    print "+ $self->{bin} $display\n" if $self->{verbose} && !$self->{quiet};

    my $pid = open my $handle, '-|';
    croak "Unable to run '$self->{bin}': $!" unless defined $pid;

    if ($pid == 0) {
        open STDERR, '>', File::Spec->devnull if $quiet_stderr;
        exec $self->{bin}, @args;
        exit 127;
    }

    local $/;
    my $output = <$handle>;
    $output = '' unless defined $output;
    close $handle;

    return ($output, _exit_code($?));
}

sub redact {
    my ($self, $text) = @_;

    return $text unless defined $text;
    for my $secret (keys %{ $self->{secret_values} }) {
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

    return q{''} unless defined $argument && length $argument;
    return $argument if $argument =~ /^[A-Za-z0-9_@%+=:,.\/-]+$/;

    my $copy = $argument;
    $copy =~ s/'/'\\''/g;
    return "'$copy'";
}

sub _exit_code {
    my ($status) = @_;

    return 0 unless $status;
    return 128 + ($status & 127) if $status & 127;
    return $status >> 8;
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

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
