use strict;
use warnings;
use Test::Most;
use Capture::Tiny qw(capture);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP ();
use Scalar::Util qw(refaddr);

use App::Actions;
use App::Actions::Check;
use App::Actions::Runner;
use App::Actions::Schema qw(validate);

my $root = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
my $lib     = File::Spec->catdir($root, 'lib');
my $script  = File::Spec->catfile($root, 'bin', 'action-run');
my $fake    = File::Spec->catfile($root, 't', 'bin', 'fake-docker');
my $fixtures = File::Spec->catdir($root, 't', 'fixtures');

# A copy of the code under test, made here rather than kept in the tree, so a
# schema can be drifted for the length of one command run.
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

# Give a module's schema a key its document does not have, which is the drift a
# forgotten schema change would cause.
sub drift_schema {
    my ($path, $package) = @_;

    open my $handle, '<', $path or die "Unable to read '$path': $!";
    binmode $handle;
    local $/;
    my $source = <$handle>;
    close $handle;
    $source = '' unless defined $source;

    my $injection = <<"CODE";
{
    no warnings 'redefine';
    my \$original = \\&${package}::json_schema;
    *${package}::json_schema = sub {
        my \$schema = \$original->(\@_);
        push \@\{ \$schema->{required} }, 'drifted_key';
        return \$schema;
    };
}
CODE

    $source =~ s/\n1;\n/\n$injection\n1;\n/
        or die "cannot inject a drifted schema into '$path'";

    open my $out, '>', $path or die "Unable to write '$path': $!";
    print {$out} $source;
    close $out;

    return;
}

# The validator is the one the commands themselves use, so a change to it is
# exercised here in the same form as at run time.
sub load_json {
    my ($path) = @_;

    open my $handle, '<', $path or die "Unable to read '$path': $!";
    local $/;
    my $text = <$handle>;
    close $handle;

    return JSON::PP->new->decode($text);
}

sub write_file {
    my ($path, $text) = @_;

    open my $handle, '>', $path or die "Unable to write '$path': $!";
    print {$handle} $text;
    close $handle;

    return;
}

sub run_cli {
    my (@args) = @_;

    my ($stdout, $stderr, $status) = capture {
        system($^X, '-I' . $lib, $script, @args);
    };

    return ($stdout, $stderr, $status >> 8);
}

# The schemas come from the modules, which is where the command prints them
# from, so these tests hold the contract a CI job fetches rather than a copy
# of it that could drift.
my $check_schema     = App::Actions::Check->json_schema;
my $preflight_schema = App::Actions::Runner->json_schema;

my %shipped_schema = (
    check     => $check_schema,
    preflight => $preflight_schema,
);

# The version of a shape is written in three places: the schema's own version,
# the const its schema_version property promises, and the constant the module
# reports.  A bump that reaches one or two of them changes what the contract
# says without changing the number a caller compares against, and a document
# that then fails would name a key rather than the version that moved.  So the
# schemas are held to themselves here, before any document is read.
my %schema_source = (
    check     => [ 'App::Actions::Check',  'json_schema_version' ],
    preflight => [ 'App::Actions::Runner', 'preflight_schema_version' ],
);

for my $document (sort keys %shipped_schema) {
    my ($module, $reported_by) = @{ $schema_source{$document} };
    my $schema = $shipped_schema{$document};

    my $version  = $schema->{version};
    my $const    = $schema->{properties}{schema_version}{const};
    my $reported = $module->$reported_by;

    my $show = sub {
        my ($value) = @_;

        return defined $value ? "$value" : 'nothing';
    };

    my @problems;
    push @problems, sprintf(
        'the %s schema says version %s, but its schema_version const says %s',
        $document, $show->($version), $show->($const),
    ) unless defined $const && defined $version && "$const" eq "$version";

    push @problems, sprintf(
        'the %s schema says version %s, but %s->%s returns %s',
        $document, $show->($version), $module, $reported_by, $show->($reported),
    ) unless defined $version && defined $reported && "$version" eq "$reported";

    is_deeply(
        \@problems,
        [],
        "the $document schema version, its const key and the module that prints it agree",
    );
    diag "$_\n" for @problems;
}

my $check_example     = load_json(File::Spec->catfile($fixtures, 'check.json'));
my $preflight_example = load_json(File::Spec->catfile($fixtures, 'preflight.json'));

is_deeply(
    [ validate($check_example, $check_schema) ],
    [],
    'the checked-in check example matches its schema',
);
is_deeply(
    [ validate($preflight_example, $preflight_schema) ],
    [],
    'the checked-in preflight example matches its schema',
);

# CI should not have to read this file to find the contract, so the command
# prints it: the same document the tests above hold the examples to.
for my $document (qw(check preflight)) {
    my ($out, $err, $exit) = run_cli('schema', $document);
    is($exit, 0, "schema $document exits 0");
    is($err, '', "schema $document writes nothing to standard error");

    my $printed = eval { JSON::PP->new->decode($out) };
    ok($printed, "schema $document prints one JSON object") or diag "stderr: $err";

    my $module = $document eq 'check'
        ? App::Actions::Check->json_schema
        : App::Actions::Runner->json_schema;

    is(
        JSON::PP->new->canonical->encode($printed),
        JSON::PP->new->canonical->encode($module),
        "schema $document prints the schema the module produces",
    );
}

my (undef, $no_name_err, $no_name_exit) = run_cli('schema');
is($no_name_exit, 2, 'schema without a document is a usage error');
like($no_name_err, qr/Usage: action-run \[options\] schema <check\|preflight>/,
    'the usage error says which documents can be named');

my (undef, $unknown_err, $unknown_exit) = run_cli('schema', 'workflow');
is($unknown_exit, 2, 'an unknown document is a usage error');
like($unknown_err, qr/Unknown document 'workflow'; expected check or preflight/,
    'the error names the documents that exist');
unlike($unknown_err, qr/ at \S+ line \d+/, 'the error reads as a sentence');

my (undef, $json_err, $json_exit) = run_cli('--json', 'schema', 'check');
is($json_exit, 2, '--json with the schema command is a usage error');
like($json_err, qr/only used by the check and preflight commands/,
    'the schema command needs no --json');

is($check_example->{schema_version}, $check_schema->{version},
    'the check example carries the version it was written for');
is($preflight_example->{schema_version}, $preflight_schema->{version},
    'the preflight example carries the version it was written for');

# A validator that accepted everything would pass the tests above, so it is
# shown to reject the ways the document can drift.
{
    my $extra = { %$check_example, surprise => 1 };
    ok(scalar validate($extra, $check_schema),
        'a key the schema does not name is rejected');
}
{
    my $missing = { %$check_example };
    delete $missing->{issues};
    ok(scalar validate($missing, $check_schema),
        'a key the schema requires is not allowed to go missing');
}
{
    my $wrong = { %$check_example, problems => 'none' };
    my @errors = validate($wrong, $check_schema);
    is(scalar @errors, 1, 'a value of the wrong type is rejected');
    is($errors[0], "\$.problems: expected integer, got 'none'",
        'the message shows the value that is wrong, not a blank');
}
{
    my $newer = { %$check_example, schema_version => $check_schema->{version} + 1 };
    my @errors = validate($newer, $check_schema);
    is(scalar @errors, 1, 'another schema version is rejected');
    is($errors[0], '$' . ".schema_version: expected $check_schema->{version}, got "
        . ($check_schema->{version} + 1),
        'the version mismatch names both versions');
}
{
    my $bad_status = JSON::PP->new->decode(JSON::PP->new->encode($preflight_example));
    $bad_status->{images}[0]{status} = 'somewhere-in-between';
    ok(scalar validate($bad_status, $preflight_schema),
        'a status outside the enum is rejected');
}
{
    my $no_concurrency = JSON::PP->new->decode(JSON::PP->new->encode($preflight_example));
    delete $no_concurrency->{pull_concurrency};
    ok(scalar validate($no_concurrency, $preflight_schema),
        'a preflight document without the pull concurrency is rejected');
}
{
    my $text_concurrency = JSON::PP->new->decode(JSON::PP->new->encode($preflight_example));
    $text_concurrency->{pull_concurrency} = 'four';
    ok(scalar validate($text_concurrency, $preflight_schema),
        'a pull concurrency that is not a number is rejected');
}

# Every shape the schemas name has to be carried by a checked-in example, or
# the contract promises a document no example is shown to produce.  That is
# two faults, not one: a schema that kept a key, a value or a null variant the
# code stopped printing, and a document that gained one nobody wrote down are
# both invisible while the only test is "the example matches the schema".
#
# The walk marks what the examples actually carry - the keys, the oneOf
# alternative a value matched, the enum value it used, and whether it was null
# where the schema allows null - then enumerates the schema against those
# marks, so an array no example fills cannot hide its item's keys, and a oneOf
# alternative, an enum value or a null variant that no example shows is
# reported rather than silently skipped.
sub mark_keys {
    my ($value, $schema, $path, $coverage) = @_;

    $path = '$' unless defined $path;

    if (ref $schema->{oneOf} eq 'ARRAY') {
        my @matching = grep { !validate($value, $_, $path) } @{ $schema->{oneOf} };

        for my $alternative (@matching) {
            $coverage->{alternatives}{ refaddr $alternative }++;
            mark_keys($value, $alternative, $path, $coverage);
        }

        return;
    }

    # A type that names null says a document may report a value it could not
    # discover, so a reader has to handle that shape; it is as much part of
    # the contract as a key is.
    $coverage->{nulls}{ refaddr $schema }++
        if !defined $value && allows_null($schema);

    # An enum is the list of values a reader may switch on, so each one has to
    # be shown at least once.  A null in the list is covered by the rule
    # above, because it is a type as well as a value there.
    $coverage->{values}{ refaddr $schema }{$value} = 1
        if ref $schema->{enum} eq 'ARRAY' && defined $value;

    if (ref $value eq 'HASH') {
        my $properties = $schema->{properties} || {};

        $coverage->{keys}{ refaddr $schema }{$_} = 1 for keys %$value;

        for my $key (sort keys %$properties) {
            next unless exists $value->{$key};
            mark_keys($value->{$key}, $properties->{$key}, "$path.$key", $coverage);
        }

        return;
    }

    if (ref $value eq 'ARRAY' && ref $schema->{items} eq 'HASH') {
        for my $index (0 .. $#$value) {
            mark_keys($value->[$index], $schema->{items}, "$path\[$index\]", $coverage);
        }
    }

    return;
}

# Whether a schema allows a document to leave a value out of the report.  It
# is asked of the schema rather than of the value, because the gap is a shape
# no example shows, not a document that happens to have no null in it.
sub allows_null {
    my ($schema) = @_;

    my $type = $schema->{type};
    my @types = ref $type eq 'ARRAY' ? @$type : defined $type ? ($type) : ();

    return scalar grep { defined $_ && $_ eq 'null' } @types;
}

# What the examples did not reach, named by the schema's own path so that the
# fix is obvious: add the key, the value or the null to an example, or take it
# out of the schema.
sub schema_gaps {
    my ($schema, $coverage, $path) = @_;

    $path = '$' unless defined $path;
    my @gaps;

    if (ref $schema->{oneOf} eq 'ARRAY') {
        for my $index (0 .. $#{ $schema->{oneOf} }) {
            my $alternative = $schema->{oneOf}[$index];
            my $label = "$path.oneOf[$index]";

            push @gaps,
                "$label: no example matches this alternative, so its keys are unexercised"
                unless $coverage->{alternatives}{ refaddr $alternative };

            push @gaps, schema_gaps($alternative, $coverage, $label);
        }
    }

    my $properties = $schema->{properties};

    if (ref $properties eq 'HASH' || ref $schema->{required} eq 'ARRAY') {
        my %declared = map { $_ => 1 }
            (@{ $schema->{required} || [] }, keys %{ $properties || {} });
        my $carried = $coverage->{keys}{ refaddr $schema } || {};

        push @gaps, "$path.$_: no example carries this key"
            for grep { !$carried->{$_} } sort keys %declared;
    }

    push @gaps, "$path: no example shows this value as null"
        if allows_null($schema) && !$coverage->{nulls}{ refaddr $schema };

    if (ref $schema->{enum} eq 'ARRAY') {
        my $used = $coverage->{values}{ refaddr $schema } || {};

        push @gaps, "$path: no example uses the enum value '$_'"
            for grep { !$used->{$_} } @{ $schema->{enum} };
    }

    for my $key (sort keys %{ $properties || {} }) {
        push @gaps, schema_gaps($properties->{$key}, $coverage, "$path.$key");
    }

    push @gaps, schema_gaps($schema->{items}, $coverage, "$path\[\]")
        if ref $schema->{items} eq 'HASH';

    return @gaps;
}

# The examples that document each schema.  One example cannot carry every
# shape a document can take, so each schema has a set: a healthy report, one
# that found a problem, one from a host where Docker could not be reached -
# the nulls for what could not be discovered - and one whose probe ran but
# could not count the project's entries.  The last also shows the skipped
# images a preflight reports when the environment is not ready, and the entry
# it could not name.
my %shipped_examples = (
    check     => [qw(check.json check-unready.json check-unreachable.json check-uncounted.json)],
    preflight => [qw(preflight.json preflight-unready.json preflight-unreachable.json
                    preflight-not-ready.json)],
);
for my $document (sort keys %shipped_examples) {
    my $schema = $shipped_schema{$document};
    my %coverage = (keys => {}, alternatives => {});

    for my $name (@{ $shipped_examples{$document} }) {
        my $example = load_json(File::Spec->catfile($fixtures, $name));

        is_deeply(
            [ validate($example, $schema) ], [],
            "the checked-in $document example '$name' matches the schema",
        );

        mark_keys($example, $schema, '$', \%coverage);
    }

    my @gaps = schema_gaps($schema, \%coverage);

    is(scalar @gaps, 0,
        "the checked-in $document examples exercise every key, enum value and null variant in the $document schema");
    diag "$document schema, unexercised: $_\n" for @gaps;
}

# A version bump is applied by hand to the schema, the module that prints it
# and every checked-in document, and the copy that gets forgotten is exactly
# the one that was not on somebody's list.  The assertions above only see the
# files named in %shipped_examples, so the directory itself is walked here:
# every document has to declare the version the module that prints it ships.
# That is what fails on a half-applied bump, with the file and both numbers
# named, instead of a CI job reporting the key at fault in a document nobody
# was editing.
my @fixture_files = do {
    opendir my $directory, $fixtures or die "Unable to read '$fixtures': $!";
    my @names = sort grep { /\.json\z/ } readdir $directory;
    closedir $directory;
    @names;
};

ok(scalar @fixture_files, 'the fixtures directory holds the checked-in examples');

my %document_of;
my @version_problems;

for my $name (@fixture_files) {
    my $example = load_json(File::Spec->catfile($fixtures, $name));

    # A document says which command printed it by what it carries - the
    # preflight adds images and the pull concurrency - rather than by how its
    # file happens to be named.
    my $document = exists $example->{pull_concurrency}
        && ref $example->{images} eq 'ARRAY'
        ? 'preflight'
        : 'check';
    $document_of{$name} = $document;

    my $shipped  = $shipped_schema{$document};
    my $declared = $example->{schema_version};

    next if defined $declared && $declared eq $shipped->{version};

    push @version_problems, sprintf(
        '%s declares schema version %s, but %s ships %s',
        $name,
        defined $declared ? $declared : 'nothing',
        $document eq 'preflight' ? 'App::Actions::Runner' : 'App::Actions::Check',
        $shipped->{version},
    );
}

is_deeply(
    \@version_problems,
    [],
    'every checked-in example declares the schema version it is written for',
);
diag "$_\n" for @version_problems;

# An example nobody listed is one the walk above never reads, so its keys,
# enum values and null variants would go unchecked while it looked covered.
my @unlisted;
for my $name (@fixture_files) {
    my $listed = grep { $_ eq $name }
        @{ $shipped_examples{ $document_of{$name} } || [] };

    push @unlisted, $name unless $listed;
}

is_deeply(
    \@unlisted,
    [],
    'every checked-in example is one the coverage walk reads',
);
diag "add '$_' to \%shipped_examples\n" for @unlisted;

# Now the documents the commands actually print, against the same schemas.
my $project = tempdir(CLEANUP => 1);
make_path(File::Spec->catdir($project, '.github', 'workflows'));
my $workflow = File::Spec->catfile($project, '.github', 'workflows', 'test.yml');

write_file($workflow, <<'YAML');
name: Schema
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
      - id: pick
        run: |
          FAKE_OUTPUT: image=alpine:3.20
      - uses: docker://${{ steps.pick.outputs.image }}
YAML

local $ENV{FAKE_DOCKER_STATE} = tempdir(CLEANUP => 1);

my ($check_out, $check_err, $check_exit) = run_cli(
    '--docker', $fake, 'check', '--json', $project,
);
is($check_exit, 0, 'check --json exits 0 against the fake daemon');

my $check_doc = eval { JSON::PP->new->decode($check_out) };
ok($check_doc, 'the check document decodes') or diag "stderr: $check_err";
is_deeply([ validate($check_doc, $check_schema) ], [],
    'the check document the command prints matches the schema');
is($check_doc->{schema_version}, App::Actions::Check->json_schema_version,
    'the printed check document carries the module version');
is_deeply([ sort keys %$check_doc ], [ sort keys %$check_example ],
    'the printed check document has the keys the example shows');

my ($preflight_out, $preflight_err, $preflight_exit) = run_cli(
    '--docker', $fake, 'preflight', '--json', $workflow, $project,
);
is($preflight_exit, 0, 'preflight --json exits 0 against the fake daemon');

my $preflight_doc = eval { JSON::PP->new->decode($preflight_out) };
ok($preflight_doc, 'the preflight document decodes') or diag "stderr: $preflight_err";
is_deeply([ validate($preflight_doc, $preflight_schema) ], [],
    'the preflight document the command prints matches the schema');
is($preflight_doc->{schema_version}, App::Actions::Runner->preflight_schema_version,
    'the printed preflight document carries the module version');
is_deeply([ sort keys %$preflight_doc ], [ sort keys %$preflight_example ],
    'the printed preflight document has the keys the example shows');

# The step the fake daemon answers decides an image name, so this document has
# a deferred record too; the example shows that shape, and the schema allows
# the optional expression and error only where they belong.
my @deferred = grep { $_->{status} eq 'deferred' } @{ $preflight_doc->{images} };
is(scalar @deferred, 1, 'the deferred image is in the printed document');
is($deferred[0]{image}, undef, 'a deferred image has no name');
like($deferred[0]{expression}, qr/\Qsteps.pick.outputs.image\E/,
    'a deferred image reports the expression it could not resolve');

my @statuses = map { $_->{status} } @{ $preflight_example->{images} };
is_deeply(
    [ grep { $_ eq 'deferred' } @statuses ],
    [ 'deferred' ],
    'the example shows the deferred shape the command can print',
);

# A document that says the run is not ready is the same shape with other
# values, which is what the schema claims.
{
    local $ENV{FAKE_OS_TYPE} = 'windows';

    my ($broken_out, $broken_err, $broken_exit) = run_cli(
        '--docker', $fake, 'preflight', '--json', $workflow, $project,
    );
    is($broken_exit, 2, 'a preflight on a broken environment exits 2');

    my $broken = eval { JSON::PP->new->decode($broken_out) };
    ok($broken, 'the failing preflight document decodes') or diag "stderr: $broken_err";
    is_deeply([ validate($broken, $preflight_schema) ], [],
        'the failing preflight document matches the schema');
    ok(!$broken->{ready}, 'the failing document is not ready');
    cmp_ok($broken->{problems}, '>', 0, 'the failing document counts a problem');
    is_deeply([ sort keys %$broken ], [ sort keys %$preflight_example ],
        'a failing document has the keys the example shows');
}

# The same for an image that could not be pulled: the failed shape carries an
# error and leaves the run unready.
{
    local $ENV{FAKE_PULL_FAILURE} = 'postgres:15';

    my ($failed_out, $failed_err, $failed_exit) = run_cli(
        '--pull', '--docker', $fake, 'preflight', '--json', $workflow, $project,
    );
    is($failed_exit, 2, 'a preflight with an unpullable image exits 2');

    my $failed = eval { JSON::PP->new->decode($failed_out) };
    ok($failed, 'the failed preflight document decodes') or diag "stderr: $failed_err";
    is_deeply([ validate($failed, $preflight_schema) ], [],
        'the failed preflight document matches the schema');

    my @failed = grep { $_->{status} eq 'failed' } @{ $failed->{images} };
    is(scalar @failed, 1, 'the image that could not be pulled is marked');
    like($failed[0]{error}, qr/Failed to pull Docker image 'postgres:15'/,
        'a failed image reports the reason');
}

# A preflight that skips the probes still reports the host it can see locally,
# so its document has the shape the schema claims rather than empty objects.
{
    my ($skipped_out, $skipped_err, $skipped_exit) = run_cli(
        '--skip-check', '--docker', $fake, 'preflight', '--json', $workflow, $project,
    );
    is($skipped_exit, 0, 'a preflight with --skip-check exits 0');

    my $skipped = eval { JSON::PP->new->decode($skipped_out) };
    ok($skipped, 'the skipped-probe document decodes') or diag "stderr: $skipped_err";
    is_deeply([ validate($skipped, $preflight_schema) ], [],
        'the skipped-probe document matches the schema');
    is($skipped->{host}{os}, $^O, 'the host is reported even when it was not probed');
}

# The commands hold themselves to the contract rather than only being tested
# against it: a document that no longer matches the shipped schema is not
# printed at all.  Replacing the schema for the length of a block is the drift
# a forgotten schema change would cause.
{
    my $shipped = \&App::Actions::Check::json_schema;
    no warnings 'redefine';
    local *App::Actions::Check::json_schema = sub {
        my ($class) = @_;
        my $schema = $shipped->($class);
        delete $schema->{properties}{ready};
        return $schema;
    };

    my $printed = '';
    open my $sink, '>', \$printed or die $!;

    my $check = App::Actions::Check->new(
        docker_bin => $fake,
        directory  => $project,
        json       => 1,
        output     => $sink,
    );

    my $ran = eval { $check->run; 1 };
    my $error = $@;
    ok(!$ran, 'a check document that does not match the schema is not printed');
    ok(ref $error && $error->isa('App::Actions::Schema::Invalid'),
        'the failure is the schema exception, not a plain string');
    like(
        "$error",
        qr/does not match App::Actions::Check->json_schema: \$\.ready: unexpected key/,
        'the error names the document, the schema and the key at fault',
    );
    is($error->message, "$error", 'the exception message is what it stringifies to')
        if ref $error;
    unlike("$error", qr/ at \S+ line \d+/, 'the error reads as a sentence');
    is($printed, '', 'nothing is printed when the document does not match');
}

{
    my $shipped = \&App::Actions::Runner::json_schema;
    no warnings 'redefine';
    local *App::Actions::Runner::json_schema = sub {
        my ($class) = @_;
        my $schema = $shipped->($class);
        delete $schema->{properties}{pull_concurrency};
        return $schema;
    };

    my $actions = App::Actions->new(
        workflow_file => $workflow,
        project_dir   => $project,
        docker_bin    => $fake,
    );

    my $ran = eval { $actions->preflight(json => 1); 1 };
    my $error = $@;
    ok(!$ran, 'a preflight document that does not match the schema is not returned');
    ok(ref $error && $error->isa('App::Actions::Schema::Invalid'),
        'the preflight failure is the schema exception too');
    like(
        "$error",
        qr/does not match App::Actions::Runner->json_schema: \$\.pull_concurrency: unexpected key/,
        'the preflight error names the key at fault',
    );
}

# The status belongs to the command, not the module, so it is checked by
# running a copy of the tree whose schema has drifted.  A CI job reading 2 as
# "the host needs fixing" must not see that for a document this distribution
# mangled itself.
{
    my $copy = File::Spec->catdir(tempdir(CLEANUP => 1), 'drifted');
    make_path($copy);
    copy_tree($root, $copy, $_) for qw(lib bin);

    drift_schema(File::Spec->catfile($copy, qw(lib App Actions Check.pm)),
        'App::Actions::Check');
    drift_schema(File::Spec->catfile($copy, qw(lib App Actions Runner.pm)),
        'App::Actions::Runner');

    my $drifted = File::Spec->catfile($copy, 'bin', 'action-run');

    my ($drift_out, $drift_err, $drift_status) = capture {
        system($^X, $drifted, '--docker', $fake, 'check', '--json', $project);
    };
    is($drift_status >> 8, App::Actions::Schema::invalid_exit(),
        'a broken check document exits with the schema status');
    is($drift_out, '', 'a broken check document prints no document');
    like($drift_err, qr/\$\.drifted_key: missing/,
        'the message names the property the schema gained');
    unlike($drift_err, qr/ at \S+ line \d+/, 'the message reads as a sentence');

    my ($pre_out, $pre_err, $pre_status) = capture {
        system($^X, $drifted, '--docker', $fake,
            'preflight', '--json', $workflow, $project);
    };
    is($pre_status >> 8, App::Actions::Schema::invalid_exit(),
        'a broken preflight document exits with the schema status');
    is($pre_out, '', 'a broken preflight document prints no document');
    like($pre_err, qr/\$\.drifted_key: missing/,
        'the preflight message names the property too');

    isnt(App::Actions::Schema::invalid_exit(), 2,
        'the schema status is not the one an unready environment uses');
}

# A saved document can be checked without Docker or a workflow, which is what
# lets a CI job validate a result produced by another job or machine.
{
    my $check_file     = File::Spec->catfile($fixtures, 'check.json');
    my $preflight_file = File::Spec->catfile($fixtures, 'preflight.json');

    for my $example ([ check => $check_file ], [ preflight => $preflight_file ]) {
        my ($name, $path) = @$example;

        my ($out, $err, $exit) = run_cli('validate', $name, $path);
        is($exit, 0, "validate $name accepts the checked-in example");
        is($err, '', "validate $name writes nothing to standard error");
        like(
            $out,
            qr/'\Q$path\E' is a valid $name document \(schema version \d+\)/,
            "validate $name says what it checked",
        );
    }

    # A document the command itself printed is what a CI job would fetch from
    # another machine.
    my $live = File::Spec->catfile(tempdir(CLEANUP => 1), 'live-preflight.json');
    write_file($live, JSON::PP->new->canonical->encode($preflight_doc));

    my ($live_out, $live_err, $live_exit) = run_cli(
        'validate', 'preflight', $live,
    );
    is($live_exit, 0, 'the preflight document the command printed validates');
    is($live_err, '', 'a valid document says nothing on standard error');
    like($live_out, qr/is a valid preflight document/, 'it confirms the document');

    # The wrong schema has to be rejected, not passed because both are JSON.
    my ($wrong_out, $wrong_err, $wrong_exit) = run_cli(
        'validate', 'preflight', $check_file,
    );
    is($wrong_exit, App::Actions::Schema::invalid_exit(),
        'a document checked against the wrong schema exits with the schema status');
    is($wrong_out, '', 'a rejected document prints no confirmation');
    like(
        $wrong_err,
        qr/does not match the preflight schema: \$\.(?:pull_concurrency|images): missing/,
        'the mismatch names a key the document lacks',
    );
    unlike($wrong_err, qr/ at \S+ line \d+/, 'the mismatch reads as a sentence');

    # A document from another schema version is what a CI job meets when the
    # two machines disagree, so the message names both versions.
    my $newer = JSON::PP->new->decode(JSON::PP->new->encode($preflight_example));
    $newer->{schema_version} = $preflight_schema->{version} + 1;

    my $newer_file = File::Spec->catfile(tempdir(CLEANUP => 1), 'newer.json');
    write_file($newer_file, JSON::PP->new->canonical->encode($newer));

    my (undef, $newer_err, $newer_exit) = run_cli(
        'validate', 'preflight', $newer_file,
    );
    is($newer_exit, App::Actions::Schema::invalid_exit(),
        'a document from another schema version is rejected');
    like(
        $newer_err,
        qr/\$\.schema_version: expected \Q$preflight_schema->{version}\E, got \d+/,
        'the message names both versions',
    );

    # A file the schema cannot judge is rejected the same way.
    my $junk = File::Spec->catfile(tempdir(CLEANUP => 1), 'junk.json');
    write_file($junk, "{ not json\n");

    my (undef, $junk_err, $junk_exit) = run_cli('validate', 'check', $junk);
    is($junk_exit, App::Actions::Schema::invalid_exit(),
        'a file that is not JSON exits with the schema status');
    like($junk_err, qr/is not valid JSON/,
        'the error says the file could not be parsed');

    # Usage errors keep their own status, so a missing file is not mistaken for
    # a document that does not match.
    my (undef, $missing_err, $missing_exit) = run_cli(
        'validate', 'check', File::Spec->catfile($fixtures, 'absent.json'),
    );
    is($missing_exit, 2, 'a file that cannot be read is a usage error');
    like($missing_err, qr/cannot read/, 'the error names the file');

    my (undef, $unknown_err, $unknown_exit) = run_cli(
        'validate', 'workflow', $check_file,
    );
    is($unknown_exit, 2, 'an unknown document name is a usage error');
    like(
        $unknown_err,
        qr/Unknown document 'workflow'; expected check or preflight/,
        'the error names the documents that exist',
    );

    my (undef, $args_err, $args_exit) = run_cli('validate', 'check');
    is($args_exit, 2, 'validate without a document is a usage error');
    like(
        $args_err,
        qr/Usage: action-run \[options\] validate <check\|preflight> <document\.json>/,
        'the usage line says what is needed',
    );

    my (undef, $json_err, $json_exit) = run_cli(
        '--json', 'validate', 'check', $check_file,
    );
    is($json_exit, 2, '--json with validate is a usage error');
    like($json_err, qr/only used by the check and preflight commands/,
        'the validate command needs no --json');
}

done_testing;
