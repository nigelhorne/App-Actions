use strict;
use warnings;
use Test::Most;
use Config;
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

use App::Actions::Process;

my $root = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
my $hook = File::Spec->catfile($root, '.githooks', 'pre-commit');

plan skip_all => 'the pre-commit hook is not part of this copy of the suite'
    unless -f $hook;
my (undef, $git_status) = App::Actions::Process::capture(['git', '--version']);
plan skip_all => 'git is needed to test a git hook' if $git_status;

ok(-x $hook || $^O eq 'MSWin32', 'the pre-commit hook is executable');

my $makefile_pl = slurp(File::Spec->catfile($root, 'Makefile.PL'));
like($makefile_pl, qr/^check-staged:/m,
    'Makefile.PL generates a check-staged target');
like($makefile_pl, qr/pre-commit --staged/,
    'the staged target runs the hook in its staged mode');
like($makefile_pl, qr/^check-worktree:/m,
    'Makefile.PL generates a check-worktree target');
like($makefile_pl, qr/pre-commit --worktree/,
    'the worktree target runs the hook in its worktree mode');

# The hook is run from a repository of its own, so that the test can stage a
# document without touching the checkout it is running in.
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

sub slurp {
    my ($file) = @_;

    open my $handle, '<', $file or die "cannot read '$file': $!\n";
    my $text = do { local $/; <$handle> };
    close $handle;

    return $text;
}

sub spew {
    my ($file, $text) = @_;

    open my $handle, '>', $file or die "cannot write '$file': $!\n";
    print {$handle} $text or die "cannot write '$file': $!\n";
    close $handle or die "cannot write '$file': $!\n";

    return;
}

my $repository = tempdir('app-actions hook XXXX', TMPDIR => 1, CLEANUP => 1);
copy_tree($root, $repository, $_) for qw(lib bin t .githooks .github);

# The live-knob check reads the documentation as well as the tests, so the
# copy has the README it looks in rather than skipping that half.
copy(
    File::Spec->catfile($root, 'README.md'),
    File::Spec->catfile($repository, 'README.md'),
) or die "cannot copy README.md into the repository copy: $!\n";

# The end-to-end target test generates a Makefile from this copy, so the
# repository carries the same Makefile.PL the checkout does.
copy(
    File::Spec->catfile($root, 'Makefile.PL'),
    File::Spec->catfile($repository, 'Makefile.PL'),
) or die "cannot copy Makefile.PL into the repository copy: $!\n";

# Everything the test runs happens in the repository, and the caller's working
# directory is put back afterwards.
sub in_repository {
    my ($command) = @_;

    my $cwd = File::Spec->rel2abs(File::Spec->curdir);
    chdir $repository or die "cannot change to '$repository': $!\n";

    my ($output, $status) = App::Actions::Process::capture(
        [
            'git',
            '-c', 'user.name=App::Actions test',
            '-c', 'user.email=test@example.com',
            '-c', 'commit.gpgsign=false',
            @$command,
        ],
        merge_stderr => 1,
    );

    chdir $cwd or die "cannot change to '$cwd': $!\n";

    return ($output, $status);
}

sub run_in_repository {
    my (@command) = @_;

    my $cwd = File::Spec->rel2abs(File::Spec->curdir);
    chdir $repository or die "cannot change to '$repository': $!\n";

    my ($output, $exit) = App::Actions::Process::capture(
        \@command, merge_stderr => 1,
    );

    chdir $cwd or die "cannot change to '$cwd': $!\n";

    return ($output, $exit);
}

sub run_hook {
    my (@args) = @_;

    return run_in_repository($^X, $hook, @args);
}

my (undef, $init) = in_repository([ 'init', '-q' ]);
is($init, 0, 'the copy is a git repository');

in_repository([ 'add', '-A' ]);
my (undef, $commit) = in_repository([ 'commit', '-qm', 'initial' ]);
is($commit, 0, 'the copy holds one commit');

my ($clean_output, $clean_status) = run_hook();
is($clean_status, 0, 'the hook passes when no schema can have moved');

# A bump applied to the working tree but not to the index is the one that
# would be committed in half: the staged document still declares the old
# version while the file beside it declares the new one.
my $fixture = File::Spec->catfile($repository, 't', 'fixtures', 'preflight-unreachable.json');
my $shipped = slurp($fixture);

like($shipped, qr/"schema_version"\s*:\s*3\b/,
    'the fixture starts at the version the module ships');

(my $stale = $shipped) =~ s/"schema_version"\s*:\s*\d+/"schema_version": 2/;

spew($fixture, $stale);
in_repository([ 'add', 't/fixtures/preflight-unreachable.json' ]);
spew($fixture, $shipped);

# The working tree agrees with itself now; only the index carries the stale
# document.  If the hook read the working tree it would let this through.
my ($refused, $refused_status) = run_hook();

isnt($refused_status, 0, 'the hook refuses a bump that is staged but not followed through');
like($refused, qr/preflight-unreachable\.json/, 'the refusal names the document');
like($refused, qr/declares schema version 2/, 'the refusal names the version it declares');
like($refused, qr/no-verify/, 'the refusal says how to skip the check for one commit');

# The same snapshot can be checked without attempting a commit, which is what
# make check-staged runs.  It has to reach the same verdict and say which mode
# it is in, so a failure does not claim a commit was refused.
my ($staged_refused, $staged_refused_status) = run_hook('--staged');
isnt($staged_refused_status, 0,
    'check-staged refuses the same staged snapshot');
like($staged_refused, qr/check-staged: the checks failed/,
    'the command-line check names itself rather than the hook');
like($staged_refused, qr/preflight-unreachable\.json/,
    'the command-line check names the staged document at fault');
unlike($staged_refused, qr/nothing has been committed/,
    'a failed make target does not claim a commit was refused');

my (undef, $worktree_passed) = run_hook('--worktree');
is($worktree_passed, 0,
    'check-worktree accepts the good working tree while the index is stale');

# The other half: the document that is staged is correct, and the edit that
# would break it sits in the working tree beside it.  The commit is fine, so
# the hook has to pass - which it only does by reading the staged document.
in_repository([ 'add', 't/fixtures/preflight-unreachable.json' ]);
spew($fixture, "$shipped\n");
in_repository([ 'add', 't/fixtures/preflight-unreachable.json' ]);
spew($fixture, $stale);

my (undef, $passed_status) = run_hook();
is($passed_status, 0, 'the hook checks the staged snapshot, not the working tree');

my (undef, $staged_passed) = run_hook('--staged');
is($staged_passed, 0, 'check-staged accepts the same staged snapshot');

my ($worktree_refused, $worktree_refused_status) = run_hook('--worktree');
isnt($worktree_refused_status, 0,
    'check-worktree refuses the bad working tree while the index is good');
like($worktree_refused, qr/check-worktree: the checks failed against the working tree/,
    'the worktree check names the tree it read');
like($worktree_refused, qr/preflight-unreachable\.json/,
    'the worktree check names the document at fault');
unlike($worktree_refused, qr/nothing has been committed/,
    'a failed worktree target does not claim a commit was refused');
like($worktree_refused, qr/make check-worktree/,
    'the worktree failure says how to run the check again');
unlike($worktree_refused, qr/stage it/,
    'the worktree advice does not tell the reader to stage the fix');

# The live-knob check has the same duty for the other agreement: a live test
# that reads a knob without the LIVE_TESTING prefix is what it exists to
# catch, and a clean working tree must not hide the staged edit.  The schema
# fixture is put back first, so a worktree run here sees only the live change.
spew($fixture, $shipped);

my $live_test = File::Spec->catfile($repository, 't', 'real-docker.t');
my $live_source = slurp($live_test);
my $unprefixed = "\$ENV{UNPREFIXED_KNOB} = 'test';\n" . $live_source;

spew($live_test, $unprefixed);
in_repository([ 'add', 't/real-docker.t' ]);
spew($live_test, $live_source);

my ($live_refused, $live_refused_status) = run_hook();
isnt($live_refused_status, 0,
    'the hook refuses a live knob that is staged without its prefix');
like($live_refused, qr/UNPREFIXED_KNOB/, 'the refusal names the knob');
like($live_refused, qr/live knobs/, 'the refusal names the check that failed');
like($live_refused, qr/no-verify/, 'the refusal says how to skip the check');

my (undef, $worktree_live_passed) = run_hook('--worktree');
is($worktree_live_passed, 0,
    'check-worktree accepts the good live test while the index is stale');

# The other half: the staged test is sound and the edit that would break it
# sits only in the working tree, so the commit has to pass.
in_repository([ 'add', 't/real-docker.t' ]);
spew($live_test, $unprefixed);

my (undef, $live_passed) = run_hook();
is($live_passed, 0, 'the live check reads the staged snapshot, not the working tree');

my ($worktree_live_refused, $worktree_live_status) = run_hook('--worktree');
isnt($worktree_live_status, 0,
    'check-worktree refuses the bad live test while the index is good');
like($worktree_live_refused, qr/UNPREFIXED_KNOB/,
    'the worktree check names the knob at fault');
like($worktree_live_refused, qr/live knobs/,
    'the worktree check names the check that failed');

spew($live_test, $live_source);

# An untracked fixture is part of the working tree but absent from every git
# diff, so check-worktree has to run the schema check anyway rather than
# filtering on the files git can name.  A bad version in a file that was never
# added is exactly the case the documented behaviour promises to catch.
my $untracked_fixture = File::Spec->catfile(
    $repository, 't', 'fixtures', 'untracked-example.json',
);
(my $untracked_document = $shipped) =~ s/"schema_version"\s*:\s*\d+/"schema_version": 2/;
spew($untracked_fixture, $untracked_document);

my ($untracked_out, $untracked_status) = run_hook('--worktree');
isnt($untracked_status, 0,
    'check-worktree refuses an invalid untracked fixture');
like($untracked_out, qr/untracked-example\.json/,
    'the worktree check names the untracked fixture');

unlink $untracked_fixture
    or die "cannot remove '$untracked_fixture': $!\n";

# The make target is what a developer actually runs, so generate its Makefile
# and run it rather than only the hook mode it invokes.  The bad fixture is
# untracked, which also keeps the documented untracked-file behaviour covered
# through the target.
{
    my ($configure_out, $configure_status) = run_in_repository($^X, 'Makefile.PL');
    is($configure_status, 0,
        'the repository generates a Makefile for check-worktree')
        or diag $configure_out;

    SKIP: {
        skip 'the generated Makefile is not available', 4
            unless $configure_status == 0;

        my $makefile = slurp(File::Spec->catfile($repository, 'Makefile'));
        like($makefile, qr/^check-worktree:/m,
            'the generated Makefile carries the check-worktree target');

        my $make = $Config{make};
        my (undef, $make_status) = run_in_repository($make, '-n', 'check-worktree');
        skip "the configured make command '$make' cannot run the target", 3
            unless $make_status == 0;

        my $target_fixture = File::Spec->catfile(
            $repository, 't', 'fixtures', 'target-untracked.json',
        );
        (my $target_document = $shipped) =~ s/"schema_version"\s*:\s*\d+/"schema_version": 2/;
        spew($target_fixture, $target_document);

        my ($target_out, $target_status) = run_in_repository(
            $make, 'check-worktree',
        );
        isnt($target_status, 0,
            'make check-worktree refuses an invalid untracked fixture');
        like(
            $target_out,
            qr/check-worktree: the checks failed against the working tree/,
            'the target output names the worktree check',
        );
        like($target_out, qr/target-untracked\.json/,
            'the target output names the untracked fixture');

        unlink $target_fixture
            or die "cannot remove '$target_fixture': $!\n";
    }
}

done_testing;
