package App::Actions::Process;

use strict;
use warnings;
use Carp qw(croak);
use File::Spec;
use File::Temp ();
use IO::Handle ();

our $VERSION = '0.01';

# Turn Perl's $? into an exit code.  Windows reports $? in the same
# POSIX-compatible form as Unix, so no platform check is needed.
sub exit_code {
    my ($status) = @_;

    return 0 unless $status;
    return 128 + ($status & 127) if $status & 127;
    return $status >> 8;
}

# Run $command (an array reference) and capture its standard output.
# Standard error is passed through to the caller unless quiet_stderr is true.
# Returns the output and the exit code.
sub capture {
    my ($command, %options) = @_;

    croak 'No command given' unless ref $command eq 'ARRAY' && @$command;

    my $temp = File::Temp->new(
        TEMPLATE => 'app-actions-XXXXXX',
        TMPDIR   => 1,
        UNLINK   => 1,
    );

    my $status = run(
        $command,
        stdout => $temp->filename,
        stderr => $options{quiet_stderr} ? File::Spec->devnull : undef,
    );

    seek $temp, 0, 0 or croak "Unable to rewind captured output: $!";
    local $/;
    my $output = <$temp>;
    $output = '' unless defined $output;
    $output =~ s/\r\n/\n/g;

    return ($output, $status);
}

# Run $command with both streams discarded.
sub run_quiet {
    my ($command) = @_;

    my $devnull = File::Spec->devnull;
    return run($command, stdout => $devnull, stderr => $devnull);
}

# Run $command with its standard output (and optionally its standard error)
# redirected to a file.  The redirection uses dup() and system() rather than
# fork() and a piped open(), because the forking pipe open is not reliably
# available on Windows.
sub run {
    my ($command, %options) = @_;

    croak 'No command given' unless ref $command eq 'ARRAY' && @$command;

    my @command = @$command;
    my $stdout  = defined $options{stdout} ? $options{stdout} : File::Spec->devnull;

    # Anything already buffered belongs before the child's output.
    STDOUT->flush;
    STDERR->flush;

    open my $saved_stdout, '>&', \*STDOUT
        or croak "Unable to duplicate STDOUT: $!";
    open my $saved_stderr, '>&', \*STDERR
        or croak "Unable to duplicate STDERR: $!";

    my $error;
    my $redirected = open STDOUT, '>', $stdout;
    if ($redirected && defined $options{stderr}) {
        $redirected = open STDERR, '>', $options{stderr};
    }
    $error = $! unless $redirected;

    my $status = 0;
    if ($redirected) {
        # Perl announces a program it cannot start; the exit status carries the
        # same information, and the caller reports it in its own words.
        local $SIG{__WARN__} = sub {
            my $warning = shift;
            warn $warning unless $warning =~ /^Can't exec /;
        };
        system(@command);
        $status = $?;
    }

    open STDOUT, '>&', $saved_stdout
        or croak "Unable to restore STDOUT: $!";
    open STDERR, '>&', $saved_stderr
        or croak "Unable to restore STDERR: $!";

    croak "Unable to redirect command output: $error" unless $redirected;

    return exit_code($status);
}

1;

__END__

=head1 NAME

App::Actions::Process - run external commands portably

=head1 SYNOPSIS

    use App::Actions::Process;

    my ($output, $status) = App::Actions::Process::capture(['git', 'status']);
    my $status = App::Actions::Process::run_quiet(['docker', 'info']);

=head1 DESCRIPTION

L<App::Actions::Docker> and L<App::Actions::Runner> need to run external
programs and inspect their exit codes.  The obvious implementations use
C<fork> and the piped forms of C<open>, which are not reliably available on
Windows.  This module uses C<system> with explicitly redirected standard
output instead, so the same code works on Unix and on Windows.

=head1 FUNCTIONS

=head2 capture

    my ($output, $status) = capture(\@command, quiet_stderr => 1);

Runs the command, capturing its standard output.  Standard error is passed
through unless C<quiet_stderr> is true.  Newlines in the captured output are
normalised to C<"\n">.  The command is not run through a shell.

=head2 run_quiet

    my $status = run_quiet(\@command);

Runs the command with both standard output and standard error discarded.

=head2 exit_code

    my $code = exit_code($?);

Converts the value of C<$?> into an exit code, mapping a signal to
C<128 + signal>.

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
