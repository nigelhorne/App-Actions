use strict;
use warnings;
use Test::Most;
use Capture::Tiny qw(capture);

use App::Actions::Process;

# Windows writes CRLF when output is redirected to a file.
sub useful_text {
    my ($text) = @_;
    return '' unless defined $text;
    $text =~ s/\r\n/\n/g;
    return $text;
}

is(App::Actions::Process::exit_code(0), 0, 'a zero status is success');
is(App::Actions::Process::exit_code(3 << 8), 3, 'an exit code is decoded');
is(App::Actions::Process::exit_code((15 << 8) | 9), 128 + 9,
    'a signal is reported as 128 + signal');
isnt(App::Actions::Process::exit_code(-1), 0,
    'a command that cannot be started is a failure');

my ($output, $status) = App::Actions::Process::capture(
    [ $^X, '-e', 'print "hello\n"' ],
);
is($status, 0, 'capture reports success');
is($output, "hello\n", 'capture returns standard output');

($output, $status) = App::Actions::Process::capture(
    [ $^X, '-e', 'print "out\n"; print STDERR "noise\n"' ],
    quiet_stderr => 1,
);
is($output, "out\n", 'quiet_stderr still captures standard output');
is($status, 0, 'quiet_stderr reports success');

($output, $status) = App::Actions::Process::capture(
    [ $^X, '-e', 'binmode STDOUT; print "a\r\nb\r\n"' ],
);
is($output, "a\nb\n", 'CRLF output is normalised on every platform');

($output, $status) = App::Actions::Process::capture([ $^X, '-e', 'exit 7' ]);
is($status, 7, 'the exit code is reported');

is(
    App::Actions::Process::run_quiet([ $^X, '-e', 'print "quiet\n"; exit 4' ]),
    4,
    'run_quiet discards the output and reports the status',
);

my (undef, $missing) = App::Actions::Process::capture(
    [ 'app-actions-no-such-command' ],
);
isnt($missing, 0, 'a missing command is reported');

# Capturing must not disturb an enclosing Capture::Tiny, and output buffered
# before the command has to be flushed first so that the order is preserved.
my ($stdout, $stderr) = capture {
    print "before\n";
    my ($inner) = App::Actions::Process::capture(
        [ $^X, '-e', 'print "inner\n"' ],
    );
    is($inner, "inner\n", 'the command output is captured inside Capture::Tiny');
    print "after\n";
};

is($stdout, "before\nafter\n", 'the enclosing capture keeps its output in order');
is($stderr, '', 'standard error is left alone');

my (undef, $passthrough) = capture {
    App::Actions::Process::capture([ $^X, '-e', 'print STDERR "noise\n"' ]);
};
is(useful_text($passthrough), "noise\n", 'standard error is passed through by default');

done_testing;
