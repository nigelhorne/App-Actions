use strict;
use warnings;
use Test::Most;
use Capture::Tiny qw(capture);
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);

my $root = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
my $lib  = File::Spec->catdir($root, 'lib');
my $script = File::Spec->catfile($root, 'bin', 'action-run-smoke');
my $fake_docker = File::Spec->catfile($root, 't', 'bin', 'fake-docker');

my $state   = tempdir(CLEANUP => 1);
my $project = tempdir(CLEANUP => 1);

# The fake Docker keeps its state in FAKE_DOCKER_STATE and is handed to the
# smoke script through --docker, as a user would hand it their own wrapper.
local $ENV{FAKE_DOCKER_STATE} = $state;

# Windows writes CRLF when output is redirected to a file, and the checks
# below match against the end of a line.
sub useful_text {
    my ($text) = @_;
    return '' unless defined $text;
    $text =~ s/\r\n/\n/g;
    return $text;
}

sub run_smoke {
    my (@args) = @_;

    my ($stdout, $stderr, $status) = capture {
        system($^X, '-I' . $lib, $script, @args);
    };

    # $? carries the POSIX-compatible status on Windows too.
    return (useful_text($stdout), useful_text($stderr), $status >> 8);
}

my ($version_out, undef, $version_exit) = run_smoke('--version');
is($version_exit, 0, '--version exits 0');
like($version_out, qr/^action-run-smoke 0\.01$/m, '--version prints the version');

my ($help_out, undef, $help_exit) = run_smoke('--help');
is($help_exit, 0, '--help exits 0');
like($help_out, qr/Usage:/, '--help prints usage');
like($help_out, qr/--directory/, '--help lists the options');
like($help_out, qr/Docker Desktop/, '--help explains the Windows setup');

my (undef, $extra_err, $extra_exit) = run_smoke('unexpected');
is($extra_exit, 2, 'an unexpected argument is a usage error');
like($extra_err, qr/Usage: action-run-smoke/, 'the usage error explains itself');

my ($out, $err, $exit) = run_smoke(
    '--docker', $fake_docker, '--directory', $project,
);
is($exit, 0, 'a ready environment passes the smoke test');
like($out, qr/^action-run-smoke$/m, 'the report names itself');
like($out, qr/^ {2}host\s+\S.*perl \d/m, 'the host platform is reported');
like($out, qr/^ {2}daemon\s+26\.0\.0, linux containers$/m, 'the daemon is reported');
like($out, qr{^ {2}mount\s+\S.* -> /check-project: OK \(\d+ entr}m,
    'the directory is mounted');
like($out, qr/^ {2}workflow\s+one job, four steps/m, 'the workflow is described');
like($out, qr/Workflow succeeded/, 'the workflow runs against Docker');
like($out, qr/^Result: smoke test passed$/m, 'the result is reported once');
unlike($out, qr/^Result: ready$/m, 'the environment report leaves the verdict alone');
is($err, '', 'a passing smoke test writes nothing to standard error');

{
    local $ENV{FAKE_OS_TYPE} = 'windows';
    my ($windows_out, undef, $windows_exit) = run_smoke(
        '--docker', $fake_docker, '--directory', $project,
    );
    is($windows_exit, 2, 'a Windows-only daemon fails the smoke test');
    like($windows_out, qr/^ {2}problem\s+the daemon runs 'windows' containers/m,
        'the container type problem is explained');
    like($windows_out, qr/^ {2}problem\s+the environment is not ready/m,
        'the environment is named as the cause');
    like($windows_out, qr/^ {2}remedy\s+\S/m, 'the check supplies the remedy');
    like($windows_out, qr/^Result: smoke test failed$/m, 'the failure is reported');
    unlike($windows_out, qr/^ {2}workflow\s/, 'no workflow runs without Linux containers');
}

{
    local $ENV{FAKE_NO_DAEMON} = 1;
    my ($down_out, undef, $down_exit) = run_smoke(
        '--docker', $fake_docker, '--directory', $project,
    );
    is($down_exit, 2, 'an unreachable daemon fails the smoke test');
    like($down_out, qr/^ {2}problem\s+the daemon is not reachable/m,
        'the daemon problem is explained');
}

{
    local $ENV{FAKE_BAD_MOUNT} = 1;
    my ($mount_out, undef, $mount_exit) = run_smoke(
        '--docker', $fake_docker, '--directory', $project,
    );
    is($mount_exit, 2, 'a broken bind mount fails the smoke test');
    like($mount_out, qr/^ {2}problem\s+the container could not read the mounted/m,
        'the mount problem is explained');
}

# An environment that is fine but a workflow that is not has its own exit
# status, so that a broken App::Actions is not mistaken for a broken Docker.
my $failing_docker = File::Spec->catfile(tempdir(CLEANUP => 1), 'failing-docker');
{
    open my $handle, '>', $failing_docker or die $!;
    print {$handle} <<"PERL";
#!/usr/bin/env perl
# Delegate everything to the fake Docker, but fail every docker exec, which is
# where the steps run.
exit 1 if \@ARGV && \$ARGV[0] eq 'exec';
exec(\$^X, '$fake_docker', \@ARGV) or exit 127;
PERL
    close $handle;
    chmod 0755, $failing_docker;
}

my ($bad_out, undef, $bad_exit) = run_smoke(
    '--docker', $failing_docker, '--directory', $project,
);
is($bad_exit, 1, 'a failing workflow is reported as a workflow failure');
like($bad_out, qr/^ {2}problem\s+the smoke workflow failed/m,
    'the workflow failure is explained');
like($bad_out, qr/^Result: smoke test failed$/m, 'the failure is reported');

done_testing;
