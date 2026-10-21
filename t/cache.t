use strict;
use warnings;
use Test::Most;
use Capture::Tiny qw(capture);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP ();

use App::Actions;
use App::Actions::Cache;

my $root = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
my $lib  = File::Spec->catdir($root, 'lib');
my $script = File::Spec->catfile($root, 'bin', 'action-run');
my $fake_docker = File::Spec->catfile($root, 't', 'bin', 'fake-docker');

my $scratch = tempdir(CLEANUP => 1);

# Every run in this file records its images in the cache, so the record and the
# fake daemon both live under one temporary directory.
local $ENV{ACTION_RUN_CACHE_FILE} = File::Spec->catfile($scratch, 'cache.json');
local $ENV{ACTION_RUN_LOG_DIR} = File::Spec->catdir($scratch, 'logs');
local $ENV{FAKE_DOCKER_STATE} = File::Spec->catfile($scratch, 'docker');
local $ENV{FAKE_DOCKER_LOG} = File::Spec->catfile($scratch, 'docker.log');

# Windows writes CRLF when output is redirected to a file, and the matches
# below anchor on the end of a line.
sub useful_text {
    my ($text) = @_;
    return '' unless defined $text;
    $text =~ s/\r\n/\n/g;
    return $text;
}

sub run_cli {
    my (@args) = @_;

    my ($stdout, $stderr, $status) = capture {
        system($^X, '-I' . $lib, $script, @args);
    };

    # $? carries the POSIX-compatible status on Windows too.
    return (useful_text($stdout), useful_text($stderr), $status >> 8);
}

sub image_marker {
    my ($image) = @_;

    (my $name = $image) =~ s/[^A-Za-z0-9_.-]/_/g;
    return File::Spec->catfile($ENV{FAKE_DOCKER_STATE}, "image-$name");
}

is(App::Actions::Cache::format_size(0), '0 B', 'nothing is 0 B');
is(App::Actions::Cache::format_size(512), '512 B', 'a small size stays in bytes');
is(App::Actions::Cache::format_size(2048), '2.0 KB', 'a size over a kilobyte is reported in KB');
is(App::Actions::Cache::format_size(123_456_789), '117.7 MB',
    'the size the fake daemon reports is shown in MB');
is(App::Actions::Cache::format_size(undef), '0 B', 'an unknown size is 0 B');

{
    local $ENV{ACTION_RUN_CACHE_FILE}
        = File::Spec->catfile(tempdir(CLEANUP => 1), 'nested', 'cache.json');

    my $cache = App::Actions::Cache->new;
    is($cache->file, $ENV{ACTION_RUN_CACHE_FILE}, 'the record path is the one it was given');
    is_deeply($cache->entries, [], 'a record that does not exist has no images');

    is($cache->remember('alpine:3.20', 'perl:5.38'), 2, 'remember reports what it recorded');
    ok(-f $cache->file, 'recording an image creates the record, and its directory');

    my $reloaded = App::Actions::Cache->new(file => $cache->file);
    is_deeply(
        [ map { $_->{image} } @{ $reloaded->entries } ],
        [ 'alpine:3.20', 'perl:5.38' ],
        'the record survives a reload, sorted by image',
    );

    $reloaded->remember('alpine:3.20');
    my ($alpine) = grep { $_->{image} eq 'alpine:3.20' } @{ App::Actions::Cache->new(
        file => $cache->file,
    )->entries };
    is($alpine->{pulls}, 2, 'pulling an image again counts as another use');
    like($alpine->{last_used}, qr/\A\d+\z/, 'the record keeps when the image was last used');

    is($reloaded->forget('perl:5.38'), 1, 'forget reports the image it dropped');
    is(scalar @{ App::Actions::Cache->new(file => $cache->file)->entries }, 1,
        'the forgotten image stays forgotten');
    is($reloaded->forget('perl:5.38'), 0, 'forgetting an image twice is not an error');

    $reloaded->forget('alpine:3.20');
    ok(!-e $cache->file, 'the record goes away when its last image does');
}

{
    my $damaged = File::Spec->catfile(tempdir(CLEANUP => 1), 'cache.json');
    open my $handle, '>', $damaged or die $!;
    print {$handle} "{ this is not a cache\n";
    close $handle;

    is_deeply(
        App::Actions::Cache->new(file => $damaged)->entries,
        [],
        'a damaged record is treated as empty rather than failing a run',
    );
}

my $project = tempdir(CLEANUP => 1);
make_path(File::Spec->catdir($project, '.github', 'workflows'));
my $workflow = File::Spec->catfile($project, '.github', 'workflows', 'test.yml');
open my $workflow_handle, '>', $workflow or die $!;
print {$workflow_handle} <<'YAML';
name: Cache test
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo hello
YAML
close $workflow_handle;

{
    my (undef, $err, $exit) = run_cli('--docker', $fake_docker, $workflow, $project);
    is($exit, 0, 'the workflow run succeeds');
    is($err, '', 'the run writes nothing to standard error');

    ok(-f $ENV{ACTION_RUN_CACHE_FILE}, 'the run recorded the image it pulled');

    open my $handle, '<', $ENV{ACTION_RUN_CACHE_FILE} or die $!;
    my $text = do { local $/; <$handle> };
    close $handle;
    my $document = JSON::PP->new->decode($text);
    is_deeply(
        [ sort keys %{ $document->{images} } ],
        ['ubuntu:latest'],
        'the record names the image the run kept',
    );
}

{
    my ($out, $err, $exit) = run_cli('cache', '--docker', $fake_docker);
    is($exit, 0, 'cache exits 0');
    is($err, '', 'cache writes nothing to standard error');
    like($out, qr/^Cache file: \Q$ENV{ACTION_RUN_CACHE_FILE}\E$/m, 'cache names the record it read');
    like($out, qr/^  IMAGE\s+SIZE\s+LAST USED$/m, 'cache has a header');
    like($out, qr/^  ubuntu:latest\s+117\.7 MB\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/m,
        'cache lists the image with its size and when it was last used');
    like($out, qr/^1 image, 117\.7 MB on disk\.$/m, 'cache totals what the record holds');
}

{
    my ($out, $err, $exit) = run_cli('cache', '--prune', '--docker', $fake_docker);
    is($exit, 0, 'prune exits 0');
    is($err, '', 'prune writes nothing to standard error');
    like($out, qr/^Removed 1 image, 117\.7 MB freed\.$/m, 'prune says what it removed and freed');
    ok(!-e image_marker('ubuntu:latest'), 'prune removed the image from the daemon');
    ok(!-e $ENV{ACTION_RUN_CACHE_FILE}, 'prune forgot the image');

    open my $log, '<', $ENV{FAKE_DOCKER_LOG} or die $!;
    my $commands = do { local $/; <$log> };
    close $log;
    like($commands, qr/^image\trm\t-f\tubuntu:latest$/m,
        'prune asks Docker to remove the image rather than doing it itself');
}

{
    my ($out, $err, $exit) = run_cli('cache', '--docker', $fake_docker);
    is($exit, 0, 'an empty cache exits 0');
    like($out, qr/^No images have been cached yet\.$/m, 'an empty cache says so');
}

{
    # A record entry whose image has gone is shown, then forgotten without
    # asking Docker to remove what is not there.
    App::Actions::Cache->new->remember('alpine:3.20');

    my ($out, $err, $exit) = run_cli('cache', '--docker', $fake_docker);
    is($exit, 0, 'cache lists an image that is no longer there');
    like($out, qr/^  alpine:3\.20\s+missing\s+/m, 'a missing image is reported as missing');
    like($out, qr/^1 image is no longer on the daemon\.$/m, 'cache counts the missing images');

    ($out, $err, $exit) = run_cli('cache', '--prune', '--docker', $fake_docker);
    is($exit, 0, 'prune exits 0 when the image has already gone');
    like($out, qr/^Forgot 1 image no longer on the daemon\.$/m,
        'prune forgets an image it did not have to remove');
    ok(!-e $ENV{ACTION_RUN_CACHE_FILE}, 'the record is gone once it has nothing left');
}

{
    my (undef, undef, $exit) = run_cli('--docker', $fake_docker, $workflow, $project);
    is($exit, 0, 'the workflow runs again to rebuild the cache');

    local $ENV{FAKE_NO_DAEMON} = 1;

    my ($out, $err);
    ($out, $err, $exit) = run_cli('cache', '--docker', $fake_docker);
    is($exit, 0, 'listing works with the daemon stopped');
    like($out, qr/^  ubuntu:latest\s+unknown\s+/m,
        'the names are shown even when the sizes cannot be');
    like($out, qr/^The Docker daemon is not reachable, so the sizes are unknown\.$/m,
        'the listing says why the sizes are unknown');

    ($out, $err, $exit) = run_cli('cache', '--prune', '--docker', $fake_docker);
    is($exit, 2, 'prune without a daemon exits 2');
    like($err, qr/cannot prune the image cache/, 'the error says what could not be done');
    ok(-f $ENV{ACTION_RUN_CACHE_FILE}, 'a failed prune leaves the record alone');
    ok(-e image_marker('ubuntu:latest'), 'a failed prune leaves the image alone');
}

{
    my ($out, $err, $exit) = run_cli(
        '--prune', '--dry-run', $workflow, $project,
    );
    is($exit, 2, '--prune without the cache command is a usage error');
    like($err, qr/--prune is only used by the cache command/,
        'the error says where --prune belongs');
}

{
    my (undef, $err, $exit) = run_cli('cache', 'extra');
    is($exit, 2, 'cache takes no arguments');
    like($err, qr/Usage: action-run \[options\] cache \[--prune\]/,
        'the usage line says how to invoke cache');
}

done_testing;
