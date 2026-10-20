use strict;
use warnings;
use Test::Most;
use Capture::Tiny qw(capture);
use File::Basename qw(dirname);
use File::Path qw(make_path);
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

done_testing;
