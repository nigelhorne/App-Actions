use strict;
use warnings;
use Test::Most;
use Capture::Tiny qw(capture);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

use App::Actions::Process;

my $root = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));

# Copying and running the suite costs as much as the suite itself, so there is
# a switch to turn it off; a child run must never copy the suite again.
plan skip_all => 'the suite was already copied here for the space-in-path run'
    if $ENV{APP_ACTIONS_SPACE_PATH_CHILD};
plan skip_all => 'SPACE_PATH=0 turns off the space-in-path run'
    if defined $ENV{SPACE_PATH} && $ENV{SPACE_PATH} eq '0';
plan skip_all => 'the suite is already running from a path with spaces'
    if $root =~ / /;

# The copy is made here, not in the distribution, so the tests below exercise
# the code under test and not a stale duplicate.
sub copy_tree {
    my ($from, $to, $directory) = @_;

    my $source = File::Spec->catdir($from, $directory);
    my $target = File::Spec->catdir($to, $directory);
    make_path($target);

    find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $path = $File::Find::name;
                my $relative = File::Spec->abs2rel($path, $source);
                my $destination = File::Spec->catfile($target, $relative);
                if (-d $path) {
                    make_path($destination);
                    return;
                }
                copy($path, $destination)
                    or die "cannot copy '$path' to '$destination': $!\n";

                # A copy is only a copy if it keeps the mode: the hook is run
                # rather than read, so an executable bit lost on the way would
                # fail a test that has nothing to do with paths.
                chmod((stat $path)[2] & 07777, $destination)
                    or die "cannot set the mode of '$destination': $!\n";
            },
        },
        $source,
    );

    return;
}

my $temp = tempdir('app-actions space XXXX', TMPDIR => 1, CLEANUP => 1);
my $copy = File::Spec->catdir($temp, 'suite with spaces');
make_path($copy);

# The documentation, the workflows and the hooks are copied too, not just the
# code: a test that reads them then runs in the copy rather than failing - or,
# worse, skipping - because the copy never had the file.  t/live-knobs.t reads
# the documentation and the workflow, and t/hooks.t runs the hook itself.
for my $directory (qw(lib bin t .github .githooks)) {
    copy_tree($root, $copy, $directory)
        if -d File::Spec->catdir($root, $directory);
}

for my $file (qw(README.md)) {
    my $from = File::Spec->catfile($root, $file);

    copy($from, File::Spec->catfile($copy, $file))
        or die "cannot copy '$from': $!\n"
        if -e $from;
}

like($copy, qr/ /, 'the copy lives under a path with spaces');

my $tests = File::Spec->catdir($copy, 't');
my $lib   = File::Spec->catdir($copy, 'lib');

opendir my $directory, $tests or die "cannot read '$tests': $!\n";
my @tests = sort grep { /\.t\z/ } readdir $directory;
closedir $directory;

ok(@tests, 'the copy contains the test suite');

my @failed;
{
    my $original = File::Spec->rel2abs(File::Spec->curdir);
    chdir $copy or die "cannot change to '$copy': $!\n";

    for my $test (@tests) {
        my $file = File::Spec->catfile($tests, $test);
        my ($stdout, $stderr, $status) = capture {
            local $ENV{APP_ACTIONS_SPACE_PATH_CHILD} = 1;
            App::Actions::Process::stream([ $^X, '-I' . $lib, $file ]);
        };

        my $ok = ok(
            $status == 0,
            "$test passes when the suite is run from a path with spaces",
        );

        next if $ok;

        push @failed, $test;
        diag "stdout:\n$stdout" if length $stdout;
        diag "stderr:\n$stderr" if length $stderr;
    }

    chdir $original or die "cannot return to '$original': $!\n";
}

is_deeply(\@failed, [], 'every test file passes from a path with spaces');

done_testing;
