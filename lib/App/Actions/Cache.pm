package App::Actions::Cache;

use strict;
use warnings;
use Carp qw(croak);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP ();

our $VERSION = '0.01';

# The images action-run keeps are a cache: a run records what it pulled, so a
# later command can list the images and say how much disk they take, and
# remove them when they are no longer wanted.  The record holds names only -
# the size is asked of the daemon each time, because an image can be removed
# or replaced behind the tool's back.

my $FORMAT = 1;

sub default_path {
    my $override = $ENV{ACTION_RUN_CACHE_FILE};
    return $override if defined $override && length $override;

    my $base;
    if ($^O eq 'MSWin32') {
        $base = $ENV{LOCALAPPDATA};
        if (!defined $base || !length $base) {
            $base = File::Spec->catdir($ENV{USERPROFILE}, 'AppData', 'Local')
                if defined $ENV{USERPROFILE} && length $ENV{USERPROFILE};
        }
        $base = File::Spec->catdir(File::Spec->curdir, '.cache')
            if !defined $base || !length $base;
    } else {
        $base = $ENV{XDG_CACHE_HOME};
        $base = File::Spec->catdir($ENV{HOME}, '.cache')
            if !defined $base || !length $base;
        $base = File::Spec->catdir(File::Spec->curdir, '.cache')
            if !defined $base || !length $base;
    }

    return File::Spec->catfile($base, 'action-run', 'cache.json');
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
    my $entries = $self->entries;

    my $out = "Cache file: $self->{file}\n";

    if (!@$entries) {
        return $out . "No images have been cached yet.\n";
    }

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

        push @lines, sprintf(
            '  %-*s  %10s  %s',
            $width, $entry->{image}, $size_text, _stamp($entry->{last_used}),
        );
    }

    $out .= "\n";
    $out .= sprintf("  %-*s  %10s  %s\n", $width, 'IMAGE', 'SIZE', 'LAST USED');
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

    my $entries = $self->entries;

    my $out = "Cache file: $self->{file}\n";
    return $out . "No images have been cached yet.\n" unless @$entries;

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
        return ($out, 1);
    }

    return ($out, 0);
}

1;
