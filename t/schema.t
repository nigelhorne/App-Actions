use strict;
use warnings;
use Test::Most;
use Capture::Tiny qw(capture);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP ();

use App::Actions::Check;
use App::Actions::Runner;

my $root = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
my $lib     = File::Spec->catdir($root, 'lib');
my $script  = File::Spec->catfile($root, 'bin', 'action-run');
my $fake    = File::Spec->catfile($root, 't', 'bin', 'fake-docker');
my $fixtures = File::Spec->catdir($root, 't', 'fixtures');

# A small JSON Schema subset: type, const, enum, properties, required, items
# and oneOf.  An object that names properties also rejects keys the schema
# does not name, which is what keeps a new key from slipping into the document
# without the schema and the example being updated with it.
sub validate {
    my ($value, $schema, $path) = @_;

    $path = '$' unless defined $path;

    if (ref $schema->{oneOf} eq 'ARRAY') {
        my $first;
        for my $alternative (@{ $schema->{oneOf} }) {
            my @errors = validate($value, $alternative, $path);
            return () unless @errors;
            $first = $errors[0] unless defined $first;
        }

        return ("$path: matches none of the alternative shapes (first said: $first)");
    }

    if (exists $schema->{const}) {
        return ("$path: expected " . _show($schema->{const}) . ', got ' . _show($value))
            unless _same($value, $schema->{const});
    }

    if (ref $schema->{enum} eq 'ARRAY') {
        return ("$path: " . _show($value) . ' is not one of '
            . join(', ', map { _show($_) } @{ $schema->{enum} }))
            unless grep { _same($value, $_) } @{ $schema->{enum} };
    }

    if (defined(my $type = $schema->{type})) {
        my @types = ref $type eq 'ARRAY' ? @$type : ($type);
        return ("$path: expected " . join(' or ', @types) . ', got ' . _show($value))
            unless grep { _is_type($value, $_) } @types;
    }

    my @errors;

    if (ref $value eq 'HASH' && ref $schema->{properties} eq 'HASH') {
        my $properties = $schema->{properties};

        for my $key (sort keys %$value) {
            push @errors, "$path.$key: unexpected key"
                unless exists $properties->{$key};
        }

        for my $key (@{ $schema->{required} || [] }) {
            push @errors, "$path.$key: missing"
                unless exists $value->{$key};
        }

        for my $key (sort keys %$properties) {
            next unless exists $value->{$key};
            push @errors, validate($value->{$key}, $properties->{$key}, "$path.$key");
        }
    }

    if (ref $value eq 'ARRAY' && ref $schema->{items} eq 'HASH') {
        for my $index (0 .. $#$value) {
            push @errors, validate($value->[$index], $schema->{items}, "$path\[$index]");
        }
    }

    return @errors;
}

sub _is_type {
    my ($value, $type) = @_;

    return !defined $value ? 1 : 0 if $type eq 'null';
    return JSON::PP::is_bool($value) ? 1 : 0 if $type eq 'boolean';
    return ref $value eq 'ARRAY' ? 1 : 0 if $type eq 'array';
    return ref $value eq 'HASH' ? 1 : 0 if $type eq 'object';
    return 0 if !defined $value || ref $value;

    return $value =~ /\A-?\d+\z/ ? 1 : 0 if $type eq 'integer';
    return $value =~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?\z/ ? 1 : 0
        if $type eq 'number';
    return 1 if $type eq 'string';

    return 0;
}

sub _same {
    my ($one, $other) = @_;

    return 1 if !defined $one && !defined $other;
    return 0 if !defined $one || !defined $other || ref $one || ref $other;

    return $one eq $other ? 1 : 0;
}

sub _show {
    my ($value) = @_;

    return 'null' unless defined $value;
    return ref $value unless ref $value;

    return "'$value'";
}

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

my $check_schema     = load_json(File::Spec->catfile($fixtures, 'check-schema.json'));
my $preflight_schema = load_json(File::Spec->catfile($fixtures, 'preflight-schema.json'));
my $check_example     = load_json(File::Spec->catfile($fixtures, 'check.json'));
my $preflight_example = load_json(File::Spec->catfile($fixtures, 'preflight.json'));

# The schema files, the documents and the modules all name the same version,
# so an assertion can say which shape it was written for.
is($check_schema->{version}, App::Actions::Check->json_schema_version,
    'the check schema version is the version the module reports');
is($preflight_schema->{version}, App::Actions::Runner->preflight_schema_version,
    'the preflight schema version is the version the module reports');

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
    ok(scalar validate($wrong, $check_schema),
        'a value of the wrong type is rejected');
}
{
    my $newer = { %$check_example, schema_version => $check_schema->{version} + 1 };
    ok(scalar validate($newer, $check_schema),
        'another schema version is rejected');
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

done_testing;
