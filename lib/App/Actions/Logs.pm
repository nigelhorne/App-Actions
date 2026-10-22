package App::Actions::Logs;

use strict;
use warnings;
use Carp qw(croak);
use File::Spec;
use JSON::PP ();
use Readonly;

use App::Actions::Cache ();
use App::Actions::I18N qw(i18n);
use App::Actions::Schema ();

our $VERSION = '0.01';

# A parallel run copies each job's log out of its temporary directory before
# that is removed, into a directory named after the run.  They are kept so a
# failure can be read after the containers are gone, but nothing used to
# remove them; this module lists what is there and removes it when asked.
#
# The run directories are named by this tool, so a prune only touches a
# directory that matches that name and only deletes files that are job logs.
# A log directory shared with anything else - ACTION_RUN_LOG_DIR can point
# anywhere - is left alone.

# Each pattern is anchored itself and used as it is: wrapping it again, as
# /\A$RUN_DIRECTORY\z/, anchored it twice and built a new pattern from it.
Readonly::Scalar my $RUN_DIRECTORY => qr/\A\d{8}-\d{6}-[0-9a-fA-F]+\z/;    # 20261021-222955-6ad9752153c1
Readonly::Scalar my $LOG_FILE => qr/\Ajob-\d+(?:-[A-Za-z0-9_.-]+)?\.log\z/;  # job-2-test_n_bad.log

# The shape of the JSON document this module prints.  Bump it whenever a key,
# a value type or an enum changes, and update the schema below and the examples
# in t/fixtures/ with it; t/schema.t asserts the number rather than discovering
# a changed shape where its assertion fails for another reason.
our $JSON_SCHEMA_VERSION = 3;

# The schema of the document logs --json prints, so that the installed
# action-run can hand the contract to a caller.  A change to the document
# belongs here, in $JSON_SCHEMA_VERSION and in the examples in t/fixtures/,
# which t/schema.t holds against this and fails when a key it names appears in
# none of them.
my $JSON_SCHEMA = <<'JSON';
{
  "title": "action-run logs --json",
  "description": "The document action-run logs --json prints.  Objects reject keys this file does not name, so a new key is a schema change.",
  "version": 3,
  "type": "object",
  "properties": {
    "schema_version": {
      "description": "The version of this shape; App::Actions::Logs->json_schema_version returns it.",
      "type": "integer",
      "const": 3
    },
    "generated_at": {
      "description": "The epoch second the document was made; age is measured from this clock.",
      "type": "integer"
    },
    "logs_directory": {
      "description": "The directory the kept logs were read from, and that --prune changed.",
      "type": "string"
    },
    "logs": {
      "description": "Every kept log, sorted by run and then by file name.",
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "run": {
            "description": "The run directory the log belongs to, as action-run named it.",
            "type": "string"
          },
          "name": {
            "description": "The log file's name within the run directory.",
            "type": "string"
          },
          "path": {
            "description": "The path the log can be read from.",
            "type": "string"
          },
          "size": {
            "description": "The bytes the log takes.",
            "type": "integer"
          },
          "mtime": {
            "description": "When the log was last written, in epoch seconds.",
            "type": "integer"
          },
          "age": {
            "description": "How many seconds before generated_at the log was last written; 0 when mtime is later than generated_at, as the text report shows it.",
            "type": "integer"
          }
        },
        "required": [ "run", "name", "path", "size", "mtime", "age" ]
      }
    },
    "totals": {
      "description": "The runs, logs and disk the listing found.",
      "type": "object",
      "properties": {
        "runs": { "type": "integer" },
        "logs": { "type": "integer" },
        "size": { "type": "integer" }
      },
      "required": [ "runs", "logs", "size" ]
    },
    "prune": {
      "description": "What --prune did, or null when the command only listed the logs.",
      "oneOf": [
        { "type": "null" },
        {
          "type": "object",
          "properties": {
            "removed": { "type": "integer" },
            "freed": { "type": "integer" },
            "failed": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "run": { "type": "string" },
                  "error": { "type": "string" }
                },
                "required": [ "run", "error" ]
              }
            }
          },
          "required": [ "removed", "freed", "failed" ]
        }
      ]
    }
  },
  "required": [
    "schema_version",
    "generated_at",
    "logs_directory",
    "logs",
    "totals",
    "prune"
  ]
}
JSON

sub json_schema {
    return JSON::PP->new->decode($JSON_SCHEMA);
}

sub json_schema_version { return $JSON_SCHEMA_VERSION }

# The directory a run keeps its per-job logs in: ACTION_RUN_LOG_DIR, then the
# per-user cache directory under action-run/logs.  It is the default a Runner
# uses too, so the command and the runs cannot disagree about where the logs
# are.
sub default_directory {
    my $override = $ENV{ACTION_RUN_LOG_DIR};

    # An empty variable is the same as an unset one.
    return (defined $override && length $override)
        ? $override
        : File::Spec->catdir(App::Actions::Cache::base_directory(), 'action-run', 'logs');
}

sub new {
    my ($class, %args) = @_;

    my $directory = $args{directory};
    $directory = default_directory()
        if !defined $directory || !length $directory;

    return bless { directory => $directory }, $class;
}

sub directory { return $_[0]->{directory} }

# Every run directory that holds at least one job log, newest first.  Only the
# names this tool writes are considered, so a stray file in a shared log
# directory is neither listed nor removed.  A symlink is skipped: following
# one would report, and a prune would delete, something outside the directory.
sub entries {
    my ($self) = @_;

    my $root = $self->{directory};
    return [] unless -d $root;

    opendir my $handle, $root
        or croak "cannot read the log directory '$root': $!";

    my @runs;
    for my $name (sort { $b cmp $a } grep { $_ =~ $RUN_DIRECTORY } readdir $handle) {
        my $run = File::Spec->catdir($root, $name);
        next if -l $run || !-d $run;

        opendir my $logs, $run or next;
        my @files;
        for my $file (sort grep { $_ =~ $LOG_FILE } readdir $logs) {
            my $path = File::Spec->catfile($run, $file);
            next if -l $path || !-f $path;

            my @stat = stat $path;
            next unless @stat;

            push @files, {
                name  => $file,
                path  => $path,
                size  => $stat[7],
                mtime => $stat[9],
            };
        }
        closedir $logs;

        next unless @files;
        push @runs, {
            name      => $name,
            directory => $run,
            logs      => \@files,
        };
    }
    closedir $handle;

    return \@runs;
}

# The logs a threshold selects, grouped by the run they belong to.  A log is
# always stamped with its own modification time, so unlike an image it has no
# unknown age; the comparison still leaves a clock that is ahead out of a
# positive threshold rather than guessing that it is old.  A run with no
# selected log is left out, so a prune never touches a run it was not asked
# about.
sub _selected_runs {
    my ($self, %args) = @_;

    my $runs = $self->entries;
    return $runs unless defined $args{older_than};

    my $now = defined $args{now} ? $args{now} : time;
    my @selected;

    for my $run (@$runs) {
        my @logs = grep {
            $now - $_->{mtime} >= $args{older_than}
        } @{ $run->{logs} };

        next unless @logs;
        push @selected, { %$run, logs => \@logs };
    }

    return \@selected;
}

# The words are shared with the cache listing, which reports an image's age
# the same way.  The largest whole unit is used, so 90 minutes is an hour ago
# and 23 hours is still hours rather than a day.
sub format_age {
    return App::Actions::Cache::format_age($_[0]);
}

# The listing: one line per kept job log, with the size it takes and how long
# ago the run wrote it.  Everything is read from the files themselves, so a
# log removed outside the tool simply stops being listed.
sub report {
    my ($self, %args) = @_;

    my $now = defined $args{now} ? $args{now} : time;
    my $older_than = $args{older_than};
    my $runs = $self->_selected_runs(
        older_than => $older_than, now => $now,
    );

    my $out = "Logs directory: $self->{directory}\n";

    my @rows;
    for my $run (@$runs) {
        for my $log (@{ $run->{logs} }) {
            push @rows, [ $run->{name}, $log->{name}, $log->{size},
                format_age($now - $log->{mtime}) ];
        }
    }

    unless (@rows) {
        if (defined $older_than && @{ $self->entries }) {
            return $out . 'No job logs are older than '
                . App::Actions::Cache::format_span($older_than) . ".\n";
        }

        return $out . "No job logs have been kept yet.\n";
    }

    $out .= 'Only job logs older than '
        . App::Actions::Cache::format_span($older_than) . ".\n"
        if defined $older_than;

    my ($run_width, $log_width) = (3, 3);
    for my $row (@rows) {
        $run_width = length $row->[0] if length $row->[0] > $run_width;
        $log_width = length $row->[1] if length $row->[1] > $log_width;
    }

    my $total = 0;
    $total += $_->[2] for @rows;

    $out .= "\n";
    $out .= sprintf(
        "  %-*s  %-*s  %10s  %s\n",
        $run_width, 'RUN', $log_width, 'LOG', 'SIZE', 'AGE',
    );
    for my $row (@rows) {
        $out .= sprintf(
            "  %-*s  %-*s  %10s  %s\n",
            $run_width, $row->[0], $log_width, $row->[1],
            App::Actions::Cache::format_size($row->[2]), $row->[3],
        );
    }

    $out .= "\n" . __PACKAGE__->i18n('logs.summary', {
        count => scalar @rows, size => App::Actions::Cache::format_size($total),
    }) . "\n";
    $out .= "Remove them with \"action-run logs --prune\".\n";

    return $out;
}

# Remove every selected log, and the run directory once that is empty.  Only a
# file that matched the listing is unlinked, so a note left in a run directory
# survives, and a newer log keeps its run directory even when the older logs
# beside it went.  A directory named another way is never touched.  A removal
# that fails is reported and leaves the rest of the prune to carry on, with
# exit 1.
sub prune {
    my ($self, %args) = @_;

    my $now = defined $args{now} ? $args{now} : time;
    my $older_than = $args{older_than};
    my $runs = $self->_selected_runs(
        older_than => $older_than, now => $now,
    );
    my $out = "Logs directory: $self->{directory}\n";

    unless (@$runs) {
        my $data = { removed => 0, freed => 0, failed => [] };

        if (defined $older_than && @{ $self->entries }) {
            return (
                $out . 'No job logs are older than '
                    . App::Actions::Cache::format_span($older_than) . ".\n",
                0,
                $data,
            );
        }

        return ($out . "No job logs have been kept yet.\n", 0, $data);
    }

    my ($removed, $freed) = (0, 0);
    my @failed;

    for my $run (@$runs) {
        my $count = @{ $run->{logs} };
        my $size  = 0;
        $size += $_->{size} for @{ $run->{logs} };

        my $ok = eval {
            for my $log (@{ $run->{logs} }) {
                $self->_unlink($log->{path})
                    or die "cannot remove '$log->{path}': $!\n";
            }

            # A directory holding something else is left in place; its logs
            # are gone, so the next listing has nothing to say about it.
            rmdir $run->{directory};
            1;
        };

        if ($ok) {
            $removed += $count;
            $freed   += $size;
            next;
        }

        my $error = $@;
        $error =~ s/\s+$//;
        push @failed, { run => $run->{name}, error => $error };
    }

    $out .= __PACKAGE__->i18n('logs.removed', {
        count => $removed, size => App::Actions::Cache::format_size($freed),
    }) . "\n" if $removed;

    my $data = { removed => $removed, freed => $freed, failed => \@failed };

    if (@failed) {
        $out .= __PACKAGE__->i18n('logs.remove_failed', { count => scalar @failed }) . "\n";
        $out .= "  $_->{run}: $_->{error}\n" for @failed;
        return ($out, 1, $data);
    }

    return ($out, 0, $data);
}

# The machine-readable form of the listing, or of a prune that was just run.
# A listing is a flat array like the cache document's images, because a caller
# asserting on it wants the logs rather than the directory tree.  Every key is
# always present and the totals count what the array holds, so an empty
# directory is three zeroes rather than missing keys.  The document is checked
# against the schema this module ships before it is returned.
sub document {
    my ($self, %args) = @_;

    my $now = defined $args{now} ? $args{now} : time;
    my $runs = $self->_selected_runs(
        older_than => $args{older_than}, now => $now,
    );
    my @logs;
    my ($count, $size) = (0, 0);

    for my $run (@$runs) {
        for my $log (@{ $run->{logs} }) {
            my $age = $now - $log->{mtime};
            $age = 0 if $age < 0;

            push @logs, {
                run   => $run->{name},
                name  => $log->{name},
                path  => $log->{path},
                size  => $log->{size} + 0,
                mtime => $log->{mtime} + 0,
                age   => $age + 0,
            };
            $count++;
            $size += $log->{size};
        }
    }

    my $document = {
        schema_version => $JSON_SCHEMA_VERSION,
        generated_at   => $now + 0,
        logs_directory => $self->{directory},
        logs           => \@logs,
        totals         => {
            runs  => scalar @$runs,
            logs  => $count,
            size  => $size,
        },
        prune => $args{prune},
    };

    App::Actions::Schema::assert_valid(
        $document, $self->json_schema,
        'the action-run logs --json document does not match App::Actions::Logs->json_schema',
    );

    return $document;
}

# The one place a log file is removed, so a test can make the filesystem say
# no without changing permissions that mean different things on another host.
sub _unlink {
    my (undef, $path) = @_;
    return unlink $path;
}

1;

__END__

=head1 NAME

App::Actions::Logs - the per-job logs action-run keeps between runs

=head1 SYNOPSIS

    use App::Actions::Logs;

    my $logs = App::Actions::Logs->new;
    print $logs->report;

    my ($report, $exit, $pruned) = $logs->prune;
    my $document = $logs->document(prune => $pruned);

=head1 DESCRIPTION

A parallel run copies each job's output out of its temporary directory before
that is removed, so a failure can be read - or pasted into a bug report - after
the containers are gone.  This module is what C<action-run logs> reads: one
entry per kept log, with its size and how long ago the run wrote it, and a
prune that removes them.  C<action-run logs --json> prints the same listing as
a versioned JSON document, described under L</JSON OUTPUT> and held to the
schema L</json_schema> returns.

The directory is C<$XDG_CACHE_HOME/action-run/logs>, or
C<~/.cache/action-run/logs> when C<XDG_CACHE_HOME> is not set, and
C<%LOCALAPPDATA%\\action-run\\logs> on Windows.  C<ACTION_RUN_LOG_DIR>
overrides it.  Only a run directory named the way this tool writes one is
listed or removed, so a shared directory holding other files is not emptied.

=head1 METHODS

=head2 new

    my $logs = App::Actions::Logs->new(%options);

C<directory> names the log directory; the default is the path described above.

=head2 directory

Returns the directory this object reads.

=head2 entries

    my $runs = $logs->entries;

Returns one entry per run directory that holds a job log, newest first.  Each
is C<< { name, directory, logs } >>, and each log is
C<< { name, path, size, mtime } >>.  A file or directory that does not match
the names this tool writes is ignored.

=head2 report

    print $logs->report;

The listing C<action-run logs> prints: one row per kept log naming the run,
the file, its size and its age, then the number of logs and the disk they
take.  C<older_than> (seconds) restricts the rows and totals to logs at least
that old, so a run with only newer logs is not listed.  C<now> (epoch seconds)
can be passed for a fixed clock in a test.

=head2 prune

    my ($report, $exit, $pruned) = $logs->prune(
        older_than => 2 * 24 * 60 * 60,  # optional
        now        => time,               # optional, for a fixed clock
    );

Remove the selected logs and return what was printed with the exit status: 0
when every selected log went, 1 when one could not be removed and was
reported.  Without C<older_than> every kept log is selected; with it only
logs at least that old are removed, so newer logs stay in their run.  The run
directory is removed too once it is empty; a directory that does not match
the name this tool writes, or that holds anything else, is left alone.
C<$pruned> is the C<prune> object of the JSON document, with the counts the
report says in words and the runs that stayed.

=head2 document

    my $document = $logs->document(
        older_than => 2 * 24 * 60 * 60,  # optional
        prune      => $pruned,            # optional, from prune()
        now        => time,               # optional, for a fixed clock
    );

Returns the document C<action-run logs --json> prints, described under
L</JSON OUTPUT>.  C<older_than> restricts C<logs> and C<totals> to the logs
the listing selected.  C<prune> is omitted for a listing and is the value
L</prune> returned after a prune.  C<now> (epoch seconds) can be passed for a
fixed clock in a test; it becomes the document's C<generated_at>.  The
document is checked against
L</json_schema> before it is returned, so a key that was added or retyped
without the schema changing raises an
L<App::Actions::Schema::Invalid|App::Actions::Schema/App::Actions::Schema::Invalid>
exception naming the first mismatch instead of being printed.

=head2 json_schema

    my $schema = App::Actions::Logs->json_schema;

Returns the JSON schema of the C<logs --json> document as a hash, the same
document C<action-run schema logs> prints.  It lives here rather than in the
test directory so that an installed distribution can hand the contract to a
caller; F<t/schema.t> validates the examples and the document against it.

=head2 json_schema_version

    my $version = App::Actions::Logs->json_schema_version;

Returns the version of the JSON document, which is also its C<schema_version>
key.  It is bumped when the shape changes, so an assertion can name the shape
it was written for.

=head1 JSON OUTPUT

With C<json> the listing is a single object, with every key always present:

    {
      "schema_version": 3,
      "generated_at": 1792540920,
      "logs_directory": "/home/me/.cache/action-run/logs",
      "logs": [
        { "run": "20261021-121355-6ad8e4c30f83", "name": "job-1-test_n_one.log", "path": "/home/me/.cache/action-run/logs/20261021-121355-6ad8e4c30f83/job-1-test_n_one.log", "size": 1229, "mtime": 1792540800, "age": 120 },
        { "run": "20261021-121355-6ad8e4c30f83", "name": "job-2-test_n_two.log", "path": "/home/me/.cache/action-run/logs/20261021-121355-6ad8e4c30f83/job-2-test_n_two.log", "size": 819, "mtime": 1792540800, "age": 120 }
      ],
      "totals": { "runs": 1, "logs": 2, "size": 2048 },
      "prune": null
    }

C<logs> is sorted by run and then by file name.  C<size> is the bytes the log
takes, C<generated_at> the epoch second the document was made, C<mtime> the
epoch second the log was last written and C<age> the seconds between them.
C<age> is C<generated_at> minus C<mtime>, so a caller can use it without
subtracting from its own clock or parsing a phrase; it is 0 when the log's
clock is ahead of C<generated_at>, as the text report shows such a log as
C<just now>.  C<totals> counts the runs, logs and bytes the listing found.
With C<older_than> only the selected logs are in C<logs>, and the totals count
only them.  C<prune> is C<null> for a listing and an object after C<--prune>,
carrying C<removed>, C<freed> and the C<failed> runs that stayed, each with
its C<run> name and C<error>.  The document is printed even when a removal
failed, and the exit status is 1.

C<schema_version> names the shape of the document; it is the number
L</json_schema_version> returns.  The schema is what C<action-run schema
logs> prints, and the checked-in examples are F<t/fixtures/logs.json>,
F<t/fixtures/logs-empty.json>, F<t/fixtures/logs-prune.json> and
F<t/fixtures/logs-prune-failed.json>.  F<t/schema.t> validates them against
it and fails when a property it names appears in none of them.

=head2 format_age

    my $age = App::Actions::Logs::format_age($seconds);

How old a log is in words: C<just now>, C<3 minutes ago>, C<2 hours ago>,
C<5 days ago>, C<2 months ago> or C<1 year ago>.  Each step uses the largest
whole unit, so 90 minutes is C<1 hour ago>.

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
