use strict;
use warnings;
use Test::Most;
use Capture::Tiny qw(capture);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

my $script = File::Spec->rel2abs(
    File::Spec->catfile(dirname(__FILE__), '..', 'bin', 'action-run'),
);
my $fake_docker = File::Spec->rel2abs(
    File::Spec->catfile(dirname(__FILE__), 'bin', 'fake-docker'),
);
chmod 0755, $fake_docker;

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

sub run_cli {
    my (@args) = @_;

    my ($stdout, $stderr, $status) = capture {
        system($^X, '-Ilib', $script, @args);
    };

    return ($stdout, $stderr, $status >> 8);
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
