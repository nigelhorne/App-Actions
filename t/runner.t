use strict;
use warnings;
use Test::Most;
use Capture::Tiny qw(capture);
use File::Basename qw(dirname);
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Temp qw(tempdir);

use App::Actions;

my $fake_docker = File::Spec->rel2abs(
    File::Spec->catfile(dirname(__FILE__), 'bin', 'fake-docker'),
);

# Windows writes CRLF when output is redirected to a file, and several tests
# match against the end of a line.
sub useful_text {
    my ($text) = @_;
    return '' unless defined $text;
    $text =~ s/\r\n/\n/g;
    return $text;
}

# Read a file without any newline translation, the way a Linux container sees
# it.
sub slurp_bytes {
    my ($path) = @_;

    open my $handle, '<', $path or die $!;
    binmode $handle;
    local $/;
    my $bytes = <$handle>;
    close $handle;

    return defined $bytes ? $bytes : '';
}

# A run with keep => 1 prints the temporary directory it retained.
sub kept_temp_dir {
    my ($result) = @_;

    my ($dir) = $result->{stdout} =~ /^ {2}temporary directory (.+)$/m;
    return $dir;
}

sub remove_kept_dir {
    my ($result) = @_;

    my $dir = kept_temp_dir($result);
    remove_tree($dir) if defined $dir && -d $dir;

    return;
}

sub run_workflow {
    my ($yaml, %options) = @_;

    my $project = tempdir(CLEANUP => 1);
    make_path(File::Spec->catdir($project, '.github', 'workflows'));
    my $workflow_file = File::Spec->catfile($project, '.github', 'workflows', 'test.yml');

    open my $handle, '>', $workflow_file or die $!;
    print {$handle} $yaml;
    close $handle;

    for my $path (sort keys %{ $options{files} || {} }) {
        my $target = File::Spec->catfile($project, split m{/}, $path);
        make_path(dirname($target));
        open my $file, '>', $target or die $!;
        print {$file} $options{files}{$path};
        close $file;
    }

    my $state = tempdir(CLEANUP => 1);
    my $log   = File::Spec->catfile($state, 'docker.log');

    local $ENV{FAKE_DOCKER_STATE} = $state;
    local $ENV{FAKE_DOCKER_LOG}   = $log;
    local $ENV{FAKE_NO_BASH}      = $options{fake_no_bash} ? 1 : 0;
    local $ENV{FAKE_NO_SUDO}      = $options{fake_no_sudo} ? 1 : 0;
    local $ENV{FAKE_NO_NODE}      = $options{fake_no_node} ? 1 : 0;
    local $ENV{FAKE_OS_TYPE}      = $options{fake_os_type};
    local $ENV{FAKE_ENTRY_COUNT}  = $options{fake_entry_count};
    local $ENV{FAKE_PULL_FAILURE} = $options{fake_pull_failure};

    my $actions = App::Actions->new(
        workflow_file => $workflow_file,
        project_dir   => $project,
        docker_bin    => $fake_docker,
        image         => 'ubuntu:latest',
        %options,
    );

    my ($stdout, $stderr, $exit) = capture { $actions->run };
    $stdout = useful_text($stdout);
    $stderr = useful_text($stderr);

    my $log_text = '';
    if (-f $log) {
        open my $log_handle, '<', $log or die $!;
        local $/;
        $log_text = <$log_handle>;
        close $log_handle;
        $log_text = '' unless defined $log_text;
    }

    return {
        stdout   => $stdout,
        stderr   => $stderr,
        exit     => $exit,
        log      => $log_text,
        project  => $project,
        state    => $state,
    };
}

my $matrix = run_workflow(<<'YAML');
name: Matrix
on: push
jobs:
  test:
    name: Perl ${{ matrix.perl }}
    runs-on: ubuntu-latest
    strategy:
      matrix:
        perl: ['5.38', '5.40']
    container:
      image: perl:${{ matrix.perl }}
    steps:
      - uses: actions/checkout@v4
      - name: Set files
        run: |
          FAKE_ENV: FROM_STEP=one
          FAKE_PATH: /opt/fake/bin
      - name: Use files
        run: echo $FROM_STEP
YAML

is($matrix->{exit}, 0, 'matrix workflow succeeds');
like($matrix->{stdout}, qr/Perl 5\.38/, 'first matrix job ran');
like($matrix->{stdout}, qr/Perl 5\.40/, 'second matrix job ran');
like($matrix->{stdout}, qr/Set files/, 'step names are shown');
like($matrix->{log}, qr/^pull\t/m, 'missing images are pulled');
like($matrix->{log}, qr/\t-e\tFROM_STEP=one\t/, 'GITHUB_ENV updates reach later steps');
like($matrix->{log}, qr/\t-e\tPATH=\/opt\/fake\/bin:/, 'GITHUB_PATH updates reach later steps');
like($matrix->{log}, qr/^rm\t-f\t/m, 'containers are removed');
like($matrix->{log}, qr/^network\trm\t/m, 'networks are removed');
like($matrix->{log}, qr/^image\trm\t-f\tperl:5\.38$/m, 'pulled Perl 5.38 image is removed');
like($matrix->{log}, qr/^image\trm\t-f\tperl:5\.40$/m, 'pulled Perl 5.40 image is removed');

my $failure = run_workflow(<<'YAML');
name: Failure
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Fail
        run: |
          FAKE_EXIT: 7
YAML

is($failure->{exit}, 1, 'failing workflow exits 1');
like($failure->{stderr}, qr/step exited with status 7/, 'step failure is reported');
like($failure->{log}, qr/^rm\t-f\t/m, 'failed runs still clean up containers');

my $skipped = run_workflow(<<'YAML');
name: Windows only
on: push
jobs:
  test:
    runs-on: windows-latest
    steps:
      - run: echo nope
YAML

is($skipped->{exit}, 0, 'workflow with only unsupported jobs exits 0');
like($skipped->{stdout}, qr/skipped: runs-on 'windows-latest' is not Linux/,
    'unsupported runner is explained');

my $dry_run = run_workflow(<<'YAML', dry_run => 1);
name: Dry run
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo hello
YAML

is($dry_run->{exit}, 0, 'dry run succeeds without Docker');
like($dry_run->{stdout}, qr/\[dry-run\]/, 'dry run prints Docker commands');

my $outputs = run_workflow(<<'YAML');
name: Outputs
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Build
        id: build
        run: |
          FAKE_OUTPUT: result=ok
      - name: Use output
        if: steps.build.outputs.result == 'ok'
        run: echo yes
YAML

is($outputs->{exit}, 0, 'step outputs workflow succeeds');
like($outputs->{log}, qr/step-2\.sh/, 'step using an output ran');
like($outputs->{log}, qr/GITHUB_OUTPUT/, 'GITHUB_OUTPUT is passed to steps');

my $needs = run_workflow(<<'YAML');
name: Needs
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Build
        run: |
          FAKE_EXIT: 1
  test:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - name: Test
        run: echo test
  always:
    needs: build
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Always
        run: |
          FAKE_SUMMARY: always ran
YAML

is($needs->{exit}, 1, 'failed dependency fails the workflow');
like($needs->{stdout}, qr/Job: test \(skipped\)/, 'dependent job is skipped');
like($needs->{stdout}, qr/Job: always/, 'always() job runs after a failed dependency');
like($needs->{stdout}, qr/always ran/, 'always() step summary is printed');

my $services = run_workflow(<<'YAML');
name: Services
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: alpine:3.20
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: secret
        ports:
          - 5432:5432
    steps:
      - run: echo hello
YAML

is($services->{exit}, 0, 'workflow with services succeeds');
like($services->{log}, qr/--network-alias\tpostgres/, 'service is attached to the job network');
like($services->{log}, qr/\t-e\tPOSTGRES_PASSWORD=secret\t/, 'service environment is passed');
like($services->{log}, qr/\t-p\t5432:5432\t/, 'service ports are published');
my @service_removals = ($services->{log} =~ /^rm\t-f\t/gm);
is(scalar @service_removals, 2, 'job and service containers are removed');

my $docker_action = run_workflow(<<'YAML');
name: Docker action
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Action
        id: action
        uses: docker://alpine:3.20
        with:
          args: FAKE_ACTION
      - name: After
        if: steps.action.outputs.result == 'ok'
        run: echo after
YAML

is($docker_action->{exit}, 0, 'docker action workflow succeeds');
like($docker_action->{log}, qr/^run\t--rm\t/m, 'docker action uses a one-shot container');
like($docker_action->{log}, qr/\t-e\tFROM_ACTION=yes\t/, 'docker action environment update is applied');
like($docker_action->{log}, qr/step-2\.sh/, 'step after docker action ran');

my $no_bash = run_workflow(<<'YAML', fake_no_bash => 1);
name: No bash
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: alpine:3.20
    steps:
      - run: echo hello
YAML

is($no_bash->{exit}, 0, 'default shell falls back to sh when bash is absent');
like($no_bash->{log}, qr/sh -e '/, 'sh is used when bash is absent');

my $no_sudo = run_workflow(<<'YAML', fake_no_sudo => 1);
name: No sudo
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: alpine:3.20
    steps:
      - run: echo hello
YAML

is($no_sudo->{exit}, 0, 'workflow without sudo succeeds');
like($no_sudo->{log}, qr/\t-e\tPATH=\/github\/actions-runner\/bin:/,
    'sudo shim directory is added to PATH when sudo is absent');

my $user_no_sudo = run_workflow(<<'YAML', fake_no_sudo => 1, user => '1000:1000');
name: User no sudo
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: alpine:3.20
    steps:
      - run: echo hello
YAML

is($user_no_sudo->{exit}, 0, 'workflow with --user succeeds');
unlike($user_no_sudo->{log}, qr/\t-e\tPATH=\/github\/actions-runner\/bin:/,
    'sudo shim is not added when a container user is requested');

my $explicit_bash = run_workflow(<<'YAML', fake_no_bash => 1);
name: Explicit bash
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: alpine:3.20
    steps:
      - run: echo hello
        shell: bash
YAML

is($explicit_bash->{exit}, 1, 'explicit bash fails when bash is absent');
like($explicit_bash->{stderr}, qr/Shell 'bash' is not available/,
    'missing explicit shell is reported');

my $strict = run_workflow(<<'YAML', strict_actions => 1);
name: Strict
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: some/unknown-action@v1
YAML

is($strict->{exit}, 1, 'strict mode fails on an unknown action');
like($strict->{stderr}, qr/skipped: remote JavaScript and composite actions are not supported/,
    'strict mode explains the unsupported action');

my $keep = run_workflow(<<'YAML', keep => 1);
name: Keep
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo hello
YAML

is($keep->{exit}, 0, 'keep workflow succeeds');
like($keep->{stdout}, qr/Kept Docker resources/, 'keep reports the resources it retained');
unlike($keep->{log}, qr/^rm\t-f\t/m, 'keep does not remove containers');
remove_kept_dir($keep);

# bash inside the container rejects scripts whose lines end in CR, so every
# file the container reads must be written with LF even when the host is
# Windows.
my $line_endings = run_workflow(<<'YAML', keep => 1);
name: Line endings
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Script
        run: |
          FAKE_ENV: FROM_STEP=one
YAML

is($line_endings->{exit}, 0, 'line ending workflow succeeds');

my $temp_dir = kept_temp_dir($line_endings);
ok(defined $temp_dir, 'the kept temporary directory is reported');

if (defined $temp_dir) {
    for my $relative (qw(scripts/step-1.sh bin/sudo aptbin/apt aptbin/apt-get event.json)) {
        my $path = File::Spec->catfile($temp_dir, split m{/}, $relative);
        ok(-f $path, "$relative is written");
        unlike(slurp_bytes($path), qr/\r/, "$relative keeps LF line endings");
    }
    remove_kept_dir($line_endings);
}

my $keep_images = run_workflow(<<'YAML', keep_images => 1);
name: Keep images
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo hello
YAML

is($keep_images->{exit}, 0, 'keep-images workflow succeeds');
like($keep_images->{log}, qr/^rm\t-f\t/m, 'keep-images still removes containers');
unlike($keep_images->{log}, qr/^image\trm\t/m, 'keep-images leaves images in place');

my $implicit_success = run_workflow(<<'YAML');
name: Implicit success
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Fail early
        run: |
          FAKE_EXIT: 9
      - name: Plain condition
        if: runner.os == 'Linux'
        run: echo should-not-run
      - name: Status condition
        if: failure()
        run: echo failure-handler
      - name: Always
        if: always()
        run: echo always-runs
YAML

is($implicit_success->{exit}, 1, 'workflow with a failing step exits 1');
like($implicit_success->{stdout}, qr/Plain condition \(skipped\)/,
    'if without a status function implies success()');
unlike($implicit_success->{stdout}, qr/Status condition \(skipped\)/,
    'failure() is not short-circuited by the failing job');
unlike($implicit_success->{stdout}, qr/Always \(skipped\)/,
    'always() runs after a failure');

my $apt_path = run_workflow(<<'YAML');
name: Apt shims
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo hello
YAML

like($apt_path->{log}, qr/\t-e\tPATH=\/github\/actions-runner\/aptbin:/,
    'apt shim directory is added to PATH');
like($apt_path->{log}, qr/\t-e\tDEBIAN_FRONTEND=noninteractive\t/,
    'package installation runs non-interactively');

my $redacted = run_workflow(<<'YAML', dry_run => 1, verbose => 1, secrets => { TOKEN => 'super-secret-value' });
name: Secret
on: push
jobs:
  test:
    name: Auth ${{ secrets.TOKEN }}
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ secrets.TOKEN }}"
YAML

is($redacted->{exit}, 0, 'secret dry-run succeeds');
like($redacted->{stdout}, qr/\*\*\*/, 'secret values are redacted in dry-run scripts');
unlike($redacted->{stdout}, qr/super-secret-value/, 'secret values do not appear in output');
unlike($redacted->{stderr}, qr/super-secret-value/, 'secret values do not appear in error output');

my $composite_action = <<'YAML';
name: Greet
inputs:
  who:
    description: Who to greet
    default: world
outputs:
  greeting:
    value: ${{ steps.say.outputs.message }}
  where:
    value: ${{ steps.report.outputs.where }}
runs:
  using: composite
  steps:
    - id: say
      name: Say hello
      shell: sh
      run: |
        FAKE_OUTPUT: message=hello-${{ inputs.who }}
        FAKE_ENV: FROM_COMPOSITE=yes
    - id: report
      name: Report path
      shell: sh
      run: |
        FAKE_OUTPUT: where=${{ github.action_path }}
        FAKE_PATH: /opt/composite/bin
YAML

my $outer_action = <<'YAML';
name: Outer
inputs:
  who:
    default: outer-default
outputs:
  greeting:
    value: ${{ steps.inner.outputs.greeting }}
  where:
    value: ${{ steps.inner.outputs.where }}
runs:
  using: composite
  steps:
    - id: inner
      uses: ./.github/actions/greet
      with:
        who: ${{ inputs.who }}
YAML

my $composite = run_workflow(<<'YAML', files => {
name: Composite
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Use the action
        id: greet
        uses: ./.github/actions/outer
        with:
          who: Nigel
      - name: Check the output
        if: steps.greet.outputs.greeting == 'hello-Nigel'
        run: echo output-ok
      - name: Check the environment
        if: env.FROM_COMPOSITE == 'yes'
        run: echo env-ok
      - name: Check the action path
        if: contains(steps.greet.outputs.where, '/github/workspace/.github/actions/greet')
        run: echo path-ok
YAML
    '.github/actions/greet/action.yml' => $composite_action,
    '.github/actions/outer/action.yml' => $outer_action,
});

is($composite->{exit}, 0, 'composite action workflow succeeds');
like($composite->{stdout}, qr/^ {4}--- Step: Say hello$/m,
    'nested composite steps are indented');
unlike($composite->{stdout}, qr/Say hello \(skipped\)/,
    'composite steps run');
unlike($composite->{stdout}, qr/Check the output \(skipped\)/,
    'nested composite outputs reach the caller');
unlike($composite->{stdout}, qr/Check the environment \(skipped\)/,
    'GITHUB_ENV changes inside a composite reach later steps');
unlike($composite->{stdout}, qr/Check the action path \(skipped\)/,
    'github.action_path points at the action directory');
like($composite->{log}, qr/\t-e\tFROM_COMPOSITE=yes\t/,
    'composite environment changes are exported to the job');
like($composite->{log}, qr/\t-e\tPATH=\/opt\/composite\/bin:/,
    'GITHUB_PATH changes inside a composite reach later steps');
like($composite->{log}, qr/\t-e\tGITHUB_ACTION_PATH=\/github\/workspace\/\.github\/actions\/greet\t/,
    'composite scripts see GITHUB_ACTION_PATH');

my $js_action = <<'YAML';
name: JavaScript
inputs:
  who:
    default: default-name
runs:
  using: node20
  main: main.js
  pre: pre.js
  post: post.js
YAML

my $javascript = run_workflow(<<'YAML', files => {
name: JavaScript
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Run the action
        id: js
        uses: ./.github/actions/js
        with:
          who: Nigel
      - name: Check the output
        if: steps.js.outputs.answer == '42'
        run: echo output-ok
      - name: Check the environment
        if: env.FROM_JS == 'yes'
        run: echo env-ok
YAML
    '.github/actions/js/action.yml' => $js_action,
    '.github/actions/js/pre.js'  => "// FAKE_ENV: FROM_PRE=yes\n",
    '.github/actions/js/main.js' => "// FAKE_OUTPUT: answer=42\n// FAKE_ENV: FROM_JS=yes\n",
    '.github/actions/js/post.js' => "// FAKE_ENV: FROM_POST=yes\n",
});

is($javascript->{exit}, 0, 'JavaScript action workflow succeeds');
like($javascript->{log}, qr/\tnode\t\/github\/workspace\/\.github\/actions\/js\/pre\.js/,
    'the pre step runs before the main step');
like($javascript->{log}, qr/\tnode\t\/github\/workspace\/\.github\/actions\/js\/main\.js/,
    'the main entry point runs');
like($javascript->{log}, qr/\tnode\t\/github\/workspace\/\.github\/actions\/js\/post\.js/,
    'the post step runs');
like($javascript->{log}, qr/\t-e\tINPUT_WHO=Nigel\t/,
    'action inputs are passed as INPUT_* variables');
like($javascript->{log}, qr/\t-e\tGITHUB_ACTION_PATH=\/github\/workspace\/\.github\/actions\/js\t/,
    'JavaScript actions see GITHUB_ACTION_PATH');
like($javascript->{log}, qr/\t-e\tFROM_PRE=yes\t/, 'the pre step can export variables');
like($javascript->{log}, qr/\t-e\tFROM_JS=yes\t/, 'the main step can export variables');
like($javascript->{log}, qr/\t-e\tGITHUB_ACTION=js\t.*post\.js/s,
    'the post step runs with the job environment');
unlike($javascript->{stdout}, qr/Check the output \(skipped\)/,
    'JavaScript action outputs reach later steps');
unlike($javascript->{stdout}, qr/Check the environment \(skipped\)/,
    'JavaScript action environment changes reach later steps');

my $main_position = index($javascript->{log}, 'actions/js/main.js');
my $post_position = index($javascript->{log}, 'actions/js/post.js');
ok($main_position >= 0, 'the main step is logged');
ok($post_position > $main_position, 'the post step runs after the main step');

my $no_node = run_workflow(<<'YAML', files => {
name: No node
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/js
YAML
    '.github/actions/js/action.yml' => $js_action,
    '.github/actions/js/main.js'    => "// FAKE_OUTPUT: answer=42\n",
}, fake_no_node => 1);

is($no_node->{exit}, 1, 'a JavaScript action without node fails');
like($no_node->{stderr}, qr/needs Node\.js/, 'missing node is explained');

my $missing_action = run_workflow(<<'YAML');
name: Missing action
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/absent
YAML

is($missing_action->{exit}, 1, 'a missing local action fails');
like($missing_action->{stderr}, qr/Local action .* does not exist/,
    'a missing local action is reported');
unlike($missing_action->{stderr}, qr/cannot prepare the image/,
    'the preflight leaves a missing action to the step that uses it');

my $escaping_action = run_workflow(<<'YAML');
name: Escaping action
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: ../../etc
YAML

is($escaping_action->{exit}, 1, 'a local action outside the project fails');
like($escaping_action->{stderr}, qr/must not escape the project/,
    'a local action outside the project is rejected');

my $broken_action = run_workflow(<<'YAML', files => {
name: Broken action
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/broken
YAML
    '.github/actions/broken/action.yml' => "name: Broken\n",
});

is($broken_action->{exit}, 1, 'an action without runs fails');
like($broken_action->{stderr}, qr/has no 'runs' mapping/,
    'broken action metadata is reported');

# The environment is probed before any job starts, using the image the job
# will use, and the probe is silent when it passes.
my $simple = <<'YAML';
name: Plain
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: perl:5.38
    steps:
      - run: echo hello
YAML

my $probed = run_workflow($simple);
is($probed->{exit}, 0, 'a workflow still runs when the probe passes');
like($probed->{log}, qr/^run\t--rm\t--network\tnone\t/m,
    'the bind mount is probed before the workflow starts');
like($probed->{log}, qr/\t-v\t[^\t]+:\/check-project:ro\t/,
    'the probe mounts the project directory read-only');
unlike($probed->{stdout}, qr/^ {2}mount\s/m, 'a passing probe says nothing');

# Probe image: the job's own image, so a working setup needs no extra pull.
unlike($probed->{log}, qr/^pull\t.*alpine:3\.20/m,
    'the probe does not pull an image the run does not need');
like($probed->{log}, qr/:ro\tperl:5\.38\t/,
    'the probe uses the image the job will use');

my $verbose_probe = run_workflow($simple, verbose => 1);
is($verbose_probe->{exit}, 0, 'a verbose run passes the probe');
like($verbose_probe->{stdout}, qr/^ {2}mount\s+\S.* -> \/check-project: OK/m,
    'a verbose run shows the probe report');

# A broken environment stops the run before a job container is started.
my $not_ready = run_workflow($simple, fake_os_type => 'windows');
is($not_ready->{exit}, 2, 'a broken environment stops the run');
like($not_ready->{stderr}, qr/the environment is not ready/,
    'the run says the environment is at fault');
like($not_ready->{stderr}, qr/--skip-check/, 'the run points at --skip-check');
unlike($not_ready->{stderr}, qr/ at \S+ line \d+/,
    'the failure message is not decorated with a source location');
unlike($not_ready->{log}, qr/^exec\t/m, 'no step runs in a broken environment');

my $hidden_project = run_workflow($simple, fake_entry_count => 0);
is($hidden_project->{exit}, 2, 'a project the container cannot see stops the run');
like($hidden_project->{stderr}, qr/the environment is not ready/,
    'the unshared drive is reported before the job starts');
unlike($hidden_project->{log}, qr/^exec\t/m, 'nothing runs with an unreadable project');

# --skip-check is the escape hatch.
my $unchecked = run_workflow($simple, fake_os_type => 'windows', skip_check => 1);
is($unchecked->{exit}, 0, 'skip_check runs the workflow anyway');
like($unchecked->{stdout}, qr/Workflow succeeded/, 'the workflow runs with skip_check');
unlike($unchecked->{log}, qr/--network\tnone\t/m, 'skip_check skips the probes');
like($unchecked->{log}, qr/^info\t/m, 'skip_check still asks whether Docker is there');

my $skipped_hidden = run_workflow($simple, fake_entry_count => 0, skip_check => 1);
is($skipped_hidden->{exit}, 0, 'skip_check ignores an unreadable project');

# Every image the run needs is prepared before the first job starts, so a
# typo in a service or action image does not surface with containers up.
my $with_images = <<'YAML';
name: Images
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: perl:5.38
    services:
      db:
        image: postgres:15
    steps:
      - uses: docker://alpine:3.20
        with:
          args: echo hi
      - run: echo hello
YAML

my $prepared = run_workflow($with_images);
is($prepared->{exit}, 0, 'a workflow with services and an action image runs');
like($prepared->{log}, qr/^pull\tpostgres:15$/m, 'the service image is pulled');
like($prepared->{log}, qr/^pull\talpine:3\.20$/m, 'the action image is pulled');

my $service_pull = index($prepared->{log}, "pull\tpostgres:15");
my $action_pull  = index($prepared->{log}, "pull\talpine:3.20");
my $job_start    = index($prepared->{log}, "run\t-d\t");
ok($service_pull >= 0 && $job_start >= 0 && $service_pull < $job_start,
    'the service image is pulled before the job container starts');
ok($action_pull >= 0 && $action_pull < $job_start,
    'the action image is pulled before the job container starts');

my $service_broken = run_workflow($with_images, fake_pull_failure => 'postgres:15');
is($service_broken->{exit}, 2, 'an unpullable service image stops the run');
like(
    $service_broken->{stderr},
    qr/cannot prepare the image 'postgres:15', needed by service 'db' of job 'test'/,
    'the failure names the image and the service that needs it',
);
unlike($service_broken->{stderr}, qr/ at \S+ line \d+/,
    'the image failure reads as a sentence, not a source location');
unlike($service_broken->{log}, qr/^run\t-d\t/m, 'no job container is started');
unlike($service_broken->{log}, qr/^exec\t/m, 'no step runs');

my $strict_pull = run_workflow($with_images, no_pull => 1);
is($strict_pull->{exit}, 2, '--no-pull with a missing image stops the run');
like($strict_pull->{stderr}, qr/is not available locally \(--no-pull\)/,
    'the --no-pull problem is explained before any container starts');
unlike($strict_pull->{stderr}, qr/ at \S+ line \d+/, 'that message reads as a sentence too');
unlike($strict_pull->{log}, qr/^run\t-d\t/m, 'no job container is started by --no-pull');

my $action_broken = run_workflow($with_images, fake_pull_failure => 'alpine:3.20');
is($action_broken->{exit}, 2, 'an unpullable action image stops the run');
like(
    $action_broken->{stderr},
    qr/cannot prepare the image 'alpine:3\.20', needed by action 'docker:\/\/alpine:3\.20'/,
    'the failure names the action that needs it',
);
unlike($action_broken->{log}, qr/^run\t-d\t/m, 'no job container is started');

# Images inside local composite actions are found by reading the action up
# front, rather than when the step that uses it happens to run.
my $image_action = <<'YAML';
name: Run an image
runs:
  using: composite
  steps:
    - name: Say hello
      uses: docker://busybox:1.36
      with:
        args: echo hi
YAML

my $local_images = run_workflow(<<'YAML', files => {
name: Local action image
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: perl:5.38
    steps:
      - uses: ./.github/actions/run-image
      - run: echo hello
YAML
    '.github/actions/run-image/action.yml' => $image_action,
});

is($local_images->{exit}, 0, 'a composite action with a docker:// step runs');
my $local_pull = index($local_images->{log}, "pull\tbusybox:1.36");
my $local_start = index($local_images->{log}, "run\t-d\t");
ok($local_pull >= 0 && $local_start >= 0 && $local_pull < $local_start,
    'the composite action image is pulled before the job container starts');

# A composite action inside a composite action is followed, and the image it
# names can come from the caller's inputs (or the action's defaults).
my $inner_action = <<'YAML';
name: Inner
inputs:
  image:
    default: busybox:1.35
runs:
  using: composite
  steps:
    - uses: docker://${{ inputs.image }}
      with:
        args: echo inner
YAML

my $wrapper_action = <<'YAML';
name: Wrapper
inputs:
  image:
    default: busybox:1.34
runs:
  using: composite
  steps:
    - uses: ./.github/actions/inner
      with:
        image: ${{ inputs.image }}
YAML

my $nested_images = run_workflow(<<'YAML', files => {
name: Nested action image
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: perl:5.38
    steps:
      - uses: ./.github/actions/wrapper
        with:
          image: busybox:1.37
      - run: echo hello
YAML
    '.github/actions/inner/action.yml'    => $inner_action,
    '.github/actions/wrapper/action.yml'  => $wrapper_action,
});

is($nested_images->{exit}, 0, 'a nested composite action runs');
my $nested_pull = index($nested_images->{log}, "pull\tbusybox:1.37");
my $nested_start = index($nested_images->{log}, "run\t-d\t");
ok($nested_pull >= 0 && $nested_start >= 0 && $nested_pull < $nested_start,
    'an image named two levels down is pulled before the job starts');
unlike($nested_images->{log}, qr/^pull\tbusybox:1\.3[45]$/m,
    'the input overrides the defaults of both actions');

# A broken image inside a local action fails the same way as a broken service
# image: before the first container, naming the action it came from.
my $local_broken = run_workflow(
    <<'YAML',
name: Local action image
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: perl:5.38
    steps:
      - uses: ./.github/actions/run-image
      - run: echo hello
YAML
    files => { '.github/actions/run-image/action.yml' => $image_action },
    fake_pull_failure => 'busybox:1.36',
);

is($local_broken->{exit}, 2, 'an unpullable image in a local action stops the run');
like(
    $local_broken->{stderr},
    qr/cannot prepare the image 'busybox:1\.36', needed by action 'docker:\/\/busybox:1\.36' in local action '\.\/\.github\/actions\/run-image' of job 'test'/,
    'the failure names the image, the action, and the job',
);
unlike($local_broken->{log}, qr/^run\t-d\t/m, 'no job container is started');
unlike($local_broken->{log}, qr/^exec\t/m, 'no step runs');

# An action that uses itself must not make the preflight descend forever.
my $self_action = <<'YAML';
name: Self
runs:
  using: composite
  steps:
    - uses: docker://busybox:1.38
    - uses: ./.github/actions/self
YAML

my $loop = run_workflow(<<'YAML', files => {
name: Self action
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: perl:5.38
    steps:
      - uses: ./.github/actions/self
YAML
    '.github/actions/self/action.yml' => $self_action,
});

my $loop_pulls = () = $loop->{log} =~ /^pull\tbusybox:1\.38$/mg;
is($loop_pulls, 1, 'a self-referencing action is walked once, not forever');

# A dry run reads no action metadata and pulls nothing for it either.
my $local_dry = run_workflow(
    <<'YAML',
name: Local action image
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: perl:5.38
    steps:
      - uses: ./.github/actions/run-image
YAML
    files   => { '.github/actions/run-image/action.yml' => $image_action },
    dry_run => 1,
);

is($local_dry->{exit}, 0, 'a dry run with a local action image succeeds');
unlike($local_dry->{log}, qr/^pull\t/m, 'a dry run pulls no local action image');

# The verbose listing points at the action an image came from.
my $local_verbose = run_workflow(
    <<'YAML',
name: Local action image
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: perl:5.38
    steps:
      - uses: ./.github/actions/run-image
YAML
    files   => { '.github/actions/run-image/action.yml' => $image_action },
    verbose => 1,
);

is($local_verbose->{exit}, 0, 'a verbose run with a local action image passes');
like(
    $local_verbose->{stdout},
    qr/^ {2}image\s+busybox:1\.36 \(action 'docker:\/\/busybox:1\.36' in local action '\.\/\.github\/actions\/run-image' of job 'test'\)$/m,
    'a verbose run names the composite action an image came from',
);

# An image used by two jobs is prepared once.
my $shared = <<'YAML';
name: Shared
on: push
jobs:
  first:
    runs-on: ubuntu-latest
    container:
      image: perl:5.38
    steps:
      - run: echo one
  second:
    runs-on: ubuntu-latest
    container:
      image: perl:5.38
    steps:
      - run: echo two
YAML

my $shared_run = run_workflow($shared);
is($shared_run->{exit}, 0, 'two jobs sharing an image run');
my $pulls = () = $shared_run->{log} =~ /^pull\tperl:5\.38$/mg;
is($pulls, 1, 'a shared image is pulled once');

# --skip-check leaves the images to be pulled when they are first used.
my $skipped_images = run_workflow(
    $with_images, fake_pull_failure => 'postgres:15', skip_check => 1,
);
is($skipped_images->{exit}, 2, 'skip_check fails later, inside the job');
like($skipped_images->{stdout}, qr/==> Job: test/, 'the job starts with skip_check');
like($skipped_images->{stderr}, qr/Failed to pull Docker image 'postgres:15'/,
    'the pull failure surfaces at use time');

# A dry run must not touch the registry.
my $dry = run_workflow($with_images, dry_run => 1);
is($dry->{exit}, 0, 'a dry run with services succeeds');
unlike($dry->{log}, qr/^pull\t/m, 'a dry run pulls nothing');

# The images are named when verbose, which is how a stuck pull is diagnosed.
my $verbose_images = run_workflow($with_images, verbose => 1);
is($verbose_images->{exit}, 0, 'a verbose run with services passes');
like($verbose_images->{stdout}, qr/^ {2}image\s+postgres:15 \(service 'db' of job 'test'\)$/m,
    'a verbose run names each image and why it is needed');

# Images that only an expression can produce are left to the run itself.
my $expression_image = run_workflow(<<'YAML');
name: Expression image
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        db: ['15', '16']
    container:
      image: perl:5.38
    services:
      database:
        image: postgres:${{ matrix.db }}
    steps:
      - run: echo hello
YAML

is($expression_image->{exit}, 0, 'a matrix-driven service image runs');
like($expression_image->{log}, qr/^pull\tpostgres:15$/m, 'the matrix value is resolved');
like($expression_image->{log}, qr/^pull\tpostgres:16$/m, 'each matrix value is resolved');

# A value that cannot be resolved yet is not guessed at.
my $unknown_image = run_workflow(<<'YAML');
name: Unknown image
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: perl:5.38
    services:
      database:
        image: postgres:${{ github.ref }}
    steps:
      - run: echo hello
YAML

is($unknown_image->{exit}, 0, 'an unresolved expression image is left to the run');

# The probe still runs first: an image problem is reported after the
# environment report, not instead of it.
my $broken_environment = run_workflow(
    $with_images, fake_os_type => 'windows', fake_pull_failure => 'postgres:15',
);
is($broken_environment->{exit}, 2, 'a broken environment is still reported first');
unlike($broken_environment->{log}, qr/^pull\t/m, 'nothing is pulled for a broken environment');

done_testing;
