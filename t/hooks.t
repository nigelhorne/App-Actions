use strict;
use warnings;
use Test::Most;
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
copy_tree($root, $repository, $_) for qw(lib bin t .githooks);

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

sub run_hook {
    my $cwd = File::Spec->rel2abs(File::Spec->curdir);
    chdir $repository or die "cannot change to '$repository': $!\n";

    my ($output, $exit) = App::Actions::Process::capture([ $^X, $hook ], merge_stderr => 1);

    chdir $cwd or die "cannot change to '$cwd': $!\n";

    return ($output, $exit);
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

# The other half: the document that is staged is correct, and the edit that
# would break it sits in the working tree beside it.  The commit is fine, so
# the hook has to pass - which it only does by reading the staged document.
in_repository([ 'add', 't/fixtures/preflight-unreachable.json' ]);
spew($fixture, "$shipped\n");
in_repository([ 'add', 't/fixtures/preflight-unreachable.json' ]);
spew($fixture, $stale);

my (undef, $passed_status) = run_hook();
is($passed_status, 0, 'the hook checks the staged snapshot, not the working tree');

done_testing;
