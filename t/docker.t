use strict;
use warnings;
use Test::Most;
use Capture::Tiny qw(capture);
use File::Spec;
use File::Temp qw(tempdir);

use App::Actions::Docker;

my $dir = tempdir(CLEANUP => 1);

# A Docker wrapper written in Perl.  It deliberately has no file extension and
# is not executable, which is how such a wrapper looks on Windows.
my $wrapper = File::Spec->catfile($dir, 'fake-docker');
open my $handle, '>', $wrapper or die $!;
print {$handle} <<'PERL';
#!/usr/bin/env perl
use strict;
use warnings;

my $command = $ARGV[0] || '';
if ($command eq '--version') {
    print "Wrapper version 1.0\n";
    exit 0;
}
if ($command eq 'fail') {
    print "failing on purpose\n";
    exit 9;
}
print join('|', @ARGV), "\n";
exit 0;
PERL
close $handle;
chmod 0644, $wrapper;

my $docker = App::Actions::Docker->new(bin => $wrapper, quiet => 1);

my ($version, $version_rc) = $docker->capture_silent('--version');
is($version_rc, 0, 'a Perl wrapper is run with the interpreter');
is($version, "Wrapper version 1.0\n", 'the wrapper output is captured');

my ($output, $rc) = $docker->capture_silent('pull', 'alpine:3.20');
is($rc, 0, 'the wrapper receives the Docker arguments');
is($output, "pull|alpine:3.20\n", 'arguments are passed through unchanged');

my (undef, $fail_rc) = $docker->capture_silent('fail');
is($fail_rc, 9, 'a failing wrapper status is reported');

my $silent_rc = $docker->run_silent('fail');
is($silent_rc, 9, 'run_silent reports the wrapper status');

my $run_rc;
my ($stdout, $stderr) = capture {
    $run_rc = $docker->run('pull', 'perl:5.38');
};
is($run_rc, 0, 'run executes the wrapper');
like($stdout, qr/^pull\|perl:5\.38$/m, 'run streams the wrapper output');

my $native = App::Actions::Docker->new(bin => $^X, quiet => 1);
my ($native_out, $native_rc) = $native->capture_silent('-e', 'print "native\n"');
is($native_rc, 0, 'a native executable is used directly');
is($native_out, "native\n", 'a native executable still produces output');

my $missing = App::Actions::Docker->new(bin => File::Spec->catfile($dir, 'absent'), quiet => 1);
my (undef, $missing_rc) = $missing->capture_silent('--version');
isnt($missing_rc, 0, 'a missing Docker command is reported');

done_testing;
