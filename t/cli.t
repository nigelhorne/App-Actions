use strict;
use warnings;
use Test::Most;
use Capture::Tiny qw(capture);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

my $root = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
my $lib = File::Spec->catdir($root, 'lib');
my $script = File::Spec->catfile($root, 'bin', 'action-run');
my $fake_docker = File::Spec->catfile($root, 't', 'bin', 'fake-docker');

sub make_project {
    my ($yaml) = @_;

    my $project = tempdir(CLEANUP => 1);
    make_path(File::Spec->catdir($project, '.github', 'workflows'));
    my $workflow = File::Spec->catfile($project, '.github', 'workflows', 'test.yml');
    open my $handle, '>', $workflow or die $!;
    print {$handle} $yaml;
    close $handle;

    return ($project, $workflow);
}

# Windows writes CRLF when a program's output is redirected to a file, and
# the tests below match against the end of the line.
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

my ($version_out, $version_err, $version_exit) = run_cli('--version');
is($version_exit, 0, '--version exits 0');
like($version_out, qr/^action-run 0\.01$/, '--version prints the version');

my ($help_out, $help_err, $help_exit) = run_cli('--help');
is($help_exit, 0, '--help exits 0');
like($help_out, qr/Usage:/, '--help prints usage');
like($help_out, qr/--dry-run/, '--help lists options');

my $yaml = <<'YAML';
name: CLI test
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        perl: ['5.38', '5.40']
    steps:
      - run: echo hello
YAML

my ($project, $workflow) = make_project($yaml);

my ($list_out, $list_err, $list_exit) = run_cli('--list', $workflow, $project);
is($list_exit, 0, '--list exits 0');
like($list_out, qr/^test\t/m, '--list shows job ids');
like($list_out, qr/test \(perl=5\.38\)/, '--list shows matrix display names');

my ($infer_out, $infer_err, $infer_exit) = run_cli('--list', $workflow);
is($infer_exit, 0, 'project directory can be inferred');
like($infer_out, qr/test \(perl=5\.40\)/, 'inferred project lists jobs');

my ($dry_out, $dry_err, $dry_exit) = run_cli('--dry-run', '--verbose', $workflow, $project);
is($dry_exit, 0, '--dry-run exits 0');
like($dry_out, qr/\[dry-run\]/, '--dry-run prints Docker commands');
like($dry_out, qr/--- script ---/, '--dry-run --verbose prints scripts');

my $state = tempdir(CLEANUP => 1);
local $ENV{FAKE_DOCKER_STATE} = $state;
local $ENV{FAKE_DOCKER_LOG} = File::Spec->catfile($state, 'docker.log');

my ($run_out, $run_err, $run_exit) = run_cli('--docker', $fake_docker, $workflow, $project);
is($run_exit, 0, 'CLI run with fake Docker succeeds');
like($run_out, qr/Workflow succeeded/, 'CLI prints a summary');
unlike($run_out, qr/^ {2}mount\s/m, 'the environment probe is silent when it passes');

{
    local $ENV{FAKE_OS_TYPE} = 'windows';
    my ($blocked_out, $blocked_err, $blocked_exit) = run_cli(
        '--docker', $fake_docker, $workflow, $project,
    );
    is($blocked_exit, 2, 'a run stops when the environment is not ready');
    like($blocked_out, qr/^ {2}problem\s+the daemon runs 'windows' containers/m,
        'the probe report explains the problem');
    like($blocked_err, qr/--skip-check/, 'the failure names the way past the probe');
    unlike($blocked_err, qr/ at \S+ line \d+/, 'the failure reads as a sentence');

    my ($skipped_out, $skipped_err, $skipped_exit) = run_cli(
        '--skip-check', '--docker', $fake_docker, $workflow, $project,
    );
    is($skipped_exit, 0, '--skip-check runs the workflow anyway');
    like($skipped_out, qr/Workflow succeeded/, '--skip-check reaches the workflow');
    is($skipped_err, '', '--skip-check reports no error');
}

my ($check_out, $check_err, $check_exit) = run_cli(
    '--docker', $fake_docker, 'check', $project,
);
is($check_exit, 0, 'check exits 0 when the environment is ready');
like($check_out, qr/^action-run check$/m, 'check names itself in the report');
like($check_out, qr/^ {2}daemon\s+.*linux containers$/m, 'check reports the daemon');
like($check_out, qr{-> /check-project: OK \(\d+ entr}, 'check probes the project directory');
like($check_out, qr/^Result: ready$/m, 'check reports ready');

my ($json_out, $json_err, $json_exit) = run_cli(
    '--docker', $fake_docker, 'check', '--json', $project,
);
is($json_exit, 0, 'check --json exits 0 when the environment is ready');
like($json_out, qr/^\{"docker":/, 'check --json prints one JSON object');
unlike($json_out, qr/^action-run check$/m, 'check --json prints no text report');
is($json_err, '', 'check --json writes nothing to standard error');

my ($json_first_out, undef, $json_first_exit) = run_cli(
    '--json', '--docker', $fake_docker, 'check', $project,
);
is($json_first_exit, 0, '--json before the command works too');
like($json_first_out, qr/^\{"docker":/, 'the option order does not matter');

my ($json_usage_out, $json_usage_err, $json_usage_exit) = run_cli(
    '--json', 'workflow.yml', 'project',
);
is($json_usage_exit, 2, '--json without check is a usage error');
like($json_usage_err, qr/only used by the check command/, 'the misuse is explained');

my ($check_usage_out, $check_usage_err, $check_usage_exit) = run_cli('check', 'a', 'b');
is($check_usage_exit, 2, 'check rejects more than one directory');
like($check_usage_err, qr/Usage: action-run \[options\] check \[directory\]/,
    'check explains its usage');

{
    local $ENV{FAKE_NO_DAEMON} = 1;
    my ($down_out, $down_err, $down_exit) = run_cli(
        '--docker', $fake_docker, 'check', $project,
    );
    is($down_exit, 2, 'check exits 2 when the daemon is unreachable');
    like($down_out, qr/^Result: not ready \(1 problem\)$/m, 'check reports the problem');
    like($down_out, qr/^ {2}remedy\s+\S/m, 'check prints a remedy beside the problem');
}

my ($missing_out, $missing_err, $missing_exit) = run_cli('--list', 'no-such-workflow.yml');
is($missing_exit, 2, 'missing workflow exits 2');
like($missing_err, qr/does not exist|not found/, 'missing workflow is reported');

my ($bad_job_out, $bad_job_err, $bad_job_exit) = run_cli(
    '--list', '--job', 'no-such-job', $workflow, $project,
);
is($bad_job_exit, 2, 'unknown job filter exits 2');
like($bad_job_err, qr/No job matched/, 'unknown job filter is reported');

my ($bad_env_out, $bad_env_err, $bad_env_exit) = run_cli(
    '--env', 'NOT_A_PAIR', '--list', $workflow, $project,
);
is($bad_env_exit, 2, 'invalid --env exits 2');
like($bad_env_err, qr/NAME=VALUE/, 'invalid --env is reported');

my ($conflict_out, $conflict_err, $conflict_exit) = run_cli(
    '--pull', '--no-pull', '--list', $workflow, $project,
);
is($conflict_exit, 2, 'conflicting pull options exit 2');
like($conflict_err, qr/cannot be used together/, 'conflicting pull options are reported');

done_testing;
