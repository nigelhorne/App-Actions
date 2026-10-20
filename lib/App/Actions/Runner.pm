package App::Actions::Runner;

use strict;
use warnings;
use Carp qw(croak);
use Cwd qw(abs_path);
use File::Basename qw(basename);
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Temp ();
use IO::Handle ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Text::ParseWords qw(shellwords);
use Time::HiRes qw(sleep);

use App::Actions::Action;
use App::Actions::Check;
use App::Actions::Docker;
use App::Actions::Expression;
use App::Actions::Process;
use App::Actions::Schema;

our $VERSION = '0.01';

# The shape of the preflight JSON document, which is the check document with
# an images array and the pull concurrency added.  It is versioned separately
# from the check document because the two can gain keys independently, but a
# change to the shared part bumps both.  Keep the schema below and the examples
# in t/fixtures/ in step.
#
# 3: docker.bin stopped being nullable, with the check document's 2.  It is
# always the resolved command, so the null type promised a shape no document
# can produce; t/schema.t requires every enum value and null variant to appear
# in the examples, which is what found it.
our $PREFLIGHT_SCHEMA_VERSION = 3;

# The schema of the document preflight --json prints, so that the installed
# action-run can hand the contract to a caller instead of leaving it in the
# tests.  A change to the document belongs here, in $JSON_SCHEMA_VERSION and
# in the examples in t/fixtures/, which t/schema.t holds against this and
# fails when a key it names appears in none of them.
my $JSON_SCHEMA = <<'JSON';
{
  "title": "action-run preflight --json",
  "description": "The document action-run preflight --json prints: the check document with an images array and the pull concurrency added.  Objects reject keys this file does not name, so a new key is a schema change.",
  "version": 3,
  "type": "object",
  "properties": {
    "schema_version": {
      "description": "The version of this shape; App::Actions::Runner->preflight_schema_version returns it.",
      "type": "integer",
      "const": 3
    },
    "ready": {
      "description": "True only when the checks passed and every image was prepared; a deferred image does not make the run unready.",
      "type": "boolean"
    },
    "problems": {
      "description": "How many problems were found, counting the failed images.",
      "type": "integer"
    },
    "pull_concurrency": {
      "description": "How many pulls the preflight allowed at once: the configured setting, but 1 on Windows, where images are pulled one at a time.  It is the number the puller was given, not how many pulls happened to overlap.",
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
    },
    "images": {
      "description": "Every image the selected jobs need, in the order the run would need it.",
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "image": {
            "description": "The image name, or null when it could not be resolved yet.",
            "type": [ "string", "null" ]
          },
          "source": {
            "description": "The job, service or action that needs it.",
            "type": "string"
          },
          "status": {
            "type": "string",
            "enum": [ "pulled", "present", "failed", "skipped", "deferred" ]
          },
          "expression": {
            "description": "Only on a deferred entry: the image name as it was written.",
            "type": "string"
          },
          "error": {
            "description": "Only on a failed or deferred entry: why it was not prepared or named.",
            "type": "string"
          }
        },
        "required": [ "image", "source", "status" ]
      }
    }
  },
  "required": [
    "schema_version",
    "ready",
    "problems",
    "pull_concurrency",
    "host",
    "docker",
    "image",
    "mounts",
    "issues",
    "images"
  ]
}
JSON

sub json_schema {
    my ($class) = @_;

    return JSON::PP->new->decode($JSON_SCHEMA);
}


sub new {
    my ($class, %args) = @_;

    croak 'A workflow is required' unless $args{workflow};
    croak 'A project directory is required' unless defined $args{project_dir};

    my $project_dir = abs_path($args{project_dir});
    croak "Project directory '$args{project_dir}' does not exist"
        unless defined $project_dir && -d $project_dir;

    my $self = bless {
        workflow      => $args{workflow},
        project_dir   => $project_dir,
        jobs          => $args{jobs} || [],
        image         => $args{image},
        perl_image    => $args{perl_image} || 'perl:%s',
        platform      => $args{platform},
        user          => $args{user},
        env           => $args{env} || {},
        secrets       => $args{secrets} || {},
        # An explain run starts nothing, so it is a dry run whose output is
        # the containers rather than the commands that would start them.
        dry_run       => ($args{dry_run} || $args{explain}) ? 1 : 0,
        explain       => $args{explain} ? 1 : 0,
        verbose       => $args{verbose} ? 1 : 0,
        quiet         => $args{quiet} ? 1 : 0,
        keep          => $args{keep} ? 1 : 0,
        keep_images   => $args{keep_images} ? 1 : 0,
        pull          => $args{pull} ? 1 : 0,
        no_pull       => $args{no_pull} ? 1 : 0,
        strict_actions => $args{strict_actions} ? 1 : 0,
        skip_check    => $args{skip_check} ? 1 : 0,
        pull_concurrency => _pull_concurrency($args{pull_concurrency}),
        expression    => App::Actions::Expression->new,
        run_id        => sprintf('%x%04x', time, $$ & 0xffff),
        pulled_images => {},
        # Every image this run has pulled, including one that was already
        # present and was refreshed by --pull.  --pull downloads each image
        # once per run, so a later check of the same image costs nothing.
        pulled_once   => {},
        containers    => [],
        networks      => [],
        summary       => [],
        name_counter  => 0,
        workflow_failed => 0,
        cleaned_up    => 0,
    }, $class;

    if (ref $args{docker}) {
        $self->{docker} = $args{docker};
    } else {
        $self->{docker} = App::Actions::Docker->new(
            bin      => $args{docker_bin},
            dry_run  => $self->{dry_run},
            explain  => $self->{explain},
            verbose  => $self->{verbose},
            quiet    => $self->{quiet},
            platform => $self->{platform},
            secrets  => $self->{secrets},
        );
    }

    croak '--pull and --no-pull cannot be used together'
        if $self->{pull} && $self->{no_pull};

    return $self;
}

# How many images may be pulled at the same time.  The option wins over the
# environment, which wins over four: four downloads saturate most connections
# without burying the pull output or the daemon.
sub _pull_concurrency {
    my ($value) = @_;

    if (!defined $value || !length $value) {
        $value = $ENV{ACTION_RUN_PULL_CONCURRENCY};
        return 4 if !defined $value || !length $value;
    }

    croak "pull concurrency must be a positive integer, not '$value'"
        unless !ref $value && $value =~ /^[1-9][0-9]*$/;

    return $value + 0;
}

sub workflow { return $_[0]->{workflow} }

sub list_jobs {
    my ($self) = @_;

    my $instances = $self->{workflow}->expand_jobs;
    $self->_select_jobs($instances);

    for my $instance (@{ $self->{instances} }) {
        print $instance->{base_id}, "\t", $self->_redact($instance->{display_name}), "\n";
    }

    return 0;
}

sub run {
    my ($self) = @_;

    my $exit_code = 0;

    local $SIG{INT}  = sub { die "Interrupted\n" };
    local $SIG{TERM} = sub { die "Terminated\n" };

    eval {
        # Selecting the jobs first means the probes can use the image the run
        # is about to use, so a working setup needs no extra pull.
        my $instances = $self->{workflow}->expand_jobs;
        $self->_select_jobs($instances);

        $self->_check_environment($instances) unless $self->{dry_run};

        $self->_prepare_temp;
        $self->_build_base_env;

        $self->_run_groups;
        $self->_print_summary;

        $exit_code = $self->{workflow_failed} ? 1 : 0;
    };

    if ($@) {
        my $error = $@;
        $error =~ s/\s+$//;
        # Whatever the run printed belongs before the error, even when the two
        # are written through different buffers.
        STDOUT->flush;
        print STDERR "action-run: $error\n" unless $self->{quiet};
        $exit_code = 2;
    }

    $self->_cleanup;

    return $exit_code;
}

sub preflight_schema_version { return $PREFLIGHT_SCHEMA_VERSION }

# Probe the host before starting anything: the daemon, the container type,
# and a real bind mount of the project directory.  Without this the first
# symptom of an unshared drive or a Windows-only daemon is a job that cannot
# see its own checkout.
sub _check_environment {
    my ($self, $instances) = @_;

    # --skip-check skips the probes, not the question "is Docker there?",
    # because a cryptic failure deeper in the run helps nobody.
    if ($self->{skip_check}) {
        $self->{docker}->check;
        return;
    }

    my $check = App::Actions::Check->new(
        docker_bin => $self->_docker_bin,
        image      => $self->_probe_image($instances),
        platform   => $self->{platform},
        directory  => $self->{project_dir},
        # Silent when everything works, a full report with remedies when not.
        quiet      => $self->{verbose} ? 0 : 1,
    );

    if ($check->run != 0) {
        # die, not croak, and with a trailing newline: the advice should read
        # as a sentence rather than end in " at <file> line <n>".
        die "the environment is not ready; fix what the report above asks for, or pass --skip-check to run anyway\n";
    }

    my ($records, $failures) = $self->_prepare_images($instances);

    if (@$failures) {
        die _image_failure_message($failures->[0]) . "\n";
    }
}

# Probe the environment and prepare the images without starting a job, so
# that a caller can report the outcome as data rather than as prose.  Returns
# the exit code, the check's summary with one record per image added, and the
# message a run would have stopped with.
#
# With json => 1 nothing is printed: the checks write into a buffer that is
# thrown away and docker's pull output is discarded, so the caller's standard
# output is free for a single document.
sub preflight {
    my ($self, %options) = @_;

    my $json = $options{json} ? 1 : 0;

    # Whether the text report names the document version at the end.  A caller
    # that prints its own report, such as the smoke test, turns it off.
    my $schema_line = defined $options{schema_line} && !$options{schema_line} ? 0 : 1;

    # The number of pulls this preflight was allowed to make at once.  It is
    # reported even when nothing was pulled, so that a caller can assert that
    # a setting reached the puller rather than inferring it from the run.
    my $concurrency = $self->_effective_pull_concurrency;

    my $instances = $self->{workflow}->expand_jobs;
    $self->_select_jobs($instances);

    my $check;
    my $check_exit = 0;
    my $summary;

    if ($self->{skip_check}) {
        # The same meaning as during a run: no probes, but Docker still has
        # to answer before anything is pulled.
        my $reachable = eval { $self->{docker}->check; 1 };
        my $error = $reachable ? undef : _trim_error($@);

        $summary = {
            schema_version => $PREFLIGHT_SCHEMA_VERSION,
            ready    => $reachable ? 1 : 0,
            problems => $reachable ? 0 : 1,
            pull_concurrency => $concurrency,
            # The host needs no probe, so it is reported even here: a
            # consumer of the document sees the same keys either way.
            host     => App::Actions::Check->host_info,
            docker   => {
                bin        => $self->_docker_bin,
                client     => undef,
                daemon     => undef,
                containers => undef,
            },
            image    => undef,
            mounts   => [],
            issues   => $reachable
                ? []
                : [ { problem => $error, remedies => [] } ],
        };

        return {
            exit    => $reachable ? 0 : 2,
            summary => $self->_preflight_document(
                summary     => $summary,
                ready       => $reachable,
                issues      => $summary->{issues},
                images      => [],
                concurrency => $concurrency,
                json        => $json,
            ),
            error   => $error,
        } unless $reachable;

        $check_exit = 0;
    }
    else {
        my $report = '';
        my %check_args = (
            docker_bin => $self->_docker_bin,
            image      => $self->_probe_image($instances),
            platform   => $self->{platform},
            directory  => $self->{project_dir},
            # Silent when everything works, a full report with remedies when
            # not.  A JSON caller keeps even that out of its streams.
            quiet      => $json ? 1 : ($self->{verbose} ? 0 : 1),
            # The preflight has a document of its own, with a version of its
            # own; the line below names that one, not the check's.
            schema_line => 0,
        );

        if ($json) {
            open my $sink, '>', \$report
                or die "Unable to buffer the preflight report: $!\n";
            $check_args{output} = $sink;
        }

        $check = App::Actions::Check->new(%check_args);
        $check_exit = $check->run;
        $summary = $check->summary($check_exit);
    }

    my (@records, @failures);

    if ($check_exit != 0) {
        # Nothing is pulled when the environment is not ready, but what the
        # run would have needed is still worth reporting.
        for my $entry ($self->_required_images($instances)) {
            my %record = (
                source => $entry->{source},
                status => 'skipped',
            );

            if (defined $entry->{image}) {
                $record{image} = $entry->{image};
            }
            else {
                $record{image}      = undef;
                $record{expression} = $entry->{expression};
                $record{error}      = $entry->{error};
            }

            push @records, \%record;
        }
    }
    else {
        my ($prepared, $failed) = $self->_prepare_images($instances, quiet => $json);
        @records  = @$prepared;
        @failures = @$failed;
    }

    my @issues = @{ $summary->{issues} || [] };
    for my $failure (@failures) {
        push @issues, {
            problem  => _image_failure_message($failure),
            remedies => [
                'check the image name, and that the registry is reachable and the Docker login is valid',
            ],
        };
    }

    # A text caller reads the images rather than the JSON document, so each
    # one is named with what needed it and what became of it.  A deferred
    # image is named by its expression, because that is all there is until its
    # step has run.
    _report_images(\@records) unless $json;

    # The version comes last, where the check report puts it, so a pasted
    # preflight report says which contract the lines above were written
    # against.
    print '  schema    version ', $PREFLIGHT_SCHEMA_VERSION,
        " (action-run schema preflight)\n" if $schema_line && !$json;

    my $ready = $summary->{ready} && !@failures;

    return {
        exit    => $ready ? 0 : 2,
        summary => $self->_preflight_document(
            summary     => $summary,
            ready       => $ready,
            issues      => \@issues,
            images      => \@records,
            concurrency => $concurrency,
            json        => $json,
        ),
        error => @failures
            ? _image_failure_message($failures[0])
            : ($ready ? undef
                : 'the environment is not ready; fix what the report above asks for, or pass --skip-check to run anyway'),
    };
}

# The document the preflight reports, built in one place so that a text
# caller, a JSON caller and a JSON caller whose daemon is unreachable all get
# the same keys.  A JSON document is validated against the schema shipped with
# this module before the caller can print it, so a key that was added, removed
# or retyped without the schema changing fails here rather than in the
# assertion that reads the document.
sub _preflight_document {
    my ($self, %args) = @_;

    my $summary = $args{summary} || {};
    my $ready   = $args{ready} ? 1 : 0;

    my $document = {
        %$summary,
        schema_version => $PREFLIGHT_SCHEMA_VERSION,
        ready    => $ready ? 1 : 0,
        problems => scalar @{ $args{issues} || [] },
        pull_concurrency => $args{concurrency},
        issues   => $args{issues} || [],
        images   => $args{images} || [],
    };

    if ($args{json}) {
        # The printed document says true or false, so it is validated in the
        # form it is printed in rather than after a conversion.
        $document->{ready} = $ready ? JSON::PP::true() : JSON::PP::false();

        App::Actions::Schema::assert_valid(
            $document, $self->json_schema,
            'the action-run preflight --json document does not match App::Actions::Runner->json_schema',
        );
    }

    return $document;
}

# Pull or verify every image the run will need, so that a mistyped service
# image fails now rather than halfway through a job with its containers up.
#
# The presence checks are cheap and run in turn, because an image that is
# already there needs no pull and one that is not available locally should
# stop the run before anything is downloaded.  The pulls themselves run
# together, so a hundred-image matrix does not wait for them one at a time.
#
# Returns one record per image, in the order the run will need them, and the
# records that failed.  A record is { image, source, status, error }, where
# status is "present", "pulled", "failed" or "deferred"; the caller decides
# whether a failure stops the run or is only reported.  A deferred record is
# one the values available before the run cannot name; it carries the
# expression and the reason, and the job prepares it once it knows more.
sub _prepare_images {
    my ($self, $instances, %options) = @_;

    my $quiet = $options{quiet} ? 1 : 0;
    my @records;
    my @pending;

    for my $entry ($self->_required_images($instances)) {
        my $image  = $entry->{image};
        my $source = $entry->{source};

        if (!defined $image) {
            # No job has run yet, so a value that comes from a step or from
            # another job's output is not known here.  Rather than guess at an
            # image name, the record says what could not be resolved; the job
            # checks it again before it starts, when the value exists.
            push @records, {
                image      => undef,
                expression => $entry->{expression},
                source     => $source,
                status     => 'deferred',
                error      => $entry->{error},
            };
            next;
        }

        print "  image     $image ($source)\n"
            if $self->{verbose} && !$self->{quiet} && !$quiet;

        my $present = $self->{dry_run} ? 1 : $self->{docker}->image_exists($image);

        if ($present && !$self->{pull}) {
            push @records, { image => $image, source => $source, status => 'present' };
            next;
        }

        # --no-pull is advice, so it is given as a sentence rather than as a
        # source location, and before any image is downloaded.
        if ($self->{no_pull}) {
            push @records, {
                image  => $image,
                source => $source,
                status => 'failed',
                error  => "Docker image '$image' is not available locally (--no-pull)",
            };
            next;
        }

        push @records, {
            image   => $image,
            source  => $source,
            status  => 'pending',
            present => $present,
        };
        push @pending, $records[-1];
    }

    my @failed = grep { $_->{status} eq 'failed' } @records;
    return (\@records, \@failed) if @failed;

    return (\@records, []) unless @pending;

    unless ($self->{quiet} || $quiet) {
        print "Pulling image $_->{image}...\n" for @pending;
    }

    my $results = {};

    if (!$self->{docker}->can('pull_many')) {
        # A caller-supplied Docker object need only offer the single-image
        # calls.
        for my $record (@pending) {
            my $image = $record->{image};
            my $pulled = eval { $self->{docker}->pull($image); 1 };
            if ($pulled) {
                $results->{$image} = 0;
                next;
            }

            my $error = _trim_error($@);
            $results->{$image} = 1;
            $record->{error} = $error if defined $error && length $error;
        }
    }
    else {
        my @images = map { $_->{image} } @pending;
        $results = $self->{docker}->pull_many(
            \@images,
            concurrency => $self->_effective_pull_concurrency,
            ($quiet ? (quiet => 1) : ()),
        );
    }

    # Every image that did arrive is recorded before the failure is reported,
    # so the cleanup at the end of the run removes it.  The first failure in
    # the order the run needs the images is the one worth naming.
    for my $record (@pending) {
        my $image = $record->{image};
        my $rc = $results->{$image};

        if ($rc != 0) {
            $record->{status} = 'failed';
            $record->{error} = "Failed to pull Docker image '$image' (exit $rc)"
                unless defined $record->{error} && length $record->{error};
            next;
        }

        $self->{pulled_images}{$image} = 1 unless $record->{present};
        $self->{pulled_once}{$image} = 1;
        $record->{status} = 'pulled';
    }

    for my $record (@records) {
        delete $record->{present};
    }

    my @still_failed = grep { $_->{status} eq 'failed' } @records;

    return (\@records, \@still_failed);
}

# The final check of one job's images, made with the values the job itself
# has.  The preflight runs before any job has, so an image built from another
# job's outputs is deferred there; this is where it is resolved and prepared,
# while the job still has no network and no containers.  A failure therefore
# ends the run before the job starts rather than halfway through it.
#
# The one kind of image that cannot be known yet is the one a step decides,
# because an output does not exist until its step has run.  Those are returned
# so the caller can report them; the step that needs one prepares it before
# starting its container.
#
# Returns the image the job container uses and the deferred expressions.
sub _prepare_job_images {
    my ($self, $job, $context) = @_;

    my $runs_on = $self->{workflow}->runs_on_text(
        $job->{'runs-on'}, $job->{matrix} || {},
    );

    my $job_image;
    my @deferred;
    my %seen;

    for my $entry ($self->_job_image_expressions($job, $runs_on, $context)) {
        my $expression = $entry->{expression};
        my $source     = $entry->{source};
        my $kind       = $entry->{kind};

        my $image = eval {
            $self->{expression}->interpolate_strict($expression, $context);
        };
        my $error = _trim_error($@);

        if (!defined $image || !length $image) {
            $error = 'the image name is empty'
                unless defined $error && length $error;

            # A job or a service container is started by the run itself, so a
            # name that cannot be resolved now is a workflow error the run can
            # report before it does anything.
            if ((defined $kind && $kind eq 'job')
                || (defined $kind && $kind =~ /^service:/)) {
                die "cannot resolve the image '$expression', needed by $source: $error\n";
            }

            push @deferred, {
                expression => $expression,
                source     => $source,
                error      => $error,
            };
            next;
        }

        $job_image = $image if defined $kind && $kind eq 'job';

        # Two steps may name the same image; it is prepared once.
        next if $seen{$image}++;

        my $prepared = eval { $self->_ensure_image($image); 1 };
        next if $prepared;

        my $failure = _trim_error($@);
        die "cannot prepare the image '$image', needed by $source: $failure\n";
    }

    return ($job_image, \@deferred);
}

# A croak() carries the source location, which is useful in a stack trace
# and noise in a report someone reads.  Everything that ends up in a summary
# or an error message goes through here first.
sub _trim_error {
    my ($error) = @_;

    return undef unless defined $error && length $error;

    $error =~ s/\s+$//;
    $error =~ s/\s+at\s+.+? line \d+\.?\z//;
    $error =~ s/\s+$//;

    return $error;
}

# One line per image for a preflight that reports as text: what needs it,
# and whether it was pulled, already there, failed, skipped or deferred.  The
# reason a deferred image could not be named follows it, since the caller
# cannot see the JSON record that carries it otherwise.
sub _report_images {
    my ($records) = @_;

    for my $record (@$records) {
        my $name = $record->{image};
        $name = $record->{expression} if !defined $name && defined $record->{expression};
        $name = '(unnamed)' unless defined $name && length $name;

        my $source = defined $record->{source} && length $record->{source}
            ? $record->{source}
            : 'the workflow';

        print "  image     $name ($source): $record->{status}\n";

        next unless $record->{status} eq 'deferred';
        next unless defined $record->{error} && length $record->{error};
        print "  deferred  $record->{error}\n";
    }

    return;
}

# The message a failed image preparation ends a run with: the image, what
# needed it, and what went wrong.
sub _image_failure_message {
    my ($failure) = @_;

    return "cannot prepare the image '$failure->{image}', needed by "
        . "$failure->{source}: $failure->{error}";
}

# Every image the run will use, in the order it needs them, as the expression
# that names it.  An expression the values available before the run cannot
# resolve is returned unresolved rather than as an empty name: the job checks
# its own images again once needs outputs are known, and reports anything it
# still cannot resolve before it starts.
sub _required_images {
    my ($self, $instances) = @_;

    my @entries;
    my %seen;

    for my $instance (@$instances) {
        my $runs_on = $self->{workflow}->runs_on_text(
            $instance->{'runs-on'}, $instance->{matrix} || {},
        );
        next unless $self->{workflow}->is_linux_runner($runs_on);

        my $context = $self->_preflight_context($instance);

        for my $entry ($self->_job_image_expressions($instance, $runs_on, $context)) {
            my $expression = $entry->{expression};
            next unless defined $expression && length $expression;

            my $image = eval {
                $self->{expression}->interpolate_strict($expression, $context);
            };
            my $error = _trim_error($@);

            if (defined $image && length $image) {
                next if $seen{"image\0$image"}++;
                push @entries, {
                    image  => $image,
                    source => $entry->{source},
                    kind   => $entry->{kind},
                };
                next;
            }

            next if $seen{"expression\0$expression\0$entry->{source}"}++;
            push @entries, {
                image      => undef,
                expression => $expression,
                source     => $entry->{source},
                error      => defined $error && length $error
                    ? $error
                    : 'the image name is empty',
            };
        }
    }

    return @entries;
}

# What one job needs, as expressions rather than resolved names, so that each
# caller can resolve them with the values it has: the preflight with what is
# known before the run, and the job itself with its full context.
sub _job_image_expressions {
    my ($self, $job, $runs_on, $context) = @_;

    my $name = defined $job->{display_name}
        ? $job->{display_name}
        : $job->{base_id};

    my @entries;

    my $job_image = eval {
        $self->{workflow}->container_image(
            $job, $runs_on,
            $self->{image} || 'ubuntu:latest',
            $self->{perl_image},
        );
    };
    push @entries, {
        expression => $job_image,
        source     => "job '$name'",
        kind       => 'job',
    } if defined $job_image && length $job_image;

    for my $id (sort keys %{ $job->{services} || {} }) {
        my $service = $job->{services}{$id};
        $service = { image => $service } unless ref $service eq 'HASH';
        next unless defined $service->{image} && length $service->{image};
        push @entries, {
            expression => $service->{image},
            source     => "service '$id' of job '$name'",
            kind       => "service:$id",
        };
    }

    my $add = sub {
        my ($expression, $source) = @_;
        push @entries, { expression => $expression, source => $source };
    };

    for my $step (@{ $job->{steps} || [] }) {
        $self->_collect_step_images($step, $name, $context, $add, {}, 0, undef);
    }

    return @entries;
}

# Walk one step's `uses`, handing the image expression to $add unresolved, so
# that the caller can decide when to resolve it.  Local composite actions are
# read here rather than when the step runs, so the images in their steps are
# known before the first container exists.
sub _collect_step_images {
    my ($self, $step, $job_name, $context, $add, $ancestors, $depth, $via) = @_;

    return unless defined $step->{uses};

    my $uses = $step->{uses};
    my $image;

    # What this context can resolve is resolved now: a composite action's
    # inputs, which are what usually decide the image.  An expression that
    # still needs a value only the job will have ("${{ steps.x.outputs.image }}")
    # is kept as written, so that the caller can recognise it as deferred
    # rather than mistake an empty string for an image name.
    my $resolve = sub {
        my ($text) = @_;

        my $value = eval { $self->{expression}->interpolate($text, $context) };
        return $text unless defined $value && length $value;
        return $value =~ /\{\{/ ? $text : $value;
    };

    if ($uses =~ m{^docker://(.*)$}s) {
        $image = $resolve->($1);
    }
    else {
        my $action = eval { $self->{expression}->interpolate($uses, $context) };
        return unless defined $action && length $action;

        if ($action =~ m{^docker://(.*)$}s) {
            $image = $resolve->($1);
        }
        elsif ($action =~ m{^\.\.?/}) {
            $self->_collect_action_images(
                $action, $step, $job_name, $context, $add, $ancestors, $depth,
            );
            return;
        }
        else {
            return;
        }
    }

    my $source = defined $via
        ? "action '$uses' in local action '$via' of job '$job_name'"
        : "action '$uses' in job '$job_name'";

    $add->($image, $source);

    return;
}

# Descend into a local composite action, with its inputs resolved as far as
# the caller's context allows.
sub _collect_action_images {
    my ($self, $action, $step, $job_name, $context, $add, $ancestors, $depth) = @_;

    # The run refuses to nest composite actions more than ten deep, so the
    # walk stops at the same point instead of descending forever.
    return if $depth >= 10;

    my $relative = eval { $self->_local_action_path($action) };
    return unless defined $relative;

    # An action may use itself, directly or through another one.
    return if $ancestors->{$relative};

    my $host_dir = File::Spec->catdir($self->{project_dir}, split m{/}, $relative);
    return unless -d $host_dir;

    my $loaded = eval { App::Actions::Action->load_from_dir($host_dir) };
    return unless $loaded && $loaded->is_composite;

    # Inputs usually decide the image ("uses: docker://${{ inputs.image }}").
    # A missing required input is the run's error to report, not the
    # preflight's, so it only leaves the image unresolved.
    my $inputs = eval { $self->_action_inputs($loaded, $step, $action, $context, undef) };
    $inputs = {} unless ref $inputs eq 'HASH';

    my %nested = %$context;
    $nested{inputs} = $inputs;
    $nested{steps}  = {};
    $nested{github} = {
        %{ $context->{github} || {} },
        action_path => "/github/workspace/$relative",
        action      => $action,
    };

    my %deeper = (%$ancestors, $relative => 1);
    for my $nested_step (@{ $loaded->steps || [] }) {
        $self->_collect_step_images(
            $nested_step, $job_name, \%nested, $add, \%deeper, $depth + 1, $action,
        );
    }

    return;
}

# The values known before the run.  github.* is resolved as the run will
# resolve it; needs.* is not, because those outputs belong to jobs that have
# not run yet, so the job checks its images again when they do.
sub _preflight_context {
    my ($self, $instance) = @_;

    return {
        matrix  => $instance->{matrix} || {},
        env     => { %{ $self->{env} || {} } },
        secrets => $self->{secrets} || {},
        vars    => {},
        inputs  => {},
        steps   => {},
        needs   => {},
        job     => { status => 'success' },
        github  => $self->_github_context($instance),
        strategy => {
            'job-index' => $instance->{matrix_index},
            'job-total' => $instance->{matrix_total},
        },
        runner  => $self->_runner_context,
    };
}

# Probe with the image the first runnable job will use: it costs no extra pull
# and it exercises the image the run actually needs.
sub _probe_image {
    my ($self, $instances) = @_;

    for my $instance (@$instances) {
        my $runs_on = $self->{workflow}->runs_on_text(
            $instance->{'runs-on'}, $instance->{matrix} || {},
        );
        next unless $self->{workflow}->is_linux_runner($runs_on);

        my $image = eval {
            $self->{workflow}->container_image(
                $instance, $runs_on,
                $self->{image} || 'ubuntu:latest',
                $self->{perl_image},
            );
        };
        next unless defined $image && length $image;

        # github.* and env.* are not resolved by container_image; the probe
        # needs a real image name, and the preflight context has those values.
        my $resolved = eval {
            $self->{expression}->interpolate_known(
                $image, $self->_preflight_context($instance),
            );
        };
        $image = $resolved if defined $resolved && length $resolved;
        next if $image =~ /\{\{/;

        return $image;
    }

    return $self->{image} || 'alpine:3.20';
}

# The Docker command to probe with; a caller may have supplied its own Docker
# object, which need not expose the binary name.
sub _docker_bin {
    my ($self) = @_;

    my $bin = eval { $self->{docker}->bin };

    return defined $bin && length $bin ? $bin : undef;
}

sub _select_jobs {
    my ($self, $instances) = @_;

    my @filters = @{ $self->{jobs} };
    my @selected;

    if (@filters) {
        my %matched;
        for my $filter (@filters) {
            my $found = 0;
            for my $index (0 .. $#$instances) {
                my $instance = $instances->[$index];
                next unless $instance->{base_id} eq $filter
                    || $instance->{display_name} eq $filter;
                $matched{$index} = 1;
                $found = 1;
            }
            croak "No job matched '$filter'" unless $found;
        }
        @selected = map { $instances->[$_] } sort { $a <=> $b } keys %matched;
    } else {
        @selected = @$instances;
    }

    my %groups;
    my @order;
    my %seen;
    for my $instance (@selected) {
        my $id = $instance->{base_id};
        push @{ $groups{$id} }, $instance;
        push @order, $id unless $seen{$id}++;
    }

    $self->{instances} = \@selected;
    $self->{job_groups} = \%groups;
    $self->{job_order} = \@order;

    return \@selected;
}

# Scripts and other files that the container reads must keep LF line endings.
# On Windows a text-mode handle would write CRLF, and bash rejects a script
# whose lines end in "\r" ("$'\r': command not found").
sub _write_container_file {
    my ($self, $path, $contents, $description) = @_;

    open my $handle, '>', $path
        or croak "Unable to write $description: $!";
    binmode $handle;
    print {$handle} $contents;
    close $handle
        or croak "Unable to write $description: $!";

    return;
}

sub _prepare_temp {
    my ($self) = @_;

    my $temp = File::Temp->newdir('app-actions-XXXXXX', TMPDIR => 1, CLEANUP => 0);
    $self->{tempdir} = $temp;
    $self->{temp_path} = "$temp";

    # The temp directory contains scripts and environment files, which may
    # contain secrets.  Keep it private unless the caller explicitly asked for
    # a different container user.
    my $directory_mode = defined $self->{user} ? 0777 : 0700;
    chmod $directory_mode, $self->{temp_path};

    for my $directory (qw(_temp _tool home scripts env output summary path event bin aptbin)) {
        my $path = "$self->{temp_path}/$directory";
        make_path($path);
        chmod $directory_mode, $path;
    }

    my $sudo = "$self->{temp_path}/bin/sudo";
    my $sudo_shim = <<'SH';
#!/bin/sh
# action-run sudo shim.  The job container is already running as root, so
# privilege escalation is unnecessary.  Ignore the common sudo options.
while [ "$#" -gt 0 ]; do
    case "$1" in
        -E|-H|-n) shift ;;
        -u) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done
exec "$@"
SH
    $self->_write_container_file($sudo, $sudo_shim, 'the sudo shim');
    chmod 0755, $sudo;

    $self->_install_apt_shims;

    return;
}

sub _install_apt_shims {
    my ($self) = @_;

    # GitHub-hosted runners configure apt with assume-yes, so unattended
    # installs work.  Without a terminal, apt aborts at its "Continue?"
    # prompt, which breaks any workflow that runs "apt install" under sudo.
    for my $name (qw(apt apt-get)) {
        my $path = "$self->{temp_path}/aptbin/$name";
        my $shim = <<"SH";
#!/bin/sh
# action-run $name shim: answer "yes" to mutating package commands so
# unattended installs behave like the GitHub-hosted runners.
subcommand=
assume_yes=
for arg in "\$@"; do
    case "\$arg" in
        --) break ;;
        -y|--yes|--assume-yes|-yq|-qy) assume_yes=1 ;;
        -*) ;;
        *) subcommand=\$arg; break ;;
    esac
done
case "\$subcommand" in
    install|remove|purge|upgrade|full-upgrade|dist-upgrade|autoremove|autoclean|build-dep)
        [ -n "\$assume_yes" ] || set -- "\$@" --yes
        ;;
esac
exec /usr/bin/$name "\$@"
SH
        $self->_write_container_file($path, $shim, "the $name shim");
        chmod 0755, $path;
    }

    return;
}

# The GitHub values a run derives from the checkout: branch, commit,
# repository and the run identifiers.  They are needed before any temporary
# directory exists, so that the preflight resolves github.* in an image name
# exactly the way the run will.
sub _repository_env {
    my ($self) = @_;

    return $self->{repository_env} if $self->{repository_env};

    my $project = $self->{project_dir};
    my $remote = _trim($self->_git('config', '--get', 'remote.origin.url'));
    my $repository;

    if ($remote =~ m{github\.com[:/]([^/]+)/(.+?)(?:\.git)?/?$}) {
        $repository = "$1/$2";
        $repository =~ s/\.git$//;
    }
    else {
        $repository = basename($project);
    }

    my $branch = _trim($self->_git('symbolic-ref', '--short', '-q', 'HEAD'));
    $branch = 'main' unless length $branch;

    my $sha = _trim($self->_git('rev-parse', 'HEAD'));
    $sha = '0' x 40 unless length $sha;

    my $actor = $ENV{GITHUB_ACTOR} || $ENV{USER} || 'local';
    my ($owner) = split m{/}, $repository, 2;
    $owner = $actor unless defined $owner && length $owner;

    return $self->{repository_env} = {
        GITHUB_ACTOR            => $actor,
        GITHUB_API_URL          => 'https://api.github.com',
        GITHUB_EVENT_NAME       => 'push',
        GITHUB_GRAPHQL_URL      => 'https://api.github.com/graphql',
        GITHUB_REF              => "refs/heads/$branch",
        GITHUB_REF_NAME         => $branch,
        GITHUB_REF_TYPE         => 'branch',
        GITHUB_REPOSITORY       => $repository,
        GITHUB_REPOSITORY_OWNER => $owner,
        GITHUB_RUN_ATTEMPT      => '1',
        GITHUB_RUN_ID           => sprintf('%d%05d', time, $$ % 100000),
        GITHUB_RUN_NUMBER       => '1',
        GITHUB_SERVER_URL       => 'https://github.com',
        GITHUB_SHA              => $sha,
    };
}

sub _build_base_env {
    my ($self) = @_;

    my $github = $self->_repository_env;

    my $event = {
        repository => {
            full_name => $github->{GITHUB_REPOSITORY},
            name      => (split m{/}, $github->{GITHUB_REPOSITORY})[-1],
            owner     => { login => $github->{GITHUB_REPOSITORY_OWNER} },
        },
        ref        => $github->{GITHUB_REF},
        after      => $github->{GITHUB_SHA},
        before     => '0' x 40,
        pusher     => { name => $github->{GITHUB_ACTOR} },
    };

    my $json = JSON::PP->new->canonical;
    my $event_path = "$self->{temp_path}/event.json";
    $self->_write_container_file($event_path, $json->encode($event), 'event.json');
    chmod(defined $self->{user} ? 0666 : 0600, $event_path);

    $self->{event} = $event;
    $self->{base_env} = {
        %$github,
        CI                    => 'true',
        DEBIAN_FRONTEND       => 'noninteractive',
        GITHUB_ACTIONS        => 'true',
        GITHUB_ACTION         => '',
        GITHUB_BASE_REF       => '',
        GITHUB_ENV            => '',
        GITHUB_EVENT_PATH     => '/github/actions-runner/event.json',
        GITHUB_HEAD_REF       => '',
        GITHUB_JOB            => '',
        GITHUB_OUTPUT         => '',
        GITHUB_PATH           => '',
        GITHUB_STATE          => '',
        GITHUB_STEP_SUMMARY   => '',
        GITHUB_TOKEN          => '',
        GITHUB_WORKFLOW       => $self->{workflow}->name,
        GITHUB_WORKSPACE      => '/github/workspace',
        HOME                  => defined $self->{user} ? '/github/actions-runner/home' : '/root',
        RUNNER_ARCH           => 'X64',
        RUNNER_NAME           => 'local',
        RUNNER_OS             => 'Linux',
        RUNNER_TEMP           => '/github/actions-runner/_temp',
        RUNNER_TOOL_CACHE     => '/github/actions-runner/_tool',
        RUNNER_WORKSPACE      => '/github',
    };

    if ($self->{verbose}) {
        $self->{base_env}{RUNNER_DEBUG} = '1';
        $self->{base_env}{ACTIONS_STEP_DEBUG} = 'true';
    }

    return;
}

sub _git {
    my ($self, @args) = @_;

    # Not fork() plus a piped open, which Windows does not reliably support.
    my ($output) = App::Actions::Process::capture(
        [ 'git', '-C', $self->{project_dir}, @args ],
        quiet_stderr => 1,
    );

    return defined $output ? $output : '';
}

sub _run_groups {
    my ($self) = @_;

    my %results;
    my %visited;
    my %running;

    for my $base_id (@{ $self->{job_order} }) {
        $self->_run_base_job($base_id, \%results, \%visited, \%running);
    }

    return \%results;
}

sub _run_base_job {
    my ($self, $base_id, $results, $visited, $running) = @_;

    return $results->{$base_id} if $visited->{$base_id};
    croak "Dependency cycle involving job '$base_id'" if $running->{$base_id};

    my $instances = $self->{job_groups}{$base_id};
    croak "Unknown job '$base_id'" unless $instances && @$instances;

    $running->{$base_id} = 1;

    my @needs = @{ $instances->[0]{needs} || [] };
    for my $need (@needs) {
        next unless exists $self->{job_groups}{$need};
        $self->_run_base_job($need, $results, $visited, $running);
    }

    my %need_results;
    for my $need (@needs) {
        if (exists $results->{$need}) {
            $need_results{$need} = $results->{$need};
        } else {
            print STDERR "action-run: job '$base_id' needs '$need', which was not selected; assuming it succeeded\n"
                unless $self->{quiet};
            $need_results{$need} = { result => 'success', outputs => {} };
        }
    }

    my $needs_failed = 0;
    for my $need (keys %need_results) {
        $needs_failed = 1 if $need_results{$need}{result} ne 'success';
    }

    my $fail_fast = 1;
    if (exists $instances->[0]{strategy}{'fail-fast'}) {
        $fail_fast = _truthy_scalar($instances->[0]{strategy}{'fail-fast'});
    }

    my $group_result = 'skipped';
    my $skipped_remaining = 0;

    for my $instance (@$instances) {
        my $matrix = $instance->{matrix} || {};
        my $display_name = $self->_redact($instance->{display_name});
        my $github = $self->_github_context($instance);
        my $strategy = {
            'fail-fast'   => $fail_fast,
            'job-index'   => $instance->{matrix_index},
            'job-total'   => $instance->{matrix_total},
            'max-parallel' => $instance->{strategy}{'max-parallel'},
        };
        my $context = {
            github   => $github,
            matrix   => $matrix,
            needs    => \%need_results,
            secrets  => $self->{secrets},
            vars     => {},
            inputs   => {},
            runner   => $self->_runner_context,
            strategy => $strategy,
            env      => {},
            job      => { status => $needs_failed ? 'failure' : 'success' },
            steps    => {},
        };
        my $status = {
            success   => $needs_failed ? 0 : 1,
            failure   => $needs_failed ? 1 : 0,
            cancelled => 0,
        };

        my $should_run;
        if (defined $instance->{if}) {
            my $condition = eval {
                $self->{expression}->condition($instance->{if}, $context, $status);
            };
            if ($@) {
                my $error = $@;
                $error =~ s/\s+$//;
                print STDERR "action-run: unable to evaluate if for '$display_name': $error\n"
                    unless $self->{quiet};
                $group_result = 'failure';
                $self->{workflow_failed} = 1;
                push @{ $self->{summary} }, {
                    name   => $instance->{display_name},
                    result => 'failure',
                };
                next;
            }
            $should_run = $condition;
            # An `if` without a status function gets an implicit success().
            $should_run = 0 if $should_run && $needs_failed
                && !_has_status_function($instance->{if});
        } else {
            $should_run = $needs_failed ? 0 : 1;
        }

        if (!$should_run) {
            print "==> Job: $display_name (skipped)\n"
                unless $self->{quiet};
            push @{ $self->{summary} }, {
                name   => $instance->{display_name},
                result => 'skipped',
            };
            next;
        }

        if ($skipped_remaining) {
            print "==> Job: $display_name (skipped by fail-fast)\n"
                unless $self->{quiet};
            push @{ $self->{summary} }, {
                name   => $instance->{display_name},
                result => 'skipped',
            };
            next;
        }

        $instance->{needs_results} = \%need_results;
        $instance->{context} = $context;

        my $result = $self->_run_instance($instance, $context);

        my $continue_on_error = 0;
        if (defined $instance->{'continue-on-error'}) {
            $continue_on_error = eval {
                $self->_boolean_value(
                    $instance->{'continue-on-error'},
                    $context,
                    { success => 1, failure => 0, cancelled => 0 },
                );
            };
            if ($@) {
                my $error = $@;
                $error =~ s/\s+$//;
                print STDERR "action-run: unable to evaluate continue-on-error for '$display_name': $error\n"
                    unless $self->{quiet};
            }
        }

        if ($result->{result} eq 'failure') {
            $group_result = 'failure';
            if ($continue_on_error) {
                print "!! Job failed but continue-on-error is set: $display_name\n"
                    unless $self->{quiet};
            } else {
                $self->{workflow_failed} = 1;
            }
            $skipped_remaining = 1 if $fail_fast;
        } elsif ($result->{result} eq 'success') {
            $group_result = 'success' if $group_result eq 'skipped';
        }

        push @{ $self->{summary} }, {
            name   => $instance->{display_name},
            result => $result->{result},
        };
    }

    my $entry = {
        result   => $group_result,
        outputs  => {},
        instances => $instances,
    };
    $results->{$base_id} = $entry;
    $visited->{$base_id} = 1;
    delete $running->{$base_id};

    return $entry;
}

sub _run_instance {
    my ($self, $job, $context) = @_;

    my $matrix = $job->{matrix} || {};
    my $display_name = $self->_redact($job->{display_name});
    my $runs_on = $self->{workflow}->runs_on_text($job->{'runs-on'}, $matrix);

    if (!$self->{workflow}->is_linux_runner($runs_on)) {
        print "==> Job: $display_name (skipped: runs-on '$runs_on' is not Linux)\n"
            unless $self->{quiet};
        return { result => 'skipped', reason => "unsupported runner: $runs_on" };
    }

    print "\n==> Job: $display_name\n" unless $self->{quiet};

    # The preflight could not name an image that comes from another job's
    # output; now that the job's values exist, the images are resolved and
    # prepared before its network or containers are, so a bad image stops the
    # run before the job starts rather than halfway through it.
    my ($image, $deferred) = $self->_prepare_job_images($job, $context);

    if (!defined $image || $image =~ /^\s*$/) {
        croak "Unable to determine a container image for job '$display_name'";
    }

    print "    image: $image\n" unless $self->{quiet};

    # A step output does not exist until the step has run, so the images built
    # from one are the only ones left; their step prepares them before it
    # starts its own container.
    for my $entry (@$deferred) {
        print "  deferred  $entry->{expression} ($entry->{source})\n"
            unless $self->{quiet};
    }

    my $network = $self->_resource_name('net', $job);
    my @containers;

    my $result;
    my $error;

    eval {
        my $rc = $self->{docker}->network_create($network);
        if ($rc != 0) {
            die "Failed to create Docker network '$network' (exit $rc)\n";
        }
        push @{ $self->{networks} }, $network;

        my @services;
        $self->_start_services($job, $network, $context, \@containers, \@services);

        my $job_env = $self->_resolve_env(
            [
                $self->{base_env},
                $self->{workflow}->env,
                $job->{env},
                (ref $job->{container} eq 'HASH' ? $job->{container}{env} : undef),
                $self->{env},
            ],
            $context,
        );

        $job_env->{GITHUB_JOB} = $job->{base_id};
        $job_env->{GITHUB_WORKSPACE} = '/github/workspace';

        my $container = $self->_start_job_container($job, $network, $job_env, $context, $image);
        push @containers, $container;
        push @{ $self->{containers} }, $container;

        my ($base_path, $has_bash, $has_node) = $self->_inspect_container($container);

        $result = $self->_execute_steps(
            $job, $container, $network, $base_path, $has_bash, $has_node, $job_env, $context,
        );

        # A service that has restarted during the run is not the one the steps
        # talked to, so the job fails as an infrastructure fault rather than
        # passing with a container that its restart policy kept alive.
        $self->_check_services(\@services);
    };
    $error = $@;

    $self->_cleanup_job($network, \@containers);

    die $error if $error;

    return $result || { result => 'failure', reason => 'job did not run' };
}

# In an explain run nothing is started, so the report is all the reader gets.
# One block per container says what it would be told to run, which is what a
# stopped service's diagnosis needs: a service has no command in the workflow,
# so its entrypoint and command are the image's own.
sub _explain_container {
    my ($self, %what) = @_;

    return unless $self->{explain};

    print "==> $what{title}\n";
    print "    container  $what{container}\n" if defined $what{container};
    print "    image      $what{image}\n";
    print "    entrypoint $what{entrypoint}\n";
    print "    command    $what{command}\n";

    return;
}

# A service's options can replace the image's entrypoint, which is part of
# what the container would be told to run.
sub _service_entrypoint {
    my ($self, $service, $context) = @_;

    return undef unless defined $service->{options};

    my $options = $self->{expression}->interpolate("$service->{options}", $context);
    my @tokens = shellwords($options);

    for my $index (0 .. $#tokens) {
        my $token = $tokens[$index];

        return $tokens[ $index + 1 ]
            if $token eq '--entrypoint' && defined $tokens[ $index + 1 ];
        return $1 if $token =~ /\A--entrypoint=(.*)\z/s;
    }

    return undef;
}

sub _start_services {
    my ($self, $job, $network, $context, $containers, $services_started) = @_;

    my $services = $job->{services} || {};
    return unless %$services;

    for my $id (sort keys %$services) {
        my $service = $services->{$id};
        $service = { image => $service } unless ref $service eq 'HASH';
        croak "Service '$id' must be a mapping" unless ref $service eq 'HASH';

        my $image = $service->{image};
        croak "Service '$id' has no image" unless defined $image && length $image;
        # Resolved and prepared by the job's own image check, before its
        # network existed.
        $image = $self->{expression}->interpolate($image, $context);

        my $name = $self->_resource_name('svc', $job, $id);
        my $service_env = $self->_resolve_env([$service->{env}], $context);

    my @args = ($self->_platform_args);

    if (defined $service->{options}) {
        my $options = $self->{expression}->interpolate("$service->{options}", $context);
        push @args, shellwords($options);
    }

    push @args, '--name', $name;
    push @args, '--network', $network;
    push @args, '--network-alias', $id;

    if (defined $self->{user}) {
        push @args, '--user', $self->{user};
    }

        for my $volume (@{ _as_array($service->{volumes}) }) {
            my $value = $self->{expression}->interpolate("$volume", $context);
            push @args, '-v', $value;
        }

        for my $key (sort keys %$service_env) {
            push @args, '-e', "$key=$service_env->{$key}";
        }

        for my $port (@{ _as_array($service->{ports}) }) {
            my $value = $self->{expression}->interpolate("$port", $context);
            push @args, '-p', $value;
        }

        if (defined $service->{credentials}) {
            print STDERR "action-run: service '$id' credentials are not supported; using the local Docker login\n"
                unless $self->{quiet};
        }

        push @args, $image;

        $self->_explain_container(
            title      => "Service '$id' of job '$job->{base_id}'",
            container  => $name,
            image      => $image,
            entrypoint => $self->_service_entrypoint($service, $context)
                || "(the image's own)",
            command    => "(the image's own)",
        );

        my $rc = $self->{docker}->container_start(@args);
        push @{ $self->{containers} }, $name;
        push @$containers, $name;

        if ($rc != 0) {
            die "Failed to start service '$id' (exit $rc)\n";
        }

        # Before asking whether it is running at all: a service whose restart
        # policy is bringing it back is reported as restarting, which is a
        # better account than "did not stay running" for a container Docker
        # considers up between attempts.
        $self->_check_services([ [ $id, $name ] ]);

        if (!$self->{docker}->container_running($name)) {
            die _stopped_message(
                "Service '$id'",
                $self->{docker}->container_exit_code($name),
                $self->{docker}->container_log_text($name),
            );
        }

        push @$services_started, [ $id, $name ] if $services_started;
    }

    return;
}

# A service that is restarting, or dead once its restart policy gave up, is not
# serving: Docker reports it as running between attempts, so asking only
# whether it is running passes a container that is backing off.  The restart
# count says how many attempts the policy has already made.
sub _check_services {
    my ($self, $services) = @_;

    for my $entry (@$services) {
        my ($id, $name) = @$entry;

        my $status   = $self->{docker}->container_status($name);
        my $restarts = $self->{docker}->container_restart_count($name);

        my $restarting = (defined $status && $status =~ /\A(?:restarting|dead)\z/)
            || (defined $restarts && $restarts > 0);

        next unless $restarting;

        die _restart_message(
            "Service '$id'",
            $status,
            $restarts,
            $self->{docker}->container_log_text($name),
        );
    }

    return;
}

# What a restarting service's failure looks like: the state the daemon reports,
# how many attempts the policy has made, and the last lines the container
# printed, which are what say whether the image or its command is at fault.
sub _restart_message {
    my ($what, $status, $restarts, $logs) = @_;

    my $message = "$what is "
        . (defined $status && $status eq 'dead' ? 'dead' : 'restarting');

    if (defined $restarts && $restarts > 0) {
        $message .= " (restart count $restarts)";
    }
    elsif (!defined $restarts) {
        $message .= ' (its restart count could not be read)';
    }

    my @lines = _log_lines($logs);
    return "$message; it printed nothing\n" unless @lines;

    return "$message; its last output was:\n"
        . join('', map { "  $_\n" } @lines);
}

# A container that was started and has stopped is reported with the status it
# left behind and the last lines it printed.  "Did not stay running" alone
# leaves the reader unable to tell a command that exited from an entrypoint
# that failed, and the container's own words are usually the answer.
sub _stopped_message {
    my ($what, $status, $logs) = @_;

    my $message = "$what did not stay running";
    $message .= defined $status
        ? " (exit $status)"
        : ' (its exit status could not be read)';

    my @lines = _log_lines($logs);
    return "$message; it printed nothing\n" unless @lines;

    return "$message; its last output was:\n"
        . join('', map { "  $_\n" } @lines);
}

# Container output as message lines: no CR from a Windows capture, no trailing
# blank lines, and nothing before the tail that docker was asked for.
sub _log_lines {
    my ($text) = @_;

    return () unless defined $text && length $text;

    my @lines = split /\n/, $text, -1;
    pop @lines while @lines && $lines[-1] =~ /\A\s*\z/;
    s/\r\z// for @lines;

    return @lines;
}

sub _start_job_container {
    my ($self, $job, $network, $job_env, $context, $image) = @_;

    my $container = $self->_resource_name('job', $job);

    my @args = ($self->_platform_args);

    if (ref $job->{container} eq 'HASH' && defined $job->{container}{options}) {
        my $options = $self->{expression}->interpolate(
            "$job->{container}{options}", $context,
        );
        push @args, shellwords($options);
    }

    push @args, '--name', $container;
    push @args, '--network', $network;
    push @args, '--hostname', _hostname($job->{base_id});

    if (defined $self->{user}) {
        push @args, '--user', $self->{user};
    }

    push @args, '-v', "$self->{project_dir}:/github/workspace";
    push @args, '-v', "$self->{temp_path}:/github/actions-runner";

    if (ref $job->{container} eq 'HASH') {
        for my $volume (@{ _as_array($job->{container}{volumes}) }) {
            my $value = $self->{expression}->interpolate("$volume", $context);
            push @args, '-v', $value;
        }
        for my $port (@{ _as_array($job->{container}{ports}) }) {
            my $value = $self->{expression}->interpolate("$port", $context);
            push @args, '-p', $value;
        }
    }

    push @args, '-w', '/github/workspace';

    for my $key (sort keys %$job_env) {
        push @args, '-e', "$key=$job_env->{$key}";
    }

    push @args, '--entrypoint', '/bin/sh';
    push @args, $image;
    push @args, '-c', 'while :; do sleep 3600; done';

    $self->_explain_container(
        title      => "Job '$job->{base_id}'",
        container  => $container,
        image      => $image,
        entrypoint => '/bin/sh',
        command    => "-c 'while :; do sleep 3600; done'",
    );

    my $rc = $self->{docker}->container_start(@args);
    if ($rc != 0) {
        $self->{docker}->container_remove($container);
        die "Failed to start the job container '$container' (exit $rc)\n";
    }

    if (!$self->{docker}->container_running($container)) {
        # Read what the container said before removing it: the same account
        # a service gets, because "did not stay running" alone leaves the
        # reader unable to tell a bad image from a bad entrypoint.
        my $message = _stopped_message(
            "Job container '$container'",
            $self->{docker}->container_exit_code($container),
            $self->{docker}->container_log_text($container),
        );
        $self->{docker}->container_remove($container);
        die $message;
    }

    return $container;
}

sub _inspect_container {
    my ($self, $container) = @_;

    my $default_path = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
    my ($path, $path_rc) = $self->{docker}->capture_silent(
        'exec', $container, 'sh', '-c', 'printf %s "$PATH"',
    );
    $path = $default_path if $path_rc != 0 || !defined $path || !length $path;

    $path = "/github/actions-runner/aptbin:$path";

    my (undef, $bash_rc) = $self->{docker}->capture_silent(
        'exec', $container, 'sh', '-c', 'command -v bash >/dev/null 2>&1',
    );

    my (undef, $node_rc) = $self->{docker}->capture_silent(
        'exec', $container, 'sh', '-c', 'command -v node >/dev/null 2>&1',
    );

    if (!defined $self->{user}) {
        my (undef, $sudo_rc) = $self->{docker}->capture_silent(
            'exec', $container, 'sh', '-c', 'command -v sudo >/dev/null 2>&1',
        );
        $path = "/github/actions-runner/bin:$path" if $sudo_rc != 0;
    }

    return ($path, $bash_rc == 0 ? 1 : 0, $node_rc == 0 ? 1 : 0);
}

sub _execute_steps {
    my ($self, $job, $container, $network, $base_path, $has_bash, $has_node, $job_env, $context) = @_;

    my %ctx = %$context;
    $ctx{env} = $job_env;
    $ctx{job} = { status => 'success' };

    my $state = {
        job            => $job,
        container      => $container,
        network        => $network,
        base_path      => $base_path,
        has_bash       => $has_bash,
        has_node       => $has_node,
        job_env        => $job_env,
        path_additions => [],
        ctx            => \%ctx,
        counter        => { value => 0 },
        post_actions   => [],
        depth          => 0,
        failed         => 0,
    };

    for my $step (@{ $job->{steps} }) {
        $self->_execute_step($state, $step);
    }

    $self->_run_post_actions($state);

    return {
        result => $state->{failed} ? 'failure' : 'success',
        env    => $job_env,
    };
}

# Run one step in the given scope.  A scope holds the container, the job-level
# environment, the expression context, and the accumulated PATH additions, so
# that composite action steps can reuse the same machinery as workflow steps.
sub _execute_step {
    my ($self, $state, $step) = @_;

    my $ctx = $state->{ctx};
    my $job_env = $state->{job_env};
    my $prefix = '  ' x ($state->{depth} || 0);

    my $step_number = ++$state->{counter}{value};
    my $step_id = $step->{id};
    my $internal_id = defined $step_id ? $step_id : "__step_$step_number";

    my $step_env = eval {
        $self->_resolve_env([$job_env, $step->{env}], $ctx);
    };
    if ($@) {
        my $error = $@;
        $error =~ s/\s+$//;
        print STDERR "action-run: unable to evaluate environment for step '$internal_id': $error\n"
            unless $self->{quiet};
        $state->{failed} = 1;
        $ctx->{job}{status} = 'failure';
        if (defined $step_id) {
            $ctx->{steps}{$step_id} = {
                outputs    => {},
                outcome    => 'failure',
                conclusion => 'failure',
            };
        }
        return 'failure';
    }

    my $status = {
        success   => $state->{failed} ? 0 : 1,
        failure   => $state->{failed} ? 1 : 0,
        cancelled => 0,
    };

    my %condition_context = (%$ctx, env => $step_env);
    my $should_run = 1;

    if (defined $step->{if}) {
        my $condition = eval {
            $self->{expression}->condition($step->{if}, \%condition_context, $status);
        };
        if ($@) {
            my $error = $@;
            $error =~ s/\s+$//;
            print STDERR "action-run: unable to evaluate if for step '$internal_id': $error\n"
                unless $self->{quiet};
            $state->{failed} = 1;
            $ctx->{job}{status} = 'failure';
            return 'failure';
        }
        $should_run = $condition;
        # An `if` without a status function gets an implicit success().
        $should_run = 0 if $should_run && $state->{failed}
            && !_has_status_function($step->{if});
    } else {
        $should_run = $state->{failed} ? 0 : 1;
    }

    my $step_name = $self->_redact($self->_step_name($step, $step_number, \%condition_context));

    if (!$should_run) {
        print "${prefix}--- Step: $step_name (skipped)\n" unless $self->{quiet};
        if (defined $step_id) {
            $ctx->{steps}{$step_id} = {
                outputs    => {},
                outcome    => 'skipped',
                conclusion => 'skipped',
            };
        }
        return 'skipped';
    }

    print "${prefix}--- Step: $step_name\n" unless $self->{quiet};

    my $result;
    my $step_error;

    eval {
        if (defined $step->{run}) {
            $result = $self->_run_script_step(
                $state, $step, $step_number,
                $step_env, \%condition_context, $status,
            );
        } else {
            $result = $self->_run_uses_step(
                $state, $step, $step_number,
                $step_env, \%condition_context, $status,
            );
        }
    };
    if ($@) {
        $step_error = $@;
        $step_error =~ s/\s+$//;
        print STDERR "action-run: $step_error\n" unless $self->{quiet};
        $result = { outcome => 'failure', error => $step_error };
    }

    my $continue_on_error = 0;
    if (defined $step->{'continue-on-error'}) {
        $continue_on_error = eval {
            $self->_boolean_value($step->{'continue-on-error'}, \%condition_context, $status);
        };
        if ($@) {
            my $error = $@;
            $error =~ s/\s+$//;
            print STDERR "action-run: unable to evaluate continue-on-error: $error\n"
                unless $self->{quiet};
        }
    }

    my $outcome = $result->{outcome} || 'success';
    my $conclusion = $outcome;

    if ($outcome eq 'failure') {
        if ($continue_on_error) {
            $conclusion = 'success';
            print "${prefix}!! Step failed but continue-on-error is set\n"
                unless $self->{quiet};
        } else {
            $conclusion = 'failure';
            $state->{failed} = 1;
            my $message = $result->{error} || 'step failed';
            print STDERR "!! $message\n" unless $self->{quiet};
        }
    }

    if ($result->{env}) {
        for my $key (keys %{ $result->{env} }) {
            $job_env->{$key} = $result->{env}{$key};
        }
    }

    if ($result->{path} && @{ $result->{path} }) {
        unshift @{ $state->{path_additions} }, @{ $result->{path} };
    }

    $ctx->{env} = $job_env;
    $ctx->{job}{status} = $state->{failed} ? 'failure' : 'success';

    if (defined $step_id) {
        $ctx->{steps}{$step_id} = {
            outputs    => $result->{outputs} || {},
            outcome    => $outcome,
            conclusion => $conclusion,
        };
    }

    if (defined $result->{summary} && $result->{summary} =~ /\S/) {
        print "${prefix}--- Step summary ---\n$result->{summary}\n" unless $self->{quiet};
    }

    return $outcome;
}

# JavaScript actions can defer a post step until the job finishes.  Posts run
# in reverse order, as they do on GitHub.
sub _run_post_actions {
    my ($self, $state) = @_;

    my $post_actions = $state->{post_actions} || [];
    return unless @$post_actions;

    my $ctx = $state->{ctx};
    my $status = {
        success   => $state->{failed} ? 0 : 1,
        failure   => $state->{failed} ? 1 : 0,
        cancelled => 0,
    };

    for my $post (reverse @$post_actions) {
        my %post_ctx = (%$ctx, inputs => $post->{inputs}, env => $state->{job_env});
        $post_ctx{github} = {
            %{ $ctx->{github} || {} },
            action_path => $post->{action_path},
        };

        my $should_run = eval {
            $self->{expression}->condition($post->{condition}, \%post_ctx, $status);
        };
        if ($@) {
            my $error = $@;
            $error =~ s/\s+$//;
            print STDERR "action-run: unable to evaluate the post condition for '$post->{uses}': $error\n"
                unless $self->{quiet};
            next;
        }
        next unless $should_run;

        print "--- Step: Post $post->{uses}\n" unless $self->{quiet};

        my $rc = eval {
            my $files = $self->_prepare_step_files((++$state->{counter}{value}) . '-post');
            my %post_env = (%{ $state->{job_env} }, %{ $files->{vars} });
            for my $key (keys %{ $post->{state} || {} }) {
                $post_env{"STATE_$key"} = $post->{state}{$key};
            }
            $self->_run_node_script(
                $state, $post->{script}, \%post_env,
                $post->{step_id}, $post->{action_path}, $post->{inputs},
            );
        };

        if ($@) {
            my $error = $@;
            $error =~ s/\s+$//;
            print STDERR "action-run: post step for '$post->{uses}' failed: $error\n"
                unless $self->{quiet};
            $state->{failed} = 1;
            $status = { success => 0, failure => 1, cancelled => 0 };
            next;
        }

        if ($rc != 0) {
            print STDERR "!! post step for '$post->{uses}' exited with status $rc\n"
                unless $self->{quiet};
            $state->{failed} = 1;
            $status = { success => 0, failure => 1, cancelled => 0 };
        }
    }

    return;
}

sub _run_script_step {
    my ($self, $state, $step, $step_number, $env, $context, $status) = @_;

    my $job = $state->{job};
    my $has_bash = $state->{has_bash};
    my $base_path = $state->{base_path};
    my $path_additions = $state->{path_additions};
    my $container = $state->{container};

    my $shell = $self->_shell_for($step, $job, $context, $status, $has_bash);

    if ($shell->{requires_bash} && !$has_bash) {
        return {
            outcome => 'failure',
            error   => "Shell '$shell->{name}' is not available in the container",
        };
    }

    my @path = @$path_additions;
    my $script = $self->{expression}->interpolate($step->{run}, $context, $status);
    $script .= "\n" unless $script =~ /\n\z/;

    my $files = $self->_prepare_step_files($step_number);
    my %exec_env = (%$env, %{ $files->{vars} });

    my $path_base = defined $exec_env{PATH} ? $exec_env{PATH} : $base_path;
    $exec_env{PATH} = join(':', @path, $path_base);

    my $workdir = $self->_working_directory($step, $job, $context, $status);
    my $script_name = "step-$step_number$shell->{extension}";
    my $host_script = "$self->{temp_path}/scripts/$script_name";
    my $container_script = "/github/actions-runner/scripts/$script_name";

    $self->_write_container_file(
        $host_script, $script, "the step script '$host_script'",
    );
    chmod(defined $self->{user} ? 0666 : 0600, $host_script);

    my $command = $shell->{command};
    my $quoted_script = _shell_quote($container_script);
    if ($command =~ /\{0\}/) {
        $command =~ s/\{0\}/$quoted_script/g;
    } else {
        $command .= " $quoted_script";
    }

    $exec_env{GITHUB_ACTION} = defined $step->{id} ? $step->{id} : "__step_$step_number";
    $exec_env{GITHUB_ACTION_PATH} = defined $context->{github}{action_path}
        ? $context->{github}{action_path} : '';

    if ($self->{dry_run} && $self->{verbose}) {
        my $display_script = $self->_redact($script);
        print "--- script ---\n$display_script--- end script ---\n";
    }

    my @args = ('-w', $workdir);
    for my $key (sort keys %exec_env) {
        push @args, '-e', "$key=$exec_env{$key}";
    }
    push @args, $container, 'sh', '-c', $command;

    my $rc = $self->{docker}->container_exec(@args);

    my ($env_updates, $outputs, $paths, $summary) = $self->_collect_step_files($files, 0);

    return {
        outcome  => $rc == 0 ? 'success' : 'failure',
        exit_code => $rc,
        env      => $env_updates,
        outputs  => $outputs,
        path     => $paths,
        summary  => $summary,
        error    => $rc == 0 ? undef : "step exited with status $rc",
    };
}

sub _run_uses_step {
    my ($self, $state, $step, $step_number, $env, $context, $status) = @_;

    my $uses = $step->{uses};
    my $action = $self->{expression}->interpolate($uses, $context, $status);

    if ($action =~ m{^actions/checkout@}i) {
        if (defined $step->{with}{path} && length $step->{with}{path}) {
            print STDERR "action-run: actions/checkout 'path' is ignored; the repository is mounted at /github/workspace\n"
                unless $self->{quiet};
        }
        if (defined $step->{with}{submodules} && $step->{with}{submodules} ne 'false') {
            print STDERR "action-run: actions/checkout submodules are not fetched; using the checkout as-is\n"
                unless $self->{quiet};
        }
        if (defined $step->{with}{ref} || defined $step->{with}{repository}) {
            print STDERR "action-run: actions/checkout ref/repository is ignored; using the local checkout\n"
                unless $self->{quiet};
        }
        return $self->_noop_result('repository already mounted at /github/workspace');
    }

    if ($action =~ m{^(?:shogo82148/actions-setup-perl|perl-actions/setup-perl)@}i) {
        my $version = $step->{with}{'perl-version'};
        if (defined $version) {
            $version = $self->{expression}->interpolate($version, $context, $status);
        }
        return $self->_noop_result(
            'using container image for Perl' . (defined $version ? " $version" : ''),
        );
    }

    if ($action =~ m{^(?:actions/cache(?:/restore|/save)?|actions/upload-artifact|actions/download-artifact|codecov/codecov-action)@}i) {
        return $self->_noop_result('caching, artifacts, and coverage uploads are not implemented');
    }

    if ($action =~ m{^docker://(.+)$}) {
        return $self->_run_docker_action(
            $state, $step, $step_number, $1,
            $env, $context, $status,
        );
    }

    if ($action =~ m{^\.\.?/}) {
        return $self->_run_local_action(
            $state, $step, $step_number, $action, $env, $context, $status,
        );
    }

    return $self->_unsupported_action($action, 'remote JavaScript and composite actions are not supported');
}

sub _run_docker_action {
    my ($self, $state, $step, $step_number, $image, $env, $context, $status) = @_;

    my $job = $state->{job};
    my $network = $state->{network};
    my $base_path = $state->{base_path};
    my $path_additions = $state->{path_additions};

    $image = $self->{expression}->interpolate($image, $context, $status);

    # The job resolved this image before it started unless a step output
    # decides it, in which case this is the first moment it is known.  Either
    # way it must be a real name before the container is started.
    if (!length $image || $image =~ /\{\{/) {
        my $why = length $image
            ? "resolved to '$image', which is not an image name"
            : 'has no image name';
        croak "Docker action '$step->{uses}' in job '$job->{base_id}' $why; "
            . 'check the expression it uses\n';
    }

    $self->_ensure_image($image);

    my $files = $self->_prepare_step_files($step_number);
    my %exec_env = (%$env, %{ $files->{vars} });

    my $path_base = defined $exec_env{PATH} ? $exec_env{PATH} : $base_path;
    $exec_env{PATH} = join(':', @$path_additions, $path_base);

    $exec_env{GITHUB_ACTION} = defined $step->{id} ? $step->{id} : "__step_$step_number";
    $exec_env{GITHUB_ACTION_PATH} = defined $context->{github}{action_path}
        ? $context->{github}{action_path} : '';

    my $workdir = $self->_working_directory($step, $job, $context, $status);

    my @args = ('run', '--rm');
    push @args, $self->_platform_args;
    push @args, '--network', $network;
    push @args, '-v', "$self->{project_dir}:/github/workspace";
    push @args, '-v', "$self->{temp_path}:/github/actions-runner";
    push @args, '-w', $workdir;

    if (defined $self->{user}) {
        push @args, '--user', $self->{user};
    }

    my $entrypoint;
    if (defined $step->{with}{entrypoint}) {
        $entrypoint = $self->{expression}->interpolate(
            "$step->{with}{entrypoint}", $context, $status,
        );
        push @args, '--entrypoint', $entrypoint;
    }

    for my $key (sort keys %exec_env) {
        push @args, '-e', "$key=$exec_env{$key}";
    }

    push @args, $image;

    my @arguments;
    if (defined $step->{with}{args}) {
        my $arguments = $self->{expression}->interpolate(
            "$step->{with}{args}", $context, $status,
        );
        @arguments = shellwords($arguments);
        push @args, @arguments;
    }

    $self->_explain_container(
        title      => "Action '$step->{uses}' in job '$job->{base_id}'",
        image      => $image,
        entrypoint => defined $entrypoint ? $entrypoint : "(the image's own)",
        command    => @arguments ? join(' ', @arguments) : "(the image's own)",
    );

    my $rc = $self->{docker}->run(@args);

    my ($env_updates, $outputs, $paths, $summary) = $self->_collect_step_files($files, 0);

    return {
        outcome   => $rc == 0 ? 'success' : 'failure',
        exit_code => $rc,
        env       => $env_updates,
        outputs   => $outputs,
        path      => $paths,
        summary   => $summary,
        error     => $rc == 0 ? undef : "docker action exited with status $rc",
    };
}

# Run an action that lives inside the project, e.g. "uses: ./.github/actions/test".
sub _run_local_action {
    my ($self, $state, $step, $step_number, $uses, $env, $context, $status) = @_;

    my $relative = $self->_local_action_path($uses);

    my $host_dir = File::Spec->catdir($self->{project_dir}, split m{/}, $relative);
    croak "Local action '$uses' does not exist (looked in $host_dir)"
        unless -d $host_dir;

    my $action = eval { App::Actions::Action->load_from_dir($host_dir) };
    if ($@) {
        my $error = $@;
        $error =~ s/\s+$//;
        croak $error;
    }

    my $container_path = "/github/workspace/$relative";
    my $inputs = $self->_action_inputs($action, $step, $uses, $context, $status);

    if ($action->is_composite) {
        return $self->_run_composite_action(
            $state, $action, $step, $step_number, $container_path,
            $inputs, $env, $context, $status,
        );
    }

    if ($action->is_javascript) {
        return $self->_run_javascript_action(
            $state, $action, $step, $step_number, $container_path,
            $inputs, $env, $context, $status,
        );
    }

    return $self->_unsupported_action(
        $uses,
        "local actions that use '$action->{using}' are not supported",
    );
}

# Resolve "./path/to/action" to a path relative to the project, or explain why
# it cannot be used.  Both the run and the preflight resolve references the
# same way, so an action is read from one place whichever finds it first.
sub _local_action_path {
    my ($self, $uses) = @_;

    my $relative = $uses;
    $relative =~ s{^\./}{};
    $relative =~ s{^/+}{};
    $relative =~ s{/+$}{};

    croak "Local action '$uses' does not name a directory inside the project"
        unless length $relative;
    croak "Local action '$uses' must not escape the project directory"
        if $relative =~ m{(?:^|/)\.\.(?:/|$)};

    return $relative;
}

# Resolve the action's inputs from defaults and the calling step's `with`.
sub _action_inputs {
    my ($self, $action, $step, $uses, $context, $status) = @_;

    my $declared = $action->inputs || {};
    my $with = ref $step->{with} eq 'HASH' ? $step->{with} : {};

    my %inputs;
    for my $name (keys %$declared) {
        my $default = $declared->{$name}{default};
        $inputs{$name} = defined $default && length $default
            ? $self->{expression}->interpolate($default, $context, $status)
            : '';
    }

    for my $name (keys %$with) {
        my $value = $with->{$name};
        $value = $self->{expression}->interpolate(_stringify($value), $context, $status)
            unless ref $value;
        $inputs{$name} = _stringify($value);
    }

    for my $name (sort keys %$declared) {
        next unless $declared->{$name}{required};
        next if defined $inputs{$name} && length $inputs{$name};
        croak "Action '$uses' requires the input '$name'";
    }

    return \%inputs;
}

sub _run_composite_action {
    my ($self, $state, $action, $step, $step_number, $container_path, $inputs, $env, $context, $status) = @_;

    my $uses = $step->{uses};
    my $depth = $state->{depth} || 0;
    croak "Composite action '$uses' is nested more than 10 levels deep" if $depth >= 10;

    my %nested_ctx = %$context;
    $nested_ctx{inputs} = $inputs;
    $nested_ctx{steps} = {};
    $nested_ctx{job} = { status => $state->{failed} ? 'failure' : 'success' };
    $nested_ctx{github} = {
        %{ $context->{github} || {} },
        action_path => $container_path,
        action      => $uses,
    };

    my $nested = {
        %$state,
        ctx     => \%nested_ctx,
        job_env => { %$env },
        depth   => $depth + 1,
        failed  => 0,
    };

    for my $nested_step (@{ $action->steps }) {
        $self->_execute_step($nested, $nested_step);
    }

    my %outputs;
    my $declared = $action->outputs || {};
    my %output_ctx = (%nested_ctx, env => $nested->{job_env});
    for my $name (keys %$declared) {
        my $value = $declared->{$name}{value};
        $outputs{$name} = $self->{expression}->interpolate($value, \%output_ctx);
    }

    # Variables exported inside the action belong to the caller's job env.
    for my $key (keys %{ $nested->{job_env} }) {
        next if exists $env->{$key} && "$env->{$key}" eq "$nested->{job_env}{$key}";
        $state->{job_env}{$key} = $nested->{job_env}{$key};
    }

    return {
        outcome   => $nested->{failed} ? 'failure' : 'success',
        env       => {},
        outputs   => \%outputs,
        path      => [],
        summary   => '',
        error     => $nested->{failed} ? "composite action '$uses' failed" : undef,
    };
}

sub _run_javascript_action {
    my ($self, $state, $action, $step, $step_number, $container_path, $inputs, $env, $context, $status) = @_;

    my $runs = $action->runs;
    my $uses = $step->{uses};

    croak "JavaScript action '$uses' needs Node.js, but 'node' was not found in the job container"
        unless $state->{has_node};

    my $step_id = defined $step->{id} ? $step->{id} : "__step_$step_number";

    my %state_values;
    my %all_env;
    my %all_outputs;
    my @all_paths;
    my $summary = '';

    my $pre = $runs->{pre};
    if (defined $pre && length "$pre") {
        my $condition = defined $runs->{'pre-if'} ? $runs->{'pre-if'} : 'always()';
        my $should_run = eval {
            $self->{expression}->condition($condition, $context, $status);
        };
        if ($@) {
            my $error = $@;
            $error =~ s/\s+$//;
            print STDERR "action-run: unable to evaluate pre-if for '$uses': $error\n"
                unless $self->{quiet};
            $should_run = 0;
        }

        if ($should_run) {
            my $files = $self->_prepare_step_files("$step_number-pre");
            my %pre_env = (%$env, %{ $files->{vars} });
            my $rc = $self->_run_node_script(
                $state, "$container_path/$pre", \%pre_env, $step_id, $container_path, $inputs,
            );
            my ($env_updates, $outputs, $paths, $pre_summary, $saved)
                = $self->_collect_step_files($files, 1);

            %all_env     = (%all_env, %$env_updates);
            %all_outputs = (%all_outputs, %$outputs);
            push @all_paths, @$paths;
            $summary .= $pre_summary if length $pre_summary;
            $state_values{$_} = $saved->{$_} for keys %$saved;

            if ($rc != 0) {
                return {
                    outcome   => 'failure',
                    exit_code => $rc,
                    env       => \%all_env,
                    outputs   => \%all_outputs,
                    path      => \@all_paths,
                    summary   => $summary,
                    error     => "pre step of JavaScript action '$uses' exited with status $rc",
                };
            }
        }
    }

    my $files = $self->_prepare_step_files($step_number);
    my %exec_env = (%$env, %{ $files->{vars} });
    for my $key (keys %state_values) {
        $exec_env{"STATE_$key"} = $state_values{$key};
    }

    my $rc = $self->_run_node_script(
        $state, "$container_path/$runs->{main}", \%exec_env, $step_id, $container_path, $inputs,
    );

    my ($env_updates, $outputs, $paths, $step_summary, $saved)
        = $self->_collect_step_files($files, 1);

    %all_env     = (%all_env, %$env_updates);
    %all_outputs = (%all_outputs, %$outputs);
    push @all_paths, @$paths;
    $summary .= $step_summary if length $step_summary;
    $state_values{$_} = $saved->{$_} for keys %$saved;

    my $post = $runs->{post};
    if (defined $post && length "$post") {
        push @{ $state->{post_actions} }, {
            uses        => $uses,
            script      => "$container_path/$post",
            condition   => defined $runs->{'post-if'} ? $runs->{'post-if'} : 'always()',
            inputs      => $inputs,
            action_path => $container_path,
            step_id     => $step_id,
            state       => { %state_values },
        };
    }

    return {
        outcome   => $rc == 0 ? 'success' : 'failure',
        exit_code => $rc,
        env       => \%all_env,
        outputs   => \%all_outputs,
        path      => \@all_paths,
        summary   => $summary,
        error     => $rc == 0 ? undef : "JavaScript action '$uses' exited with status $rc",
    };
}

# Execute a JavaScript action entry point with the job environment, its inputs
# as INPUT_* variables, and GITHUB_ACTION_PATH pointing at the action.
sub _run_node_script {
    my ($self, $state, $script, $env, $step_id, $action_path, $inputs) = @_;

    my %exec_env = %$env;
    my $path_base = defined $exec_env{PATH} ? $exec_env{PATH} : $state->{base_path};
    $exec_env{PATH} = join(':', @{ $state->{path_additions} }, $path_base);

    $exec_env{GITHUB_ACTION} = $step_id;
    $exec_env{GITHUB_ACTION_PATH} = $action_path;

    for my $name (sort keys %$inputs) {
        (my $key = uc $name) =~ s/[^A-Z0-9_]/_/g;
        $exec_env{"INPUT_$key"} = $inputs->{$name};
    }

    my @args = ('-w', '/github/workspace');
    for my $key (sort keys %exec_env) {
        push @args, '-e', "$key=$exec_env{$key}";
    }
    push @args, $state->{container}, 'node', $script;

    return $self->{docker}->container_exec(@args);
}

sub _noop_result {
    my ($self, $message) = @_;

    print "    ($message)\n" unless $self->{quiet};

    return {
        outcome => 'success',
        env     => {},
        outputs => {},
        path    => [],
        summary => '',
    };
}

sub _unsupported_action {
    my ($self, $action, $reason) = @_;

    my $message = "action '$action' skipped: $reason";
    if ($self->{strict_actions}) {
        print STDERR "action-run: $message\n" unless $self->{quiet};
        return {
            outcome => 'failure',
            env     => {},
            outputs => {},
            path    => [],
            summary => '',
            error   => $message,
        };
    }

    print STDERR "action-run: $message\n" unless $self->{quiet};
    print "    (skipped: $reason)\n" unless $self->{quiet};

    return {
        outcome => 'skipped',
        env     => {},
        outputs => {},
        path    => [],
        summary => '',
    };
}

sub _shell_for {
    my ($self, $step, $job, $context, $status, $has_bash) = @_;

    my $shell = $step->{shell};
    $shell = $job->{defaults}{run}{shell} unless defined $shell;
    $shell = $self->{workflow}->defaults->{run}{shell} unless defined $shell;

    if (!defined $shell) {
        return {
            name          => 'bash',
            command       => 'bash -e {0}',
            extension     => '.sh',
            requires_bash => 1,
        } if $self->{dry_run} || $has_bash;

        return {
            name          => 'sh',
            command       => 'sh -e {0}',
            extension     => '.sh',
            requires_bash => 0,
        };
    }

    $shell = $self->{expression}->interpolate("$shell", $context, $status);
    my $lower = lc $shell;
    $lower =~ s/^\s+|\s+$//g;

    my %known = (
        bash => {
            name          => 'bash',
            command       => 'bash --noprofile --norc -eo pipefail {0}',
            extension     => '.sh',
            requires_bash => 1,
        },
        sh => {
            name          => 'sh',
            command       => 'sh -e {0}',
            extension     => '.sh',
            requires_bash => 0,
        },
        perl => {
            name          => 'perl',
            command       => 'perl {0}',
            extension     => '.pl',
            requires_bash => 0,
        },
        python => {
            name          => 'python',
            command       => 'python {0}',
            extension     => '.py',
            requires_bash => 0,
        },
        pwsh => {
            name          => 'pwsh',
            command       => 'pwsh -File {0}',
            extension     => '.ps1',
            requires_bash => 0,
        },
        powershell => {
            name          => 'powershell',
            command       => 'powershell -File {0}',
            extension     => '.ps1',
            requires_bash => 0,
        },
    );

    return $known{$lower} if exists $known{$lower};

    return {
        name          => 'custom',
        command       => $shell =~ /\{0\}/ ? $shell : "$shell {0}",
        extension     => '.sh',
        requires_bash => 0,
    };
}

sub _working_directory {
    my ($self, $step, $job, $context, $status) = @_;

    my $workdir = $step->{'working-directory'};
    $workdir = $job->{defaults}{run}{'working-directory'} unless defined $workdir;
    $workdir = $self->{workflow}->defaults->{run}{'working-directory'} unless defined $workdir;
    $workdir = '/github/workspace' unless defined $workdir && length $workdir;

    $workdir = $self->{expression}->interpolate("$workdir", $context, $status);
    $workdir = '/github/workspace' unless length $workdir;
    $workdir = "/github/workspace/$workdir" unless $workdir =~ m{^/};

    return $workdir;
}

sub _step_name {
    my ($self, $step, $number, $context) = @_;

    my $name = $step->{name};
    $name = $step->{uses} if !defined $name && defined $step->{uses};
    if (!defined $name && defined $step->{run}) {
        $name = $step->{run};
        $name =~ s/\s+/ /g;
        $name =~ s/^\s+|\s+$//g;
        $name = substr($name, 0, 77) . '...' if length $name > 80;
    }
    $name = "Step $number" unless defined $name && length $name;

    my $value = eval {
        $self->{expression}->interpolate($name, $context);
    };
    return $@ ? $name : $value;
}

sub _prepare_step_files {
    my ($self, $step_number) = @_;

    my $prefix = "step-$step_number";
    my %host = (
        env     => "$self->{temp_path}/env/$prefix.env",
        output  => "$self->{temp_path}/output/$prefix.out",
        path    => "$self->{temp_path}/path/$prefix.path",
        summary => "$self->{temp_path}/summary/$prefix.md",
        state   => "$self->{temp_path}/env/$prefix.state",
    );
    my %vars = (
        GITHUB_ENV          => "/github/actions-runner/env/$prefix.env",
        GITHUB_OUTPUT       => "/github/actions-runner/output/$prefix.out",
        GITHUB_PATH         => "/github/actions-runner/path/$prefix.path",
        GITHUB_STEP_SUMMARY => "/github/actions-runner/summary/$prefix.md",
        GITHUB_STATE        => "/github/actions-runner/env/$prefix.state",
    );

    for my $key (keys %host) {
        open my $handle, '>', $host{$key}
            or croak "Unable to create step file '$host{$key}': $!";
        close $handle;
        chmod(defined $self->{user} ? 0666 : 0600, $host{$key});
    }

    return { host => \%host, vars => \%vars };
}

sub _collect_step_files {
    my ($self, $files, $keep_state) = @_;

    my $env     = $self->_parse_kv_file($files->{host}{env});
    my $outputs = $self->_parse_kv_file($files->{host}{output});
    my $paths   = $self->_read_lines($files->{host}{path});
    my $summary = $self->_read_file($files->{host}{summary});
    my $state   = $keep_state
        ? $self->_parse_kv_file($files->{host}{state})
        : {};

    my %remove = %{ $files->{host} };
    delete $remove{state} if $keep_state;
    unlink grep { defined && -e $_ } values %remove;

    return ($env, $outputs, $paths, $summary, $state);
}

sub _parse_kv_file {
    my ($self, $path) = @_;

    my %values;
    return \%values unless defined $path && -f $path;

    open my $handle, '<', $path or return \%values;

    while (defined(my $line = <$handle>)) {
        $line =~ s/\r?\n$//;
        next if $line eq '';

        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s) {
            $values{$1} = $2;
            next;
        }

        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)<<(\S+)$/) {
            my ($name, $delimiter) = ($1, $2);
            my @lines;
            while (defined(my $body = <$handle>)) {
                $body =~ s/\r?\n$//;
                last if $body eq $delimiter;
                push @lines, $body;
            }
            $values{$name} = join("\n", @lines);
        }
    }

    close $handle;

    return \%values;
}

sub _read_lines {
    my ($self, $path) = @_;

    my @lines;
    return \@lines unless defined $path && -f $path;

    open my $handle, '<', $path or return \@lines;
    while (defined(my $line = <$handle>)) {
        $line =~ s/\r?\n$//;
        $line =~ s/^\s+|\s+$//g;
        push @lines, $line if length $line;
    }
    close $handle;

    return \@lines;
}

sub _read_file {
    my ($self, $path) = @_;

    return '' unless defined $path && -f $path;

    open my $handle, '<', $path or return '';
    local $/;
    my $contents = <$handle>;
    close $handle;

    return defined $contents ? $contents : '';
}

sub _resolve_env {
    my ($self, $layers, $context) = @_;

    my %env;
    for my $layer (@$layers) {
        next unless defined $layer && ref $layer eq 'HASH';
        for my $key (keys %$layer) {
            $env{$key} = _stringify($layer->{$key});
        }
    }

    for my $pass (1 .. 10) {
        my %with_env = (%$context, env => { %env });
        my $changed = 0;
        for my $key (keys %env) {
            my $value = eval {
                $self->{expression}->interpolate($env{$key}, \%with_env);
            };
            if ($@) {
                my $error = $@;
                $error =~ s/\s+$//;
                croak "Unable to evaluate environment variable '$key': $error";
            }
            if ($value ne $env{$key}) {
                $env{$key} = $value;
                $changed = 1;
            }
        }
        last unless $changed;
    }

    return \%env;
}

sub _boolean_value {
    my ($self, $value, $context, $status) = @_;

    return $value ? 1 : 0 if ref $value;
    return 0 unless defined $value;

    my $text = "$value";
    $text =~ s/^\s+|\s+$//g;
    return 0 if $text eq '';
    return 1 if $text =~ /^(?:true|yes|1)$/i;
    return 0 if $text =~ /^(?:false|no|0)$/i;

    return $self->{expression}->condition($text, $context, $status);
}

sub _github_context {
    my ($self, $job) = @_;

    # Before the run has built its base environment, the values derived from
    # the checkout are still enough to resolve github.ref and friends.
    my $env = $self->{base_env} || $self->_repository_env;
    my $job_id = ref $job eq 'HASH' ? $job->{base_id} : $job;

    return {
        event_name      => $env->{GITHUB_EVENT_NAME},
        event           => $self->{event} || {},
        event_path      => '/github/actions-runner/event.json',
        ref             => $env->{GITHUB_REF},
        ref_name        => $env->{GITHUB_REF_NAME},
        ref_type        => $env->{GITHUB_REF_TYPE},
        sha             => $env->{GITHUB_SHA},
        repository      => $env->{GITHUB_REPOSITORY},
        repository_owner => $env->{GITHUB_REPOSITORY_OWNER},
        workflow        => $self->{workflow}->name,
        job             => $job_id,
        run_id          => $env->{GITHUB_RUN_ID},
        run_number      => $env->{GITHUB_RUN_NUMBER},
        run_attempt     => $env->{GITHUB_RUN_ATTEMPT},
        actor           => $env->{GITHUB_ACTOR},
        server_url      => $env->{GITHUB_SERVER_URL},
        api_url         => $env->{GITHUB_API_URL},
        graphql_url     => $env->{GITHUB_GRAPHQL_URL},
        workspace       => '/github/workspace',
        token           => '',
        head_ref        => '',
        base_ref        => '',
    };
}

sub _runner_context {
    my ($self) = @_;

    return {
        os          => 'Linux',
        arch        => 'X64',
        name        => 'local',
        temp        => '/github/actions-runner/_temp',
        tool_cache  => '/github/actions-runner/_tool',
        workspace   => '/github/workspace',
    };
}

# The number of pulls the run allows at once: --pull-concurrency, then
# ACTION_RUN_PULL_CONCURRENCY, then four, but never more than one on Windows,
# where the pulls run one after another.  This is the number handed to the
# puller, and so the number the preflight reports, rather than what was asked
# for.
sub _effective_pull_concurrency {
    my ($self) = @_;

    return 1 if $^O eq 'MSWin32';

    return $self->{pull_concurrency};
}

sub _ensure_image {
    my ($self, $image) = @_;

    return 1 if $self->{dry_run};

    # --pull refreshes an image once per run.  The preflight prepares every
    # image the run will need before the first job starts, so a job that
    # checks its own image again, a second matrix job using the same image, or
    # a step that names an image another step already used would otherwise
    # download it again for no gain.
    return 1 if $self->{pulled_once}{$image};

    my $exists = $self->{docker}->image_exists($image);

    if ($self->{pull} || !$exists) {
        if ($self->{no_pull}) {
            die "Docker image '$image' is not available locally (--no-pull)\n";
        }
        print "Pulling image $image...\n" unless $self->{quiet};
        $self->{docker}->pull($image);
        $self->{pulled_images}{$image} = 1 unless $exists;
        $self->{pulled_once}{$image} = 1;
    }

    return 1;
}

sub _platform_args {
    my ($self) = @_;

    return () unless defined $self->{platform} && length $self->{platform};
    return ('--platform', $self->{platform});
}

sub _resource_name {
    my ($self, $kind, $job, $suffix) = @_;

    my $counter = ++$self->{name_counter};
    my $short_id = substr($self->{run_id}, -8);
    my $base = $job->{base_id};
    $base =~ s/[^A-Za-z0-9_.-]/-/g;
    $base = substr($base, 0, 20);

    my $name = "action-run-$short_id-$counter-$kind-$base-$job->{matrix_index}";
    $name .= "-$suffix" if defined $suffix && length $suffix;
    $name =~ s/[^A-Za-z0-9_.-]/-/g;

    return substr($name, 0, 63);
}

sub _cleanup_job {
    my ($self, $network, $containers) = @_;

    return if $self->{keep};

    for my $container (reverse @$containers) {
        $self->{docker}->container_remove($container);
        @{ $self->{containers} } = grep { $_ ne $container } @{ $self->{containers} };
    }

    $self->{docker}->network_remove($network);
    @{ $self->{networks} } = grep { $_ ne $network } @{ $self->{networks} };

    return;
}

sub _cleanup {
    my ($self) = @_;

    return if $self->{cleaned_up}++;

    if ($self->{keep}) {
        if (@{ $self->{containers} } || @{ $self->{networks} } || $self->{temp_path}) {
            print "Kept Docker resources:\n" unless $self->{quiet};
            print "  container $_\n" for @{ $self->{containers} };
            print "  network $_\n" for @{ $self->{networks} };
            print "  temporary directory $self->{temp_path}\n" if $self->{temp_path};
        }
        return;
    }

    for my $container (reverse @{ $self->{containers} }) {
        $self->{docker}->container_remove($container);
    }
    for my $network (reverse @{ $self->{networks} }) {
        $self->{docker}->network_remove($network);
    }

    if (!$self->{keep_images}) {
        for my $image (sort keys %{ $self->{pulled_images} }) {
            $self->{docker}->image_remove($image);
        }
    }

    if ($self->{temp_path} && -d $self->{temp_path}) {
        eval { remove_tree($self->{temp_path}); };
    }

    return;
}

sub _print_summary {
    my ($self) = @_;

    return if $self->{quiet};

    print "\n=== Workflow summary ===\n";
    if (!@{ $self->{summary} }) {
        print "  No jobs were run.\n";
    } else {
        for my $entry (@{ $self->{summary} }) {
            printf "  %-50s %s\n", $self->_redact($entry->{name}), $entry->{result};
        }
    }
    print 'Workflow ', ($self->{workflow_failed} ? 'FAILED' : 'succeeded'), "\n";

    return;
}

sub _as_array {
    my ($value) = @_;

    return [] unless defined $value;
    return $value if ref $value eq 'ARRAY';
    return [$value];
}

sub _has_status_function {
    my ($condition) = @_;

    return 0 unless defined $condition;
    return $condition =~ /\b(?:success|failure|always|cancelled)\s*\(/ ? 1 : 0;
}

sub _truthy_scalar {
    my ($value) = @_;

    return $value ? 1 : 0 if ref $value;
    return 0 unless defined $value;
    return 0 if $value =~ /^(?:false|no|0)$/i;
    return 1;
}

sub _stringify {
    my ($value) = @_;

    return '' unless defined $value;
    if (blessed($value) && $value->isa('JSON::PP::Boolean')) {
        return $value ? 'true' : 'false';
    }
    return "$value" unless ref $value;
    return JSON::PP->new->canonical->encode($value);
}

sub _hostname {
    my ($value) = @_;

    $value = 'local' unless defined $value && length $value;
    $value =~ s/[^A-Za-z0-9.-]/-/g;
    $value = substr($value, 0, 63);
    $value = 'local' unless length $value;

    return $value;
}

sub _shell_quote {
    my ($value) = @_;

    $value = '' unless defined $value;
    $value =~ s/'/'\\''/g;
    return "'$value'";
}

sub _redact {
    my ($self, $text) = @_;

    return $text unless defined $text;
    return $self->{docker}->redact($text) if $self->{docker}->can('redact');
    return $text;
}

sub _trim {
    my ($value) = @_;

    return '' unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    return $value;
}

1;

__END__

=head1 NAME

App::Actions::Runner - run a GitHub Actions workflow in Docker

=head1 SYNOPSIS

    use App::Actions;
    use App::Actions::Runner;

    my $runner = App::Actions::Runner->new(
        workflow    => $workflow,
        project_dir => '/home/njh/src/njh/CGI-Info',
        image       => 'ubuntu:latest',
    );
    my $exit = $runner->run;

=head1 DESCRIPTION

This module executes the jobs in a workflow.  Each job gets its own Docker
network, its own service containers, and a long-lived job container.  Steps
are executed with C<docker exec>, so filesystem changes persist between
steps while each step gets a fresh shell, just as on GitHub.

A service has to stay up.  One that stops is reported with the status it
exited with and the last lines it printed; one that its restart policy keeps
bringing back, or that is caught between attempts, fails the run the same way,
with the restart count, rather than being taken for a working service because
Docker reports it as running.

Containers, networks, and any images that this run pulled are removed when the
job or run finishes.  Use C<keep> for debugging.

=head1 METHODS

=head2 run

Runs every selected job and returns an exit status: 0 for success, 1 for a
workflow failure, 2 for a usage or Docker error.

=head2 preflight

    my $result = $runner->preflight(json => 1);

Makes the same checks and image preparations as a run, without starting a
container.  Returns a hash of C<exit>, C<summary> and C<error>.  The summary is
the L<App::Actions::Check> report with C<images> added and
C<pull_concurrency> reporting the number of pulls the preflight was allowed at
once, which is 1 on Windows whatever was configured.  Its C<schema_version> is
L</preflight_schema_version> rather than the check's, because the document is
its own shape.

Unless C<json> is set it also prints, one line per image, what needs the image
and whether it was pulled, already present, failed, skipped or deferred; a
deferred image is printed by its expression with the reason it could not be
resolved, since no name exists until its step has run.  The text report ends
with the version of the schema the preflight document is written against, and
the check report it embeds leaves its own version line out; pass
C<schema_line =E<gt> 0> when the caller prints a report that is not this
document, as the smoke test does.  With C<json> the summary is the document
that C<action-run preflight --json> prints, C<ready>
is already a JSON boolean rather than 0 or 1, and the document is validated
against L</json_schema> before it is returned: a key that was added, removed
or retyped without the schema changing dies here with an
L<App::Actions::Schema::Invalid|App::Actions::Schema/App::Actions::Schema::Invalid>
exception naming the first mismatch, rather than surprising whatever reads the
document.  C<action-run> turns that exception into exit 70, so a caller is not
left thinking the host needs fixing.

=head2 preflight_schema_version

    my $version = App::Actions::Runner->preflight_schema_version;

Returns the version of the preflight JSON document, which is also its
C<schema_version> key.  The checked-in example is validated against the schema
in F<t/schema.t>.

=head2 json_schema

    my $schema = App::Actions::Runner->json_schema;

Returns the JSON schema of the preflight document as a hash, the same document
C<action-run schema preflight> prints.  It is kept here so that the contract
ships with the module rather than only with the tests.

=head2 list_jobs

Prints the expanded jobs and returns 0.

=head1 LIMITATIONS

Only Linux C<runs-on> runners are supported.  JavaScript actions cannot be
executed locally; well-known actions such as checkout and setup-perl become
no-ops, and other actions are skipped with a warning unless C<strict_actions>
is set.  Local composite actions, job outputs, C<needs.*.outputs>, and
C<timeout-minutes> are not implemented.  C<hashFiles()> is not implemented.

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
