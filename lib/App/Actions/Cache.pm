package App::Actions::Cache;

use strict;
use warnings;
use Carp qw(croak);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP ();

use App::Actions::Schema ();

our $VERSION = '0.01';

# The images action-run keeps are a cache: a run records what it pulled, so a
# later command can list the images and say how much disk they take, and
# remove them when they are no longer wanted.  The record holds names only -
# the size is asked of the daemon each time, because an image can be removed
# or replaced behind the tool's back.

my $FORMAT = 1;

# The shape of the JSON document this module prints.  Bump it whenever a key,
# a value type or an enum changes, and update the schema below and the examples
# in t/fixtures/ with it; a CI job asserts the number rather than discovering
# a changed shape at the point where its assertion fails for another reason.
our $JSON_SCHEMA_VERSION = 3;

# The schema of the document cache --json prints, so that the installed
# action-run can hand the contract to a caller instead of leaving it in the
# tests.  A change to the document belongs here, in $JSON_SCHEMA_VERSION and
# in the examples in t/fixtures/, which t/schema.t holds against this and
# fails when a key it names appears in none of them.
my $JSON_SCHEMA = <<'JSON';
{
  "title": "action-run cache --json",
  "description": "The document action-run cache --json prints.  Objects reject keys this file does not name, so a new key is a schema change.",
  "version": 3,
  "type": "object",
  "properties": {
    "schema_version": {
      "description": "The version of this shape; App::Actions::Cache->json_schema_version returns it.",
      "type": "integer",
      "const": 3
    },
    "generated_at": {
      "description": "The epoch second the document was made; an image's age is generated_at minus its last_used.",
      "type": "integer"
    },
    "cache_file": {
      "description": "The record the images were read from, and that --prune changed.",
      "type": "string"
    },
    "docker": {
      "description": "The Docker command and whether it could be reached.",
      "type": "object",
      "properties": {
        "bin": { "type": "string" },
        "reachable": { "type": "boolean" }
      },
      "required": [ "bin", "reachable" ]
    },
    "images": {
      "description": "Every image the command selected, sorted by name; a listing without --older-than selects the whole record.",
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "image": { "type": "string" },
          "pulls": {
            "description": "How many runs pulled and kept the image.",
            "type": "integer"
          },
          "last_used": {
            "description": "When a run last used the image, in epoch seconds, or null in a record written without it.",
            "type": [ "integer", "null" ]
          },
          "age": {
            "description": "The seconds between generated_at and last_used, or null when last_used is unknown; 0 when last_used is later than generated_at.",
            "type": [ "integer", "null" ]
          },
          "size": {
            "description": "The bytes the daemon reports, or null when it could not report one.",
            "type": [ "integer", "null" ]
          },
          "present": {
            "description": "Whether the daemon has the image, or null when the daemon could not be reached.",
            "type": [ "boolean", "null" ]
          }
        },
        "required": [ "image", "pulls", "last_used", "age", "size", "present" ]
      }
    },
    "totals": {
      "description": "The selected images and the disk they take.  The size and the counts are null when the daemon could not be reached.",
      "type": "object",
      "properties": {
        "images": { "type": "integer" },
        "size": { "type": [ "integer", "null" ] },
        "present": { "type": [ "integer", "null" ] },
        "missing": { "type": [ "integer", "null" ] }
      },
      "required": [ "images", "size", "present", "missing" ]
    },
    "prune": {
      "description": "What --prune did to the images --older-than selected, or null when the command only listed the record.",
      "oneOf": [
        { "type": "null" },
        {
          "type": "object",
          "properties": {
            "removed": { "type": "integer" },
            "freed": { "type": "integer" },
            "forgotten": { "type": "integer" },
            "failed": {
              "type": "array",
              "items": { "type": "string" }
            }
          },
          "required": [ "removed", "freed", "forgotten", "failed" ]
        }
      ]
    }
  },
  "required": [
    "schema_version",
    "generated_at",
    "cache_file",
    "docker",
    "images",
    "totals",
    "prune"
  ]
}
JSON

sub json_schema {
    my ($class) = @_;

    return JSON::PP->new->decode($JSON_SCHEMA);
}

sub json_schema_version { return $JSON_SCHEMA_VERSION }

# The per-user directory action-run keeps its own state in: the image cache
# record and the logs of a run.  XDG_CACHE_HOME is where a Linux or macOS
# desktop puts that, and LOCALAPPDATA where Windows does.
sub base_directory {
    my $base;
    if ($^O eq 'MSWin32') {
        $base = $ENV{LOCALAPPDATA};
        if (!defined $base || !length $base) {
            $base = File::Spec->catdir($ENV{USERPROFILE}, 'AppData', 'Local')
                if defined $ENV{USERPROFILE} && length $ENV{USERPROFILE};
        }
    } else {
        $base = $ENV{XDG_CACHE_HOME};
        $base = File::Spec->catdir($ENV{HOME}, '.cache')
            if !defined $base || !length $base;
    }

    $base = File::Spec->catdir(File::Spec->curdir, '.cache')
        if !defined $base || !length $base;

    return $base;
}

sub default_path {
    my $override = $ENV{ACTION_RUN_CACHE_FILE};
    return $override if defined $override && length $override;

    return File::Spec->catfile(base_directory(), 'action-run', 'cache.json');
}

sub new {
    my ($class, %args) = @_;

    my $file = $args{file};
    $file = default_path() if !defined $file || !length $file;

    return bless { file => $file, data => undef }, $class;
}

sub file { return $_[0]->{file} }

sub load {
    my ($self) = @_;

    return $self->{data} if $self->{data};

    my $images = {};
    my $path   = $self->{file};

    if (-e $path) {
        my $text = '';
        if (open my $handle, '<', $path) {
            binmode $handle;
            $text = do { local $/; <$handle> };
            close $handle;
        }
        $text = '' unless defined $text;

        # A cache that cannot be read is not worth failing a run over: the
        # images are still there, and the next run records them again.
        my $decoded = eval { JSON::PP->new->decode($text) };
        if ($decoded && ref $decoded eq 'HASH' && ref $decoded->{images} eq 'HASH') {
            for my $image (keys %{ $decoded->{images} }) {
                my $entry = $decoded->{images}{$image};
                next unless ref $entry eq 'HASH';
                $images->{$image} = {
                    pulls     => $entry->{pulls} || 0,
                    last_used => $entry->{last_used},
                };
            }
        }
    }

    return $self->{data} = { version => $FORMAT, images => $images };
}

sub save {
    my ($self) = @_;

    my $data = $self->{data} || $self->load;
    my $path = $self->{file};

    # Nothing cached means nothing to remember, so the file goes away rather
    # than staying behind as an empty document.
    if (!keys %{ $data->{images} }) {
        unlink $path if -e $path;
        return 1;
    }

    my $dir = dirname($path);
    make_path($dir) unless -d $dir;

    my $temp = File::Spec->catfile(
        $dir, sprintf('.cache-%d-%d.tmp', $$, int(rand(1_000_000))),
    );

    open my $handle, '>', $temp
        or croak "cannot write '$temp': $!";
    binmode $handle;
    print {$handle} JSON::PP->new->canonical->pretty->encode($data);
    close $handle or croak "cannot write '$temp': $!";

    if (!rename $temp, $path) {
        my $error = $!;
        unlink $temp;
        croak "cannot replace '$path': $error";
    }

    return 1;
}

# Record images this run pulled and kept.  Pulling the same image again later
# counts as another use, which is what "last used" reports.
sub remember {
    my ($self, @images) = @_;

    my $data = $self->load;
    my $now  = time;
    my $count = 0;

    for my $image (@images) {
        next unless defined $image && length $image;

        my $entry = $data->{images}{$image} || {};
        $entry->{pulls}     = ($entry->{pulls} || 0) + 1;
        $entry->{last_used} = $now;
        $data->{images}{$image} = $entry;
        $count++;
    }

    $self->save if $count;

    return $count;
}

sub entries {
    my ($self) = @_;

    my $images = $self->load->{images};

    return [
        map {
            {
                image     => $_,
                pulls     => $images->{$_}{pulls} || 0,
                last_used => $images->{$_}{last_used},
            }
        } sort keys %{$images}
    ];
}

# Forget images without touching the daemon: they are no longer there, or the
# user asked for them to be dropped from the record.
sub forget {
    my ($self, @images) = @_;

    my $data = $self->load;
    my $count = 0;

    for my $image (@images) {
        next unless defined $image;
        $count++ if delete $data->{images}{$image};
    }

    $self->save if $count;

    return $count;
}

sub format_size {
    my ($bytes) = @_;

    return '0 B' unless defined $bytes && $bytes > 0;

    my @units = qw(B KB MB GB TB);
    my $value = $bytes;
    my $unit  = 0;
    while ($value >= 1024 && $unit < $#units) {
        $value /= 1024;
        $unit++;
    }

    return sprintf('%d %s', $value, $units[$unit]) unless $unit;
    return sprintf('%.1f %s', $value, $units[$unit]);
}

my %DURATION_SECONDS = (
    s       => 1,
    sec     => 1,
    secs    => 1,
    second  => 1,
    seconds => 1,
    m       => 60,
    min     => 60,
    mins    => 60,
    minute  => 60,
    minutes => 60,
    h       => 60 * 60,
    hr      => 60 * 60,
    hrs     => 60 * 60,
    hour    => 60 * 60,
    hours   => 60 * 60,
    d       => 60 * 60 * 24,
    day     => 60 * 60 * 24,
    days    => 60 * 60 * 24,
    w       => 60 * 60 * 24 * 7,
    week    => 60 * 60 * 24 * 7,
    weeks   => 60 * 60 * 24 * 7,
    mo      => 60 * 60 * 24 * 30,
    month   => 60 * 60 * 24 * 30,
    months  => 60 * 60 * 24 * 30,
    y       => 60 * 60 * 24 * 365,
    yr      => 60 * 60 * 24 * 365,
    yrs     => 60 * 60 * 24 * 365,
    year    => 60 * 60 * 24 * 365,
    years   => 60 * 60 * 24 * 365,
);

# A duration is a number and a unit, with the unit matching the words the age
# column uses: 30s, 15m, 12h, 7d, 2w, 3mo or 1y.  Months and years are the
# 30- and 365-day spans format_age uses, so a threshold and the ages it filters
# cannot disagree about what "2 months" means.
sub parse_duration {
    my ($text) = @_;

    return unless defined $text;
    return unless $text =~ /\A\s*(\d+)\s*([A-Za-z]+)\s*\z/;

    my ($amount, $unit) = ($1, lc $2);
    return unless exists $DURATION_SECONDS{$unit};

    return $amount * $DURATION_SECONDS{$unit};
}

sub _format_span {
    my ($seconds) = @_;

    $seconds = 0 unless defined $seconds && $seconds =~ /\A-?\d+\z/;
    $seconds = 0 if $seconds < 0;

    my @units = (
        [ 1,                 'second' ],
        [ 60,                'minute' ],
        [ 60 * 60,           'hour'   ],
        [ 60 * 60 * 24,      'day'    ],
        [ 60 * 60 * 24 * 30, 'month'  ],
        [ 60 * 60 * 24 * 365, 'year'  ],
    );

    # The largest whole unit is used, so 90 minutes is an hour and 40 days is
    # a month, whether the number is an age or a threshold.
    my ($index, $amount) = (0, int($seconds / $units[0][0]));
    for my $next (1 .. $#units) {
        last if $seconds < $units[$next][0];
        $index  = $next;
        $amount = int($seconds / $units[$next][0]);
    }

    my $label = $units[$index][1];
    return sprintf('%d %s%s', $amount, $label, $amount == 1 ? '' : 's');
}

# How old a kept image is, in the words a reader expects rather than a second
# count.
sub format_age {
    my ($seconds) = @_;

    $seconds = 0 unless defined $seconds && $seconds =~ /\A-?\d+\z/;
    $seconds = 0 if $seconds < 0;

    return 'just now' if $seconds < 60;

    return _format_span($seconds) . ' ago';
}

# The entries a threshold selects.  An image with no recorded last use cannot
# be shown to be old enough, so it is left out rather than guessed at; that
# also keeps it in the record when the listing is a prune.
sub _selected_entries {
    my ($self, %args) = @_;

    my $entries = $self->entries;
    return $entries unless defined $args{older_than};

    my $now = defined $args{now} ? $args{now} : time;
    return [
        grep {
            defined $_->{last_used}
                && $now - $_->{last_used} >= $args{older_than}
        } @$entries
    ];
}

sub _stamp {
    my ($epoch) = @_;

    return '-' unless defined $epoch && $epoch =~ /\A\d+\z/;

    my @time = localtime($epoch);
    return sprintf(
        '%04d-%02d-%02d %02d:%02d',
        $time[5] + 1900, $time[4] + 1, $time[3], $time[2], $time[1],
    );
}

# The listing: one line per recorded image, with the size the daemon reports
# and when a run last pulled it.  When the daemon cannot be reached the names
# are still worth printing, so the sizes are left unknown instead of the
# command failing.
sub report {
    my ($self, %args) = @_;

    my $docker = $args{docker};
    my $now = defined $args{now} ? $args{now} : time;
    my $older_than = $args{older_than};
    my $entries = $self->_selected_entries(
        older_than => $older_than, now => $now,
    );

    my $out = "Cache file: $self->{file}\n";

    if (!@$entries) {
        if (defined $older_than && @{ $self->entries }) {
            return $out . 'No cached images are older than '
                . _format_span($older_than) . ".\n";
        }

        return $out . "No images have been cached yet.\n";
    }

    $out .= 'Only images older than ' . _format_span($older_than) . ".\n"
        if defined $older_than;

    my $width = 5;
    for my $entry (@$entries) {
        $width = length $entry->{image} if length $entry->{image} > $width;
    }

    my ($total, $sized, $missing) = (0, 0, 0);
    my @lines;

    for my $entry (@$entries) {
        my $size_text = 'unknown';
        if ($docker) {
            my $size = $docker->image_size($entry->{image});
            if (defined $size) {
                $total += $size;
                $sized++;
                $size_text = format_size($size);
            } else {
                $missing++;
                $size_text = 'missing';
            }
        }

        my $age_text = defined $entry->{last_used}
            ? format_age($now - $entry->{last_used})
            : 'unknown';

        push @lines, sprintf(
            '  %-*s  %10s  %-16s  %s',
            $width, $entry->{image}, $size_text, _stamp($entry->{last_used}),
            $age_text,
        );
    }

    $out .= "\n";
    $out .= sprintf(
        "  %-*s  %10s  %-16s  %s\n",
        $width, 'IMAGE', 'SIZE', 'LAST USED', 'AGE',
    );
    $out .= "$_\n" for @lines;

    my $count = @$entries;
    $out .= sprintf(
        "\n%d image%s%s.\n",
        $count, $count == 1 ? '' : 's',
        $sized ? ', ' . format_size($total) . ' on disk' : '',
    );

    if (!$docker) {
        $out .= "The Docker daemon is not reachable, so the sizes are unknown.\n";
    } elsif ($missing) {
        $out .= sprintf(
            "%d image%s no longer on the daemon.\n",
            $missing, $missing == 1 ? ' is' : 's are',
        );
    }

    $out .= "Remove them with \"action-run cache --prune\".\n" if $sized;

    return $out;
}

# Remove every recorded image.  The daemon is the judge of what is there: an
# image that has already gone is forgotten without an error, and one that
# cannot be removed stays in the record so a later attempt still sees it.
sub prune {
    my ($self, %args) = @_;

    my $docker = $args{docker}
        or croak 'pruning the image cache needs a Docker command';

    my $now = defined $args{now} ? $args{now} : time;
    my $older_than = $args{older_than};
    my $entries = $self->_selected_entries(
        older_than => $older_than, now => $now,
    );

    my $out = "Cache file: $self->{file}\n";
    if (!@$entries) {
        my $data = { removed => 0, freed => 0, forgotten => 0, failed => [] };

        if (defined $older_than && @{ $self->entries }) {
            return (
                $out . 'No cached images are older than '
                    . _format_span($older_than) . ".\n",
                0,
                $data,
            );
        }

        return ($out . "No images have been cached yet.\n", 0, $data);
    }

    my ($removed, $freed, $gone) = (0, 0, 0);
    my @failed;
    my @forget;

    for my $entry (@$entries) {
        my $image = $entry->{image};
        my $size  = $docker->image_size($image);

        # A size means the image is there; no size means it is not, or the
        # daemon is gone.  The check that precedes a prune tells the two
        # apart, so a missing image is simply forgotten.
        if (!defined $size) {
            push @forget, $image;
            $gone++;
            next;
        }

        if ($docker->image_remove($image) == 0) {
            push @forget, $image;
            $removed++;
            $freed += $size;
        } else {
            push @failed, $image;
        }
    }

    $self->forget(@forget) if @forget;

    my $data = {
        removed   => $removed,
        freed     => $freed,
        forgotten => $gone,
        failed    => [ @failed ],
    };

    $out .= sprintf(
        "Removed %d image%s, %s freed.\n",
        $removed, $removed == 1 ? '' : 's', format_size($freed),
    ) if $removed;

    $out .= sprintf(
        "Forgot %d image%s no longer on the daemon.\n",
        $gone, $gone == 1 ? '' : 's',
    ) if $gone;

    if (@failed) {
        $out .= sprintf(
            "Could not remove %d image%s:\n",
            scalar @failed, @failed == 1 ? '' : 's',
        );
        $out .= "  $_\n" for @failed;
        return ($out, 1, $data);
    }

    return ($out, 0, $data);
}

# The machine-readable form of the listing, or of a prune that was just run.
# The keys are stable and a value that could not be discovered is null rather
# than absent, so a reader can assert on the shape without a missing key
# meaning something different from an unknown value.
sub document {
    my ($self, %args) = @_;

    my $now   = defined $args{now} ? $args{now} : time;
    my $total = 0;
    my ($present, $missing) = (0, 0);
    my $reachable = $args{reachable} ? 1 : 0;
    my $docker = $args{docker};
    my $entries = $self->_selected_entries(
        older_than => $args{older_than}, now => $now,
    );

    my $bin = $args{docker_bin};
    $bin = $docker->bin
        if (!defined $bin || !length $bin) && $docker;
    $bin = 'docker' unless defined $bin && length $bin;

    my @images;
    for my $entry (@$entries) {
        my ($size, $is_present);

        if ($reachable && $docker) {
            $size = $docker->image_size($entry->{image});
            if (defined $size) {
                $total += $size;
                $present++;
                $is_present = JSON::PP::true();
            } else {
                $missing++;
                $is_present = JSON::PP::false();
            }
        }

        my $age;
        if (defined $entry->{last_used}) {
            $age = $now - $entry->{last_used};
            $age = 0 if $age < 0;
        }

        push @images, {
            image     => $entry->{image},
            pulls     => $entry->{pulls} + 0,
            last_used => $entry->{last_used},
            age       => $age,
            size      => $size,
            present   => $is_present,
        };
    }

    my $document = {
        schema_version => $JSON_SCHEMA_VERSION,
        generated_at   => $now + 0,
        cache_file     => $self->{file},
        docker         => {
            bin       => $bin,
            reachable => $reachable ? JSON::PP::true() : JSON::PP::false(),
        },
        images => \@images,
        totals => {
            images  => scalar @$entries,
            size    => $reachable ? $total : undef,
            present => $reachable ? $present : undef,
            missing => $reachable ? $missing : undef,
        },
        prune => $args{prune},
    };

    App::Actions::Schema::assert_valid(
        $document, $self->json_schema,
        'the action-run cache --json document does not match App::Actions::Cache->json_schema',
    );

    return $document;
}

1;

__END__

=head1 NAME

App::Actions::Cache - the record of images that action-run keeps between runs

=head1 SYNOPSIS

    use App::Actions::Cache;

    my $cache = App::Actions::Cache->new;
    $cache->remember('alpine:3.20');

    print $cache->report(docker => $docker);
    my $document = $cache->document(docker => $docker, reachable => 1);
    my ($report, $exit, $pruned) = $cache->prune(docker => $docker);

=head1 DESCRIPTION

A run keeps the images it pulls, because they are the next run's cache.  This
module is the record of which images those are: it is a small JSON file that
names each image, when a run last pulled it and how many runs have, so
C<action-run cache> can list them and C<action-run cache --prune> can remove
them.  Sizes are asked of Docker each time rather than stored, because an
image can be removed or replaced outside the tool.

The file is C<$XDG_CACHE_HOME/action-run/cache.json>, or
C<~/.cache/action-run/cache.json> when C<XDG_CACHE_HOME> is not set, and
C<%LOCALAPPDATA%\action-run\cache.json> on Windows.  C<ACTION_RUN_CACHE_FILE>
overrides it.  A file that cannot be read is treated as empty: the images are
still on the disk, and the next run records them again.

C<action-run cache --json> prints the same listing as a versioned JSON
document, which is described under L</JSON OUTPUT> and held to the schema
L</json_schema> returns.

=head1 METHODS

=head2 new

    my $cache = App::Actions::Cache->new(%options);

C<file> names the record; the default is the path described above.

=head2 remember

    my $count = $cache->remember(@images);

Record that a run pulled and kept each image, incrementing its use count and
setting the time it was last used.

=head2 entries

    my $entries = $cache->entries;

Returns an array of C<{ image, pulls, last_used }>, sorted by image name.

=head2 parse_duration

    my $seconds = App::Actions::Cache::parse_duration('30d');

Turn a duration such as C<30s>, C<15m>, C<12h>, C<7d>, C<2w>, C<3mo> or C<1y>
into seconds.  The unit may be spelled out (C<2 days>).  Months and years are
the 30- and 365-day spans the age column uses, so a threshold and the ages it
filters cannot disagree about what C<2 months> means.  An unknown unit, a
negative number or a number without a unit returns C<undef> instead of a
quietly wrong threshold.

=head2 forget

    my $count = $cache->forget(@images);

Drop images from the record without contacting Docker.  The record file is
removed when the last image goes.

=head2 report

    print $cache->report(docker => $docker);

The listing C<action-run cache> prints.  Pass C<docker> to have the sizes and
missing images reported; without it the names are listed with their sizes
unknown, which is what happens when the daemon is not running.  Each row
shows the time an image was last used and its age in words, using the same
C<generated_at> minus C<last_used> rule as the JSON document; an image with no
recorded use has an unknown age.  C<older_than> (seconds) restricts the
listing and its totals to images at least that old; an image with no recorded
use is left out, because its age cannot be shown to reach the threshold.
C<now> (epoch seconds) can be passed for a fixed clock in a test.

=head2 prune

    my ($report, $exit, $pruned) = $cache->prune(
        docker     => $docker,
        older_than => 2 * 24 * 60 * 60,  # optional
        now        => time,               # optional, for a fixed clock
    );

Remove the selected images and forget them; without C<older_than> that is
every recorded image.  With C<older_than> only images at least that old are
considered, so newer images stay in the record, and an image with no recorded
last use is left alone.  An image that has already gone is forgotten, one
that cannot be removed stays in the record, and C<$exit> is 1 when any removal
failed.  C<$pruned> is the C<prune> object of the JSON document, with the
counts the report says in words.

=head2 document

    my $document = $cache->document(
        docker     => $docker,      # undef when it could not be reached
        docker_bin => $docker->bin, # the command named in the document
        reachable  => 1,
        older_than => 2 * 24 * 60 * 60,  # optional, seconds
        prune      => $pruned,      # optional, from prune()
        now        => time,         # optional, for a fixed clock
    );

Returns the document C<action-run cache --json> prints, described under
L</JSON OUTPUT>.  C<older_than> restricts C<images> and C<totals> to the
images the listing selected.  The daemon is asked for each image's size only when
C<reachable> is true; otherwise the sizes, the presence of each image and the
counts that depend on them are C<undef>, which is written as C<null>.  C<now>
(epoch seconds) can be passed for a fixed clock in a test; it becomes the
document's C<generated_at>, and each image's C<age> is that value minus its
C<last_used>, or C<null> when the record has no last use; a last use later
than C<generated_at> is reported as age 0.  The
document is checked against L</json_schema> before it is returned, so a key
that was added or retyped without the schema changing raises an
L<App::Actions::Schema::Invalid|App::Actions::Schema/App::Actions::Schema::Invalid>
exception naming the first mismatch instead of being printed.

=head2 json_schema

    my $schema = App::Actions::Cache->json_schema;

Returns the JSON schema of the C<cache --json> document as a hash, the same
document C<action-run schema cache> prints.  It lives here rather than in the
test directory so that an installed distribution can hand the contract to a
caller; F<t/schema.t> validates the examples and the document against it.

=head2 json_schema_version

    my $version = App::Actions::Cache->json_schema_version;

Returns the version of the JSON document, which is also its C<schema_version>
key.  It is bumped when the shape changes, so an assertion can name the shape
it was written for.

=head1 JSON OUTPUT

With C<json> the listing is a single object, with every key always present and
C<null> for a value that could not be discovered:

    {
      "schema_version": 3,
      "generated_at": 1792540920,
      "cache_file": "/home/me/.cache/action-run/cache.json",
      "docker": { "bin": "docker", "reachable": true },
      "images": [
        { "image": "alpine:3.20", "pulls": 3, "last_used": 1792540800, "age": 120, "size": 12345678, "present": true },
        { "image": "perl:5.38", "pulls": 1, "last_used": 1792440000, "age": 100920, "size": null, "present": false }
      ],
      "totals": { "images": 2, "size": 12345678, "present": 1, "missing": 1 },
      "prune": null
    }

With C<older_than> only the images at least that old are in C<images>, and
the C<totals> count only them; an image with no C<last_used> is not selected.
C<size> is the bytes the daemon reports, C<present> whether it still has the
image, C<last_used> the epoch second a run last used it, and C<age> the
seconds between C<generated_at> and C<last_used>.  C<age> is C<null> when the
record has no last use, and 0 when the last use is later than
C<generated_at>, so a clock that is ahead is not reported as a negative age.
C<generated_at> is the epoch second the document was made, so the age needs
neither machine to agree on a clock.  When the daemon
cannot be reached, C<docker.reachable> is false and the sizes, C<present> and
the C<totals> that would count them are C<null>; the record's own values are
still listed.  C<prune> is C<null> for a listing and an object after
C<--prune>, carrying C<removed>, C<freed>, C<forgotten> and the C<failed>
images that stayed in the record.  The command's exit status is unchanged, so
a prune that could not remove an image still prints its document and exits 1.

C<schema_version> names the shape of the document; it is the number
L</json_schema_version> returns.  The schema is what C<action-run schema
cache> prints, and the checked-in examples are F<t/fixtures/cache.json> (two
images, one present and one missing), F<t/fixtures/cache-empty.json>,
F<t/fixtures/cache-unreachable.json> (the nulls for what the daemon could not
say) and F<t/fixtures/cache-prune.json>.  F<t/schema.t> validates them against
it and fails when a property or a null variant it names appears in none of
them.

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
