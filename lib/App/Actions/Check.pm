package App::Actions::Check;

use strict;
use warnings;
use Config;
use File::Spec;
use File::Temp ();
use JSON::PP ();

use App::Actions::Docker;
use App::Actions::Schema;

our $VERSION = '0.01';

# The shape of the JSON document this module prints.  Bump it whenever a key,
# a value type or an enum changes, and update the schema below and the examples
# in t/fixtures/ with it; a CI job asserts the number rather than discovering
# a changed shape at the point where its assertion fails for another reason.
#
# 2: docker.bin stopped being nullable.  It is always the resolved command, so
# the null type promised a shape no document can produce; t/schema.t requires
# every enum value and null variant to appear in the examples, which is what
# found it.
our $JSON_SCHEMA_VERSION = 2;

# The schema of the document check --json prints, so that the installed
# action-run can hand the contract to a caller instead of leaving it in the
# tests.  A change to the document belongs here, in $JSON_SCHEMA_VERSION and
# in the examples in t/fixtures/, which t/schema.t holds against this and
# fails when a key it names appears in none of them.
my $JSON_SCHEMA = <<'JSON';
{
  "title": "action-run check --json",
  "description": "The document action-run check --json prints.  Objects reject keys this file does not name, so a new key is a schema change.",
  "version": 2,
  "type": "object",
  "properties": {
    "schema_version": {
      "description": "The version of this shape; App::Actions::Check->json_schema_version returns it.",
      "type": "integer",
      "const": 2
    },
    "ready": {
      "description": "True only when every check passed.",
      "type": "boolean"
    },
    "problems": {
      "description": "How many problems were found.",
      "type": "integer"
    },
    "host": {
      "type": "object",
      "properties": {
        "os": { "type": "string" },
        "name": { "type": "string" },
        "perl": { "type": "string" },
        "archname": { "type": "string" }
      },
      "required": [ "os", "name", "perl", "archname" ]
    },
    "docker": {
      "type": "object",
      "properties": {
        "bin": { "type": "string" },
        "client": { "type": [ "string", "null" ] },
        "daemon": { "type": [ "string", "null" ] },
        "containers": { "type": [ "string", "null" ] }
      },
      "required": [ "bin", "client", "daemon", "containers" ]
    },
    "image": {
      "description": "The probe image, or null when no container was run.",
      "type": [ "string", "null" ]
    },
    "mounts": {
      "type": "array",
      "items": {
        "oneOf": [
          {
            "description": "The temporary directory the probe reads back from.",
            "type": "object",
            "properties": {
              "host": { "type": "string" },
              "container": { "type": "string" },
              "ok": { "type": "boolean" }
            },
            "required": [ "host", "container", "ok" ]
          },
          {
            "description": "The project directory, whose entry count is compared with the host's.",
            "type": "object",
            "properties": {
              "host": { "type": "string" },
              "container": { "type": "string" },
              "entries": { "type": [ "integer", "null" ] },
              "expected": { "type": [ "integer", "null" ] },
              "ok": { "type": "boolean" }
            },
            "required": [ "host", "container", "entries", "expected", "ok" ]
          }
        ]
      }
    },
    "issues": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "problem": { "type": "string" },
          "remedies": {
            "type": "array",
            "items": { "type": "string" }
          }
        },
        "required": [ "problem", "remedies" ]
      }
    }
  },
  "required": [
    "schema_version",
    "ready",
    "problems",
    "host",
    "docker",
    "image",
    "mounts",
    "issues"
  ]
}
JSON

sub json_schema {
    return JSON::PP->new->decode($JSON_SCHEMA);
}


my %PLATFORM_NAME = (
    linux   => 'Linux',
    darwin  => 'macOS',
    MSWin32 => 'Windows',
    cygwin  => 'Cygwin',
    msys    => 'MSYS',
);

sub new {
    my ($class, %args) = @_;

    my $image = defined $args{image} && length $args{image}
        ? $args{image}
        : 'alpine:3.20';

    return bless {
        docker_bin => $args{docker_bin},
        image      => $image,
        platform   => $args{platform},
        directory  => $args{directory},
        # The platform decides the wording of the remedies, so it is a value
        # rather than a call to $^O buried in the messages.
        os         => defined $args{os} && length $args{os} ? $args{os} : $^O,
        output     => $args{output} || \*STDOUT,
        # A caller that prints its own heading and verdict, such as the smoke
        # test, can ask for the report without them.
        title      => exists $args{title} ? $args{title} : 'action-run check',
        summary    => exists $args{summary} && !$args{summary} ? 0 : 1,
        # A caller that probes before a workflow wants silence when all is
        # well, and the whole report when it is not.
        quiet      => $args{quiet} ? 1 : 0,
        # A machine-readable report instead of the text one, for CI.
        json       => $args{json} ? 1 : 0,
        # The text report names the schema the JSON document is written
        # against, so a pasted report says which contract it came from.  A
        # caller whose own report is not that document - the preflight, which
        # has a document of its own, and the smoke test, which prints none -
        # turns the line off.
        schema_line => exists $args{schema_line} && !$args{schema_line} ? 0 : 1,
        problems   => 0,
        data       => { mounts => [], issues => [] },
    }, $class;
}

sub image { return $_[0]->{image} }

sub json_schema_version { return $JSON_SCHEMA_VERSION }

# Report the host, the Docker daemon and a real bind mount.  Returns 0 when
# every check passed and 2 when something needs fixing, matching the exit
# codes of the rest of the command line tool.
sub run {
    my ($self) = @_;

    # The report is built in a buffer so that a quiet run can drop it when
    # every check passed, without the checks themselves knowing.
    my $target = $self->{output};
    my $report = '';
    open my $buffer, '>', \$report or die "Unable to buffer the check report: $!";
    $self->{output} = $buffer;

    my $exit = $self->_run_checks;

    $self->{output} = $target;
    close $buffer;

    # The JSON report replaces the text one rather than joining it, so that
    # its output can be piped straight into jq or a CI assertion.
    if ($self->{json}) {
        print {$target} $self->_json_report($exit), "\n";
        return $exit;
    }

    print {$target} $report if $self->{problems} || !$self->{quiet};

    return $exit;
}

sub _run_checks {
    my ($self) = @_;

    $self->{problems} = 0;
    $self->{data} = { mounts => [], issues => [] };
    my $out = $self->{output};

    print {$out} "$self->{title}\n" if defined $self->{title} && length $self->{title};
    print {$out} '  host      ', $self->_host_description, "\n";

    $self->{data}{host} = $self->host_info;

    my $docker = App::Actions::Docker->new(
        bin      => $self->{docker_bin},
        platform => $self->{platform},
        quiet    => 1,
    );
    $self->{data}{docker} = { bin => $docker->bin };
    print {$out} '  docker    ', $docker->bin, "\n";

    if ($self->_check_daemon($docker)) {
        $self->_check_mounts($docker);
    }

    # The version comes before the verdict, so a report pasted into an issue
    # says which contract the lines above were written against.
    if ($self->{schema_line}) {
        print {$out} '  schema    version ', $JSON_SCHEMA_VERSION,
            " (action-run schema check)\n";
    }

    if ($self->{problems}) {
        if ($self->{summary}) {
            my $plural = $self->{problems} == 1 ? '' : 's';
            print {$out} "Result: not ready ($self->{problems} problem$plural)\n";
        }
        return 2;
    }

    print {$out} "Result: ready\n" if $self->{summary};
    return 0;
}

# The host part of the report.  It is local knowledge rather than probe
# knowledge, so a caller that skips the checks (a preflight with --skip-check)
# can still report a host instead of an empty object the schema would reject.
sub host_info {
    my ($invocant, $os) = @_;

    $os = $invocant->{os} if !defined $os && ref $invocant eq 'HASH';
    $os = $^O unless defined $os && length $os;

    return {
        os       => $os,
        name     => $PLATFORM_NAME{$os} || $os,
        perl     => sprintf('%vd', $^V),
        archname => $Config{archname},
    };
}

sub _host_description {
    my $os = $_[0]->{os};
    my $name = $PLATFORM_NAME{$os} || $os;

    return sprintf '%s (%s), perl %vd, %s', $name, $os, $^V, $Config{archname};
}

sub _check_daemon {
    my ($self, $docker) = @_;

    my ($client, $client_rc) = $docker->capture_silent(
        'version', '--format', '{{.Client.Version}}',
    );
    if ($client_rc != 0 || !length _trim($client)) {
        $self->_problem(
            "the Docker command '$docker->{bin}' could not be run",
            $self->_is_windows()
                ? 'install Docker Desktop, or pass --docker with the full path to docker.exe'
                : 'install Docker, or pass --docker with the full path to the docker executable',
        );
        return 0;
    }
    $self->{data}{docker}{client} = _trim($client);
    print {$self->{output}} '  client    ', _trim($client), "\n";

    my ($server, $server_rc) = $docker->capture_silent(
        'version', '--format', '{{.Server.Version}}',
    );
    if ($server_rc != 0 || !length _trim($server)) {
        my @remedies = $self->_is_windows()
            ? (   'start Docker Desktop and wait until it is running, then try again',
                  'if the engine will not start, run "wsl --shutdown" and start Docker Desktop again',
              )
            : (   'start the Docker daemon, for example "sudo systemctl start docker"',
                  'or point DOCKER_HOST at a daemon that is already running',
              );
        $self->_problem(
            'the daemon is not reachable; is Docker running and can this user access it?',
            @remedies,
        );
        return 0;
    }

    my ($ostype, $ostype_rc) = $docker->capture_silent(
        'info', '--format', '{{.OSType}}',
    );
    my $containers = $ostype_rc == 0 && length _trim($ostype)
        ? lc _trim($ostype)
        : 'unknown';

    $self->{data}{docker}{daemon}     = _trim($server);
    $self->{data}{docker}{containers} = $containers;
    print {$self->{output}} '  daemon    ', _trim($server), ", $containers containers\n";

    if ($containers ne 'linux') {
        $self->_problem(
            "the daemon runs '$containers' containers; action-run needs Linux containers",
            $self->_is_windows()
                ? 'right-click the Docker Desktop tray icon and choose "Switch to Linux containers"'
                : 'point DOCKER_HOST at a daemon that runs Linux containers',
        );
        return 0;
    }

    return 1;
}

# Mount a temporary directory and, when asked, the project directory, then
# read a token back from inside a container.  A bind mount that silently maps
# something else fails this, which is what happens on Windows when Docker
# Desktop does not share the drive.
sub _check_mounts {
    my ($self, $docker) = @_;

    my $temp = File::Temp->newdir('action-run-check-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $token = join '-', time, $$;
    my $marker = File::Spec->catfile("$temp", 'marker');
    open my $handle, '>', $marker
        or return $self->_problem(
            "cannot write '$marker': $!",
            'check the permissions of the temporary directory, or set TMPDIR',
        );
    binmode $handle;
    print {$handle} $token;
    close $handle;

    my @mounts = ("$temp:/action-run-check");
    my $project;
    if (defined $self->{directory}) {
        $project = File::Spec->rel2abs($self->{directory});
        if (!-d $project) {
            return $self->_problem(
                "'$project' is not a directory",
                'pass a directory that exists, or leave the argument out',
            );
        }
        push @mounts, "$project:/check-project:ro";
    }

    my $command = 'cat /action-run-check/marker; echo; ';
    $command .= defined $project ? 'ls -A /check-project | wc -l' : 'echo 0';

    my @args = ('run', '--rm', '--network', 'none');
    push @args, $docker->platform_args;
    push @args, '-v', $_ for @mounts;
    push @args, $self->{image}, 'sh', '-c', $command;

    $self->{data}{image} = $self->{image};
    print {$self->{output}} '  image     ', $self->{image}, "\n";

    my ($output, $rc) = $docker->capture(@args);
    if ($rc != 0) {
        return $self->_problem(
            "the probe container failed (exit $rc)",
            "run \"docker pull $self->{image}\" by hand to see the error",
            'on an ARM host add --platform linux/amd64 for x86-only images',
        );
    }

    my ($returned) = split /\n/, defined $output ? $output : '', 2;
    if (!defined $returned || _trim($returned) ne $token) {
        return $self->_problem(
            'the container could not read the mounted temporary directory',
            $self->_is_windows()
                ? 'share the drive that holds the temporary directory in Docker Desktop > Settings > Resources > File sharing'
                : 'a bind mount needs a local daemon; a remote DOCKER_HOST cannot see this machine\'s paths',
        );
    }
    push @{ $self->{data}{mounts} }, {
        host      => "$temp",
        container => '/action-run-check',
        ok        => JSON::PP::true(),
    };
    print {$self->{output}} "  mount     $temp -> /action-run-check: OK\n";

    return 1 unless defined $project;

    my (undef, $seen) = split /\n/, defined $output ? $output : '';
    $seen = _trim($seen);
    my $expected = _entry_count($project);
    my $manifest = {
        host      => $project,
        container => '/check-project',
        entries   => defined $seen && $seen =~ /^\d+$/ ? $seen + 0 : undef,
        expected  => $expected,
        ok        => JSON::PP::false(),
    };
    push @{ $self->{data}{mounts} }, $manifest;

    if (!defined $seen || $seen !~ /^\d+$/) {
        return $self->_problem("could not count the entries in '$project'");
    }
    if (!defined $expected || $seen != $expected) {
        my $host = defined $expected ? $expected : 'unknown';
        return $self->_problem(
            "'$project' -> /check-project sees $seen entries, the host has $host",
            $self->_is_windows()
                ? "share the drive that holds '$project' in Docker Desktop > Settings > Resources > File sharing"
                : 'choose a directory the daemon can see, or point DOCKER_HOST at a local daemon',
        );
    }

    $manifest->{ok} = JSON::PP::true();
    my $unit = $seen == 1 ? 'entry' : 'entries';
    print {$self->{output}}
        "  mount     $project -> /check-project: OK ($seen $unit)\n";

    return 1;
}

sub _entry_count {
    my ($directory) = @_;

    # An unreadable directory has no count, which is not the same as empty.
    my $count;
    if (opendir my $handle, $directory) {
        $count = grep { $_ ne '.' && $_ ne '..' } readdir $handle;
        closedir $handle;
    }

    return $count;
}

# Report a problem with the concrete step that fixes it.  A diagnosis without
# a remedy is only half a check: the reader is left to guess whether to start
# Docker, share a drive, or switch container types.
sub _problem {
    my ($self, $message, @remedies) = @_;

    print {$self->{output}} "  problem   $message\n";
    my @given;
    for my $remedy (@remedies) {
        next unless defined $remedy && length $remedy;
        print {$self->{output}} "  remedy    $remedy\n";
        push @given, $remedy;
    }
    $self->{problems}++;

    push @{ $self->{data}{issues} }, {
        problem  => $message,
        remedies => \@given,
    };

    return 0;
}

# The report as data, so that a caller can add to it (the preflight adds the
# images it prepared) or assert on it without parsing text.  The keys are
# stable and values that could not be discovered are null rather than absent.
# "ready" is a plain 0 or 1 here; the JSON encoder turns it into true or false.
sub summary {
    my ($self, $exit) = @_;

    my $data = $self->{data} || {};
    my $docker = $data->{docker} || {};

    return {
        schema_version => $JSON_SCHEMA_VERSION,
        ready    => $exit == 0 ? 1 : 0,
        problems => $self->{problems} + 0,
        host     => $data->{host} || {},
        docker   => {
            bin        => $docker->{bin},
            client     => $docker->{client},
            daemon     => $docker->{daemon},
            containers => $docker->{containers},
        },
        image    => $data->{image},
        mounts   => $data->{mounts} || [],
        issues   => $data->{issues} || [],
    };
}

# The machine-readable form of the report, for CI.  The document is held to
# its own schema before it is encoded, so a key that was added, removed or
# retyped without the schema changing stops the report here rather than in an
# assertion at the far end of a pipeline.
sub _json_report {
    my ($self, $exit) = @_;

    my $summary = $self->summary($exit);
    $summary->{ready} = $exit == 0 ? JSON::PP::true() : JSON::PP::false();

    App::Actions::Schema::assert_valid(
        $summary, $self->json_schema,
        'the action-run check --json document does not match App::Actions::Check->json_schema',
    );

    return JSON::PP->new->canonical->encode($summary);
}

sub _is_windows {
    my $os = $_[0]->{os};

    return $os eq 'MSWin32' || $os eq 'cygwin' || $os eq 'msys';
}

sub _trim {
    my ($value) = @_;

    my $trimmed = defined $value ? $value : '';
    $trimmed =~ s/^\s+//;
    $trimmed =~ s/\s+$//;

    return $trimmed;
}

1;

__END__

=head1 NAME

App::Actions::Check - diagnose the host, Docker and bind mounts for App::Actions

=head1 SYNOPSIS

    use App::Actions::Check;

    my $check = App::Actions::Check->new(
        docker_bin => 'docker',
        image      => 'alpine:3.20',
        directory  => '/path/to/project',
    );
    my $exit_code = $check->run;

=head1 DESCRIPTION

L<App::Actions::Check> performs the checks that explain most failures to run
a workflow locally: whether the host is one that C<action-run> supports,
whether the Docker daemon is reachable and can run Linux containers, and
whether Docker can bind-mount the host directories that a run needs.

The mount check starts one short-lived container, mounts a temporary
directory and reads a file back from it.  When C<directory> is given, that
directory is mounted read-only as well and the number of entries visible
inside the container is compared with the host, which catches a drive that
Docker Desktop has not shared.

Every problem is followed by one or more C<remedy> lines naming the step that
fixes it: starting Docker Desktop or the daemon, switching Docker Desktop to
Linux containers, sharing the drive that holds the temporary or project
directory, pulling the probe image by hand, or choosing another directory.
The remedies name the tools of the platform the check runs on.

The text report names the version of the schema that its JSON document is
written against, on a C<schema> line before the verdict, so a report pasted
into an issue says which contract its lines belong to.  Set C<schema_line> to
false in a caller whose own report is not that document, such as the
preflight, which has one of its own.

=head1 METHODS

=head2 new

    my $check = App::Actions::Check->new(%options);

Options are C<docker_bin>, C<image> (default C<alpine:3.20>), C<platform>
(passed to Docker as C<--platform>), C<directory> (an extra directory to
test), C<output> (a filehandle, default C<STDOUT>), C<title> (the heading,
default C<action-run check>; an empty string leaves it out), C<summary>
(default true; set it to false to leave the final C<Result:> line to the
caller), C<quiet> (print nothing unless a problem was found), C<json> (print
one JSON object instead of the text report), C<schema_line> (default true;
set it to false to leave the schema version out of a report that is not the
check document) and C<os> (the platform whose remedies are printed, default
C<$^O>; set it to report for another host, for example when pasting a report
into a bug tracker).

=head2 run

Prints a report and returns 0 when every check passed, or 2 when a problem
was found.

=head2 image

Returns the image used for the mount probe.

=head2 summary

    my $report = $check->summary($exit);

Returns the report as a hash reference instead of printing it, with the keys
described under L</JSON OUTPUT>.  C<ready> is a plain 0 or 1 here, so a caller
that encodes it as JSON should convert it to a JSON boolean.  The preflight
uses this to add the images it prepared.

=head2 json_schema

    my $schema = App::Actions::Check->json_schema;

Returns the JSON schema of the C<check --json> document as a hash, the same
document C<action-run schema check> prints.  It lives here rather than in the
test directory so that an installed distribution can hand the contract to a
caller; F<t/schema.t> validates the example and the document against it.

=head2 json_schema_version

    my $version = App::Actions::Check->json_schema_version;

Returns the version of the JSON document, which is also its C<schema_version>
key.  It is bumped when the shape changes, so an assertion can name the shape
it was written for.

=head1 JSON OUTPUT

With C<json> the report is a single object, with every key always present and
C<null> for a value that could not be discovered:

    {
      "schema_version": 2,
      "ready": true,
      "problems": 0,
      "host": { "os": "linux", "name": "Linux", "perl": "5.40.0", "archname": "x86_64-linux" },
      "docker": { "bin": "docker", "client": "29.9.1", "daemon": "29.9.1", "containers": "linux" },
      "image": "alpine:3.20",
      "mounts": [
        { "host": "/tmp/action-run-check-XXXX", "container": "/action-run-check", "ok": true },
        { "host": "/src/project", "container": "/check-project", "entries": 17, "expected": 17, "ok": true }
      ],
      "issues": [ { "problem": "...", "remedies": [ "..." ] } ]
    }

C<schema_version> names the shape of the document; it is the number
L</json_schema_version> returns.  The schema is what C<action-run schema
check> prints, and the checked-in examples are F<t/fixtures/check.json> (a
passing report), F<t/fixtures/check-unready.json> (a mount mismatch),
F<t/fixtures/check-unreachable.json> (Docker could not be run, so its version
fields and the probe image are C<null>) and F<t/fixtures/check-uncounted.json>
(the probe ran but could not count the project's entries, so both counts are
C<null>).  F<t/schema.t> validates them against it and fails when a property,
an enum value or a null variant it names appears in none of them, so a shape
left behind by the code or by the schema cannot hide there.

Before the document is printed it is validated against that schema, so a key
that was added, removed or retyped without the schema being updated is an
error here rather than a surprise in the assertion that reads it.  Nothing is
printed when that happens: the exception is an
L<App::Actions::Schema::Invalid|App::Actions::Schema/App::Actions::Schema::Invalid>
carrying the first mismatch and the number of others, which C<action-run>
turns into exit 70.

The exit status is unchanged, so a caller may use either.

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
