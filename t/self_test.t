use strict;
use warnings;
use Test::Most;
use Capture::Tiny qw(capture);
use Fcntl qw(:flock);
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);

use App::Actions::Docker;
use App::Actions::Process;

# The tool run on the workflows the distribution ships, through the command a
# user runs rather than the library: bin/action-run <workflow> <project>.  The
# first proves the command surface - a container started, the project mounted
# into it, a step given its environment, what the step printed, everything
# removed - and the second runs the tool's own command in a Perl image, so
# action-run is exercised where it is being tested rather than only from the
# checkout that started it.  The fake Docker executes step scripts, so both
# are covered without a daemon; with LIVE_TESTING=1 the same workflows run in
# real containers, which is the part a fake cannot claim.
my $root = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
my $workflow = File::Spec->catfile($root, 't', 'lib', 'self_test.yml');
my $cli_workflow = File::Spec->catfile($root, 't', 'lib', 'self_test_cli.yml');
my $script   = File::Spec->catfile($root, 'bin', 'action-run');

# The workflows and the command are part of the distribution, so one missing is
# a packaging fault rather than an environment without Docker: it is worth
# failing for even when the run would be skipped, because the suite would
# otherwise pass without the file the self test is about.
BAIL_OUT("cannot find '$workflow'; the self test would have nothing to run")
    unless -f $workflow;
BAIL_OUT("cannot find '$cli_workflow'; the self test would have nothing to run")
    unless -f $cli_workflow;
BAIL_OUT("cannot find '$script'; the self test would have nothing to run it with")
    unless -f $script;

my $live = defined $ENV{LIVE_TESTING} && length $ENV{LIVE_TESTING}
    && $ENV{LIVE_TESTING} ne '0';

# Which half of the test this is decides what it proves, so the run says so
# rather than passing quietly: without the switch the steps run against the
# fake Docker, and nothing here has started a container.
diag $live
    ? 'LIVE_TESTING=1: running the workflow in a real container'
    : 'LIVE_TESTING is not set: running against the fake Docker, so the '
        . 'container path is not exercised; set LIVE_TESTING=1 to run it in '
        . 'a real container';

# Windows writes CRLF when output is redirected to a file, and the assertions
# below anchor on the end of a line.
sub useful_text {
    my ($text) = @_;
    return '' unless defined $text;
    $text =~ s/\r\n/\n/g;
    return $text;
}

# The command is the one in the documentation - the workflow, then the project
# directory - so the test covers the argument handling and the exit status as
# well as the run.
sub run_workflow_file {
    my ($docker, $file) = @_;

    my ($out, $err, $status) = capture {
        App::Actions::Process::stream([
            $^X, '-I' . File::Spec->catdir($root, 'lib'), $script,
            '--docker', $docker, $file, $root,
        ]);
    };

    return (useful_text($out), useful_text($err), $status);
}

# The containers a run starts are named action-run-*, so they can be listed
# and compared with what was there beforehand.
sub action_run_containers {
    my ($daemon) = @_;

    my ($output) = $daemon->capture_silent(
        'ps', '--all', '--quiet', '--filter', 'name=action-run',
    );

    return [ sort grep { length } split /\s+/, useful_text($output) ];
}

my ($docker, $state);
if ($live) {
	$docker = defined $ENV{DOCKER} && length $ENV{DOCKER} ? $ENV{DOCKER} : 'docker';
} else {
    $state = File::Spec->catdir(tempdir(CLEANUP => 1), 'state');
    $ENV{FAKE_DOCKER_STATE} = $state;
    $docker = File::Spec->catfile($root, 't', 'bin', 'fake-docker');

    ok(-f $docker, 'the fake daemon the self test runs against ships with the tests')
        or BAIL_OUT("cannot find '$docker'; the distribution is incomplete");
}

my $daemon = App::Actions::Docker->new(bin => $docker, quiet => 1);

my ($os_type, $info_rc) = $daemon->capture_silent(
    'info', '--format', '{{.OSType}}',
);
ok($info_rc == 0, 'the Docker daemon is reachable')
    or BAIL_OUT("'$docker info' failed; is Docker running and reachable?");

my $os = defined $os_type ? $os_type : '';
$os =~ s/\s+\z//;
is($os, 'linux', 'the Docker daemon runs Linux containers')
    or BAIL_OUT(
        "the Docker daemon reports OSType '$os', not 'linux'.  Point DOCKER_HOST "
        . 'at a daemon that runs Linux containers',
    );

# The live tests in this suite can overlap, and while one is running its
# containers are visible to all the others.  One lock in a fixed place keeps
# the cleanup check below from reporting somebody else's container, and this
# run's containers from being taken for somebody else's leak.  The fake daemon
# keeps its containers in its own state directory, so no other test can see
# them.
my %already;
my $live_lock;
if ($live) {
    my $lock_path = File::Spec->catfile(File::Spec->tmpdir, 'app-actions-real-docker.lock');
    open $live_lock, '>>', $lock_path
        or die "Unable to open '$lock_path': $!";
    flock($live_lock, LOCK_EX)
        or die "Unable to lock '$lock_path': $!";

    %already = map { $_ => 1 } @{ action_run_containers($daemon) };
    diag 'action-run containers already present before this test: '
        . join ' ', sort keys %already
        if %already;
}

my ($stdout, $stderr, $exit) = run_workflow_file($docker, $workflow);

diag "stdout:\n$stdout" if $exit != 0;
diag "stderr:\n$stderr" if length $stderr;

is($exit, 0, 'action-run runs the workflow it ships');
like($stdout, qr/^==> Job: self-test$/m, 'the job the workflow defines runs');
like($stdout, qr/^ {2}self-test\s+success$/m, 'the job summary reports success');
like($stdout, qr/^Workflow succeeded$/m, 'the run reports success');
# A step's own output is what shows the script ran rather than a log line
# saying it was found.  The fake daemon executes scripts on a host with a
# POSIX shell; on Windows it emulates them, so there is nothing to quote there
# and the live run is the one that covers a real container.
SKIP: {
    skip 'the fake daemon cannot execute step scripts on this host', 3
        unless $live || $^O ne 'MSWin32';

    like($stdout, qr/action-run is testing itself/,
        'a step ran and its output came back');
    like($stdout, qr/the project is visible in the container/,
        'the project is mounted where the step can read it');
    like($stdout, qr/the environment reached the step/,
        'a step environment variable reached the container');
}

# The second shipped workflow runs the tool itself inside a Perl image:
# "action-run schema check" and "action-run validate" are exercised from
# inside the container, through the command a user runs.
my ($cli_stdout, $cli_stderr, $cli_exit) = run_workflow_file($docker, $cli_workflow);

diag "stdout:\n$cli_stdout" if $cli_exit != 0;
diag "stderr:\n$cli_stderr" if length $cli_stderr;

is($cli_exit, 0, 'action-run runs the second workflow it ships');
like($cli_stdout, qr/^==> Job: self-test-cli$/m,
    'the Perl-image job runs');
like($cli_stdout, qr/^ {2}self-test-cli\s+success$/m,
    'the Perl-image job summary reports success');
like($cli_stdout, qr/^Workflow succeeded$/m,
    'the second workflow reports success');

SKIP: {
    skip 'the fake daemon cannot execute step scripts on this host', 3
        unless $live || $^O ne 'MSWin32';

    like($cli_stdout, qr/^the dependencies the tool needs are available$/m,
        'the image was ready for the tool to run');
    like($cli_stdout, qr/^the CLI printed its check schema inside the container$/m,
        "the tool's own command printed a schema from inside the container");
    like($cli_stdout, qr/^the CLI validated a document inside the container$/m,
        "the tool's own command validated a document from inside the container");
}

my @leftovers;
if ($live) {
    @leftovers = grep { !$already{$_} } @{ action_run_containers($daemon) };
}
else {
    opendir my $directory, $state or die "Unable to read '$state': $!";
    @leftovers = sort grep { /\Acontainer-/ } readdir $directory;
    closedir $directory;
}

is_deeply(\@leftovers, [], 'the self test leaves no containers behind');

if (@leftovers) {
    if ($live) {
        my ($detail) = $daemon->capture_silent(
            'ps', '--all', '--format', '{{.ID}} {{.Names}} {{.Image}} {{.Status}}',
            '--filter', 'name=action-run',
        );
        diag "action-run containers still present:\n" . useful_text($detail);
    }
    else {
        diag "container files left in $state: @leftovers\n";
    }
}

done_testing;
