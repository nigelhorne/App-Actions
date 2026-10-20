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
            },
        },
        $source,
    );

    return;
}

my $temp = tempdir('app-actions space XXXX', TMPDIR => 1, CLEANUP => 1);
my $copy = File::Spec->catdir($temp, 'suite with spaces');
make_path($copy);

copy_tree($root, $copy, $_) for qw(lib bin t);

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
