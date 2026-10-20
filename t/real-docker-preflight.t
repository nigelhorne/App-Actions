use strict;
use warnings;
use Test::Most;
use Capture::Tiny qw(capture);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

use App::Actions;
use App::Actions::Docker;

# The preflight against a real daemon, rather than the fake one used by the
# rest of the suite.  It is written for a Windows host running Docker Desktop
# with the WSL2 Linux engine, which is where the bind mounts, the daemon
# queries and the pull handling differ most from the development machine, but
# nothing here is Windows-specific: point DOCKER or DOCKER_HOST at any Linux
# daemon and it runs there too.
#
#     REAL_DOCKER=1 prove -l t/real-docker-preflight.t
#
# An image that cannot be pulled is how a real daemon is made to fail the
# probe and the image preparation: unlike a stopped daemon, it leaves the rest
# of the checks working.
my $enabled = defined $ENV{REAL_DOCKER} && length $ENV{REAL_DOCKER}
    && $ENV{REAL_DOCKER} ne '0';
plan skip_all => 'set REAL_DOCKER=1 to exercise the preflight against a real Docker daemon'
    unless $enabled;

my $docker = defined $ENV{DOCKER} && length $ENV{DOCKER} ? $ENV{DOCKER} : 'docker';
my $image  = defined $ENV{REAL_DOCKER_IMAGE} && length $ENV{REAL_DOCKER_IMAGE}
    ? $ENV{REAL_DOCKER_IMAGE}
    : 'alpine:3.20';

# Small images for the service and the action, so that the test is about the
# preflight and not about the download.
my $service_image = 'busybox:1.36';
my $action_image  = 'hello-world:latest';

my $missing_image = 'action-run-no-such-image-xyz:1';

# Windows writes CRLF when output is redirected to a file, and the matches
# below anchor on the end of a line.
sub useful_text {
    my ($text) = @_;
    return '' unless defined $text;
    $text =~ s/\r\n/\n/g;
    return $text;
}

sub run_workflow {
    my ($yaml, %options) = @_;

    my $project = tempdir(CLEANUP => 1);
    make_path(File::Spec->catdir($project, '.github', 'workflows'));
    my $file = File::Spec->catfile($project, '.github', 'workflows', 'test.yml');

    open my $handle, '>', $file or die $!;
    print {$handle} $yaml;
    close $handle;

    my $actions = App::Actions->new(
        workflow_file => $file,
        project_dir   => $project,
        docker_bin    => $docker,
        image         => $image,
        %options,
    );

    my ($stdout, $stderr, $exit) = capture { $actions->run };

    return {
        stdout  => useful_text($stdout),
        stderr  => useful_text($stderr),
        exit    => $exit,
        project => $project,
    };
}

sub trim {
    my ($value) = @_;

    return '' unless defined $value;
    $value =~ s/\s+//g;

    return $value;
}

my $daemon = App::Actions::Docker->new(bin => $docker, quiet => 1);

my ($os_type, $info_rc) = $daemon->capture_silent(
    'info', '--format', '{{.OSType}}',
);

ok($info_rc == 0, 'the Docker daemon is reachable')
    or BAIL_OUT("'$docker info' failed; is Docker running and reachable?");

(my $os = useful_text($os_type)) =~ s/\s+\z//;
is($os, 'linux', 'the Docker daemon runs Linux containers')
    or BAIL_OUT(
        "the Docker daemon reports OSType '$os', not 'linux'.  On Windows, "
        . 'switch Docker Desktop to the WSL2 Linux engine, or point DOCKER_HOST '
        . 'at a Linux daemon',
    );

# The probe must fail the run, before anything is started, when its container
# cannot run.  Waiting for Docker Desktop to finish starting would be a
# different test, so an image that cannot be pulled stands in for a broken
# environment.
my $failed_probe = run_workflow(<<"YAML");
name: Failing probe
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: $missing_image
    steps:
      - run: echo never
YAML

is($failed_probe->{exit}, 2, 'a probe that cannot run its container stops the run');
like($failed_probe->{stdout}, qr/^Result: not ready \(1 problem\)$/m,
    'the check reports the environment as not ready');
like($failed_probe->{stdout}, qr/probe container failed \(exit \d+\)/,
    'the problem is the probe container, not a guess');
like($failed_probe->{stdout}, qr/^ {2}remedy\s+\S/m,
    'the problem comes with a remedy');
like($failed_probe->{stderr}, qr/the environment is not ready/,
    'the run says the environment is at fault');
like($failed_probe->{stderr}, qr/--skip-check/,
    'the run points at --skip-check');
unlike($failed_probe->{stdout}, qr/==> Job:/, 'no job starts in a broken environment');

# Every image the job will need is prepared first, including the service
# image and the image of a docker:// action.  --pull makes the pulls visible
# even when Docker has the images cached.
my $with_images = <<"YAML";
name: Prepared images
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: $image
    services:
      helper:
        image: $service_image
    steps:
      - uses: docker://$action_image
        with:
          args: hello
      - run: echo after
YAML

my $prepared = run_workflow($with_images, pull => 1);

if ($prepared->{exit} != 0) {
    diag "stdout:\n$prepared->{stdout}";
    diag "stderr:\n$prepared->{stderr}" if length $prepared->{stderr};
}

is($prepared->{exit}, 0, 'a workflow with service and action images runs');
like($prepared->{stdout}, qr/Workflow succeeded/, 'the run reports success');
unlike($prepared->{stdout}, qr/^Result: ready$/m,
    'a passing probe prints no report');

my $job_start = index($prepared->{stdout}, '==> Job: test');
ok($job_start > 0, 'the job starts');

for my $wanted (
    [ $image,         'the job image' ],
    [ $service_image, 'the service image' ],
    [ $action_image,  'the docker:// action image' ],
) {
    my ($prepared_image, $description) = @$wanted;
    my $at = index($prepared->{stdout}, "Pulling image $prepared_image...");

    ok(
        $at >= 0 && $at < $job_start,
        "$description is pulled before the job container starts",
    );
}

unlike($prepared->{stdout}, qr/cannot prepare the image/,
    'nothing had to be reported as unready');

# An image that cannot be pulled is reported before the first container, with
# the service that needs it named.
my $broken_service = <<"YAML";
name: Broken service image
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: $image
    services:
      broken:
        image: $missing_image
    steps:
      - run: echo never
YAML

my $broken = run_workflow($broken_service);

if ($broken->{exit} != 2) {
    diag "stdout:\n$broken->{stdout}";
    diag "stderr:\n$broken->{stderr}" if length $broken->{stderr};
}

is($broken->{exit}, 2, 'an unpullable service image stops the run');
like(
    $broken->{stderr},
    qr/cannot prepare the image '\Q$missing_image\E', needed by service 'broken' of job 'test'/,
    'the failure names the image, the service, and the job',
);
unlike($broken->{stderr}, qr/ at \S+ line \d+/,
    'the failure reads as a sentence, not a source location');
unlike($broken->{stdout}, qr/==> Job:/, 'no job container is started');

# Nothing this test started is still running, on Windows or anywhere else.
my ($leftovers) = $daemon->capture_silent(
    'ps', '--quiet', '--filter', 'name=action-run',
);
is(trim($leftovers), '', 'no action-run containers are left behind');

done_testing;
