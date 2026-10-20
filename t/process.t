use strict;
use warnings;
use Test::Most;
use Capture::Tiny qw(capture);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

use App::Actions::Process;

# Child programs are written to files rather than passed with -e: Win32 Perl
# does not round-trip "-e" code containing double quotes through system(), and
# mangles it into a different program.
sub write_program {
    my ($contents, %options) = @_;

    my $directory = $options{directory} || tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($directory, 'program.pl');

    open my $handle, '>', $path or die $!;
    binmode $handle;
    print {$handle} $contents;
    close $handle;

    return $path;
}

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

# Windows command-line quoting.  These are the rules the C runtime uses to
# split a command line, so the quoted argument has to parse back to the
# original; Perl's own quoting skips any argument containing a double quote.
is(App::Actions::Process::quote_win32('plain'), 'plain',
    'an argument without spaces or quotes is left alone');
is(App::Actions::Process::quote_win32('two words'), '"two words"',
    'spaces force quotes');
is(App::Actions::Process::quote_win32(''), '""',
    'an empty argument is quoted');
is(App::Actions::Process::quote_win32('say "hi"'), '"say \"hi\""',
    'an embedded double quote is escaped');
is(App::Actions::Process::quote_win32('a\\b c'), '"a\\b c"',
    'a backslash away from a quote is kept');
is(App::Actions::Process::quote_win32('a\\"b'), '"a' . ('\\' x 3) . '"b"',
    'a backslash before a quote is doubled');
is(
    App::Actions::Process::quote_win32('trailing ' . '\\'),
    '"trailing ' . ('\\' x 2) . '"',
    'a trailing backslash is doubled so it cannot escape the closing quote',
);
is(App::Actions::Process::quote_win32('sh -c printf %s "$PATH"'),
    '"sh -c printf %s \"$PATH\""',
    'a shell command is quoted as one argument');

my $hello = write_program("print \"hello\\n\";\n");
my ($output, $status) = App::Actions::Process::capture([ $^X, $hello ]);
is($status, 0, 'capture reports success');
is($output, "hello\n", 'capture returns standard output');

my $both = write_program("print \"out\\n\";\nprint STDERR \"noise\\n\";\n");
($output, $status) = App::Actions::Process::capture(
    [ $^X, $both ],
    quiet_stderr => 1,
);
is($output, "out\n", 'quiet_stderr still captures standard output');
is($status, 0, 'quiet_stderr reports success');

my $crlf = write_program("binmode STDOUT;\nprint \"a\\r\\nb\\r\\n\";\n");
($output, $status) = App::Actions::Process::capture([ $^X, $crlf ]);
is($output, "a\nb\n", 'CRLF output is normalised on every platform');

my $failing = write_program("exit 7;\n");
($output, $status) = App::Actions::Process::capture([ $^X, $failing ]);
is($status, 7, 'the exit code is reported');

# Arguments that need quoting have to arrive unchanged, on Windows as well as
# on Unix.  Win32 Perl splits them at their spaces otherwise.
my $echo_args = write_program("print join('|', \@ARGV), \"\\n\";\n");
($output, $status) = App::Actions::Process::capture(
    [ $^X, $echo_args, 'two words', 'say "hi"', 'a\\b c' ],
);
is($status, 0, 'a command with quoted arguments runs');
is($output, 'two words|say "hi"|a\\b c' . "\n",
    'arguments with spaces and quotes reach the command unchanged');

my $quiet = write_program("print \"quiet\\n\";\nexit 4;\n");
is(
    App::Actions::Process::run_quiet([ $^X, $quiet ]),
    4,
    'run_quiet discards the output and reports the status',
);

my $streamed = write_program("print \"streamed\\n\";\nexit 5;\n");
my $stream_status;
my ($stream_out) = capture {
    $stream_status = App::Actions::Process::stream([ $^X, $streamed ]);
};
is($stream_status, 5, 'stream reports the exit code');
is($stream_out, "streamed\n", 'stream passes the output through');

my (undef, $missing) = App::Actions::Process::capture(
    [ 'app-actions-no-such-command' ],
);
isnt($missing, 0, 'a missing command is reported');

# Paths with spaces are common on Windows and must reach the child intact.
my $spaced_dir = File::Spec->catdir(tempdir(CLEANUP => 1), 'with space');
make_path($spaced_dir);
my $spaced = write_program("print \"spaced\\n\";\n", directory => $spaced_dir);
my ($spaced_out, $spaced_status) = App::Actions::Process::capture([ $^X, $spaced ]);
is($spaced_status, 0, 'a script below a path with spaces runs');
is($spaced_out, "spaced\n", 'the output of a script below a path with spaces is captured');

# Capturing must not disturb an enclosing Capture::Tiny, and output buffered
# before the command has to be flushed first so that the order is preserved.
my $inner = write_program("print \"inner\\n\";\n");
my ($stdout, $stderr) = capture {
    print "before\n";
    my ($inner_out) = App::Actions::Process::capture([ $^X, $inner ]);
    is($inner_out, "inner\n", 'the command output is captured inside Capture::Tiny');
    print "after\n";
};

is($stdout, "before\nafter\n", 'the enclosing capture keeps its output in order');
is($stderr, '', 'standard error is left alone');

my $noise = write_program("print STDERR \"noise\\n\";\n");
my (undef, $passthrough) = capture {
    App::Actions::Process::capture([ $^X, $noise ]);
};
is(useful_text($passthrough), "noise\n", 'standard error is passed through by default');

done_testing;
