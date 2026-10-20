package App::Actions::Workflow;

use strict;
use warnings;
use Carp qw(croak);
use File::Basename qw(basename);
use JSON::PP ();
use YAML::PP;
use YAML::PP::Common qw(PRESERVE_ORDER);

use App::Actions::Expression;

our $VERSION = '0.01';

sub load {
    my ($class, $file) = @_;

    croak 'No workflow file given' unless defined $file && length $file;
    croak "Workflow file not found: $file" unless -f $file;

    my $yaml = YAML::PP->new(preserve => PRESERVE_ORDER);
    my $data = eval { $yaml->load_file($file) };
    if ($@) {
        my $error = $@;
        $error =~ s/\s+$//;
        croak "Unable to parse workflow '$file': $error";
    }
    croak "Workflow '$file' is empty" unless defined $data;
    croak "Workflow '$file' must contain a YAML mapping" unless ref $data eq 'HASH';

    my $jobs = $data->{jobs};
    croak "Workflow '$file' has no 'jobs' mapping" unless ref $jobs eq 'HASH';

    my @jobs;
    for my $id (keys %$jobs) {
        my $job = $jobs->{$id};
        croak "Job '$id' must be a mapping" unless ref $job eq 'HASH';
        croak "Job '$id' has no 'steps' list" unless ref $job->{steps} eq 'ARRAY';

        my $needs = $job->{needs};
        $needs = [] unless defined $needs;
        $needs = [$needs] unless ref $needs eq 'ARRAY';

        my $container = $job->{container};
        if (defined $container && !ref $container) {
            $container = { image => $container };
        }
        croak "Job '$id' container must be a mapping or a string"
            if defined $container && ref $container ne 'HASH';

        my $services = $job->{services} || {};
        croak "Job '$id' services must be a mapping" unless ref $services eq 'HASH';

        my @steps = map { _normalize_step($_, $id) } @{ $job->{steps} };

        push @jobs, {
            %$job,
            id          => $id,
            needs       => [ map { "$_" } @$needs ],
            container   => $container,
            services    => { %$services },
            env         => _mapping($job->{env}, "env of job '$id'"),
            defaults    => _defaults($job->{defaults}, "defaults of job '$id'"),
            strategy    => _mapping($job->{strategy}, "strategy of job '$id'"),
            steps       => \@steps,
        };
    }

    return bless {
        file     => $file,
        name     => defined $data->{name} ? "$data->{name}" : basename($file),
        env      => _mapping($data->{env}, 'workflow env'),
        defaults => _defaults($data->{defaults}, 'workflow defaults'),
        jobs     => \@jobs,
        raw      => $data,
    }, $class;
}

sub file     { return $_[0]->{file} }
sub name     { return $_[0]->{name} }
sub env      { return $_[0]->{env} }
sub defaults { return $_[0]->{defaults} }
sub jobs     { return $_[0]->{jobs} }
sub raw      { return $_[0]->{raw} }

sub job_by_id {
    my ($self, $id) = @_;
    for my $job (@{ $self->{jobs} }) {
        return $job if $job->{id} eq $id;
    }
    return undef;
}

# Expand every job's matrix into concrete job instances.
sub expand_jobs {
    my ($self, %options) = @_;

    my $expression = App::Actions::Expression->new;
    my @instances;

    for my $job (@{ $self->{jobs} }) {
        my $matrix = $job->{strategy}{matrix};
        my $combinations = _expand_matrix($matrix);

        my $total = scalar @$combinations;
        for my $index (0 .. $#$combinations) {
            my $values = $combinations->[$index];
            my $name = _job_display_name($job, $values, $expression);
            my $setup_perl = _find_setup_perl_version($job, $values, $expression);

            push @instances, {
                %$job,
                base_id            => $job->{id},
                matrix             => $values,
                matrix_index       => $index,
                matrix_total       => $total,
                display_name       => $name,
                setup_perl_version => $setup_perl,
            };
        }
    }

    return \@instances;
}

sub runs_on_text {
    my ($self, $runs_on, $matrix) = @_;

    my $expression = App::Actions::Expression->new;
    my $text;
    if (ref $runs_on eq 'ARRAY') {
        $text = join ' ', map { _stringify($_) } @$runs_on;
    } elsif (ref $runs_on) {
        croak "'runs-on' must be a string or a list";
    } else {
        $text = defined $runs_on ? "$runs_on" : '';
    }

    return $expression->interpolate($text, { matrix => $matrix || {} });
}

sub is_linux_runner {
    my ($self, $runs_on) = @_;
    return 0 if $runs_on =~ /\b(?:windows|macos|darwin)\b/i;
    return 1;
}

sub default_image_for_runner {
    my ($self, $runs_on, $fallback) = @_;

    if ($runs_on =~ /\bubuntu-(\d+\.\d+)\b/i) {
        return "ubuntu:$1";
    }
    if ($runs_on =~ /\bubuntu-latest\b/i) {
        return 'ubuntu:latest';
    }

    return $fallback;
}

sub perl_image_for_version {
    my ($self, $version, $template) = @_;

    $template = 'perl:%s' unless defined $template && length $template;
    $version = 'latest' unless defined $version && length $version;
    $version =~ s/^v//i;
    $version = 'latest' if $version eq 'dev';

    return $template =~ /%s/ ? sprintf($template, $version) : "$template:$version";
}

sub container_image {
    my ($self, $job, $runs_on, $fallback, $perl_template) = @_;

    if (ref $job->{container} eq 'HASH' && defined $job->{container}{image}) {
        my $expression = App::Actions::Expression->new;
        return $expression->interpolate(
            $job->{container}{image},
            { matrix => $job->{matrix} || {} },
        );
    }

    if (defined $job->{setup_perl_version} && length $job->{setup_perl_version}) {
        return $self->perl_image_for_version($job->{setup_perl_version}, $perl_template);
    }

    return $self->default_image_for_runner($runs_on, $fallback);
}

sub _normalize_step {
    my ($step, $job_id) = @_;

    croak "A step in job '$job_id' is not a mapping" unless ref $step eq 'HASH';

    my %copy = %$step;
    $copy{env}  = _mapping($copy{env},  "env of a step in job '$job_id'");
    $copy{with} = _mapping($copy{with}, "with of a step in job '$job_id'");

    for my $field (qw(run uses shell working-directory name)) {
        croak "Step field '$field' in job '$job_id' must be a string"
            if defined $copy{$field} && ref $copy{$field};
    }

    croak "A step in job '$job_id' has neither 'run' nor 'uses'"
        unless defined $copy{run} || defined $copy{uses};

    return \%copy;
}

sub _mapping {
    my ($value, $description) = @_;

    return {} unless defined $value;
    croak "$description must be a mapping" unless ref $value eq 'HASH';
    return { %$value };
}

sub _defaults {
    my ($value, $description) = @_;

    return {} unless defined $value;
    croak "$description must be a mapping" unless ref $value eq 'HASH';

    my %copy = %$value;
    if (defined $copy{run}) {
        croak "$description run must be a mapping" unless ref $copy{run} eq 'HASH';
        $copy{run} = { %{ $copy{run} } };
    }

    return \%copy;
}

sub _expand_matrix {
    my ($matrix) = @_;

    return [ {} ] unless defined $matrix;
    croak 'strategy.matrix must be a mapping' unless ref $matrix eq 'HASH';

    my @keys = sort grep { $_ ne 'include' && $_ ne 'exclude' } keys %$matrix;

    my $includes = $matrix->{include} || [];
    $includes = [$includes] unless ref $includes eq 'ARRAY';
    my $excludes = $matrix->{exclude} || [];
    $excludes = [$excludes] unless ref $excludes eq 'ARRAY';

    # A matrix consisting only of include entries yields one combination per
    # include entry, as on GitHub.
    if (!@keys) {
        my @combinations = map { +{ %$_ } } grep { ref $_ eq 'HASH' } @$includes;
        return @combinations ? \@combinations : [ {} ];
    }

    my @combinations = ({});
    for my $key (@keys) {
        my $values = $matrix->{$key};
        $values = [$values] unless ref $values eq 'ARRAY';
        croak "Matrix key '$key' must be a list" unless @$values;

        my @expanded;
        for my $combination (@combinations) {
            for my $value (@$values) {
                push @expanded, { %$combination, $key => $value };
            }
        }
        @combinations = @expanded;
    }

    for my $exclude (@$excludes) {
        croak 'Each matrix exclude entry must be a mapping' unless ref $exclude eq 'HASH';
        @combinations = grep { !_matches($_, $exclude) } @combinations;
    }

    my %original = map { $_ => 1 } @keys;
    my @extra;
    for my $include (@$includes) {
        croak 'Each matrix include entry must be a mapping' unless ref $include eq 'HASH';
        my $added = 0;

        for my $combination (@combinations) {
            my $compatible = 1;
            for my $key (keys %$include) {
                if ($original{$key}
                    && !_scalar_equal($combination->{$key}, $include->{$key})) {
                    $compatible = 0;
                    last;
                }
            }

            if ($compatible) {
                for my $key (keys %$include) {
                    $combination->{$key} = $include->{$key};
                }
                $added = 1;
            }
        }

        push @extra, { %$include } unless $added;
    }
    push @combinations, @extra;

    return \@combinations;
}

sub _matches {
    my ($combination, $filter) = @_;

    for my $key (keys %$filter) {
        return 0 unless exists $combination->{$key};
        return 0 unless _scalar_equal($combination->{$key}, $filter->{$key});
    }

    return 1;
}

sub _scalar_equal {
    my ($left, $right) = @_;

    return 1 if !defined $left && !defined $right;
    return 0 if !defined $left || !defined $right;

    if (ref $left || ref $right) {
        my $json = JSON::PP->new->canonical;
        return $json->encode($left) eq $json->encode($right) ? 1 : 0;
    }

    return "$left" eq "$right" ? 1 : 0;
}

sub _job_display_name {
    my ($job, $matrix, $expression) = @_;

    if (defined $job->{name} && !ref $job->{name}) {
        return $expression->interpolate($job->{name}, { matrix => $matrix });
    }

    my @parts = map { "$_=" . _stringify($matrix->{$_}) } sort keys %$matrix;
    return $job->{id} unless @parts;
    return $job->{id} . ' (' . join(', ', @parts) . ')';
}

sub _find_setup_perl_version {
    my ($job, $matrix, $expression) = @_;

    for my $step (@{ $job->{steps} || [] }) {
        next unless defined $step->{uses};
        next unless $step->{uses} =~ m{^(?:shogo82148/actions-setup-perl|perl-actions/setup-perl)@}i;

        my $version = $step->{with}{'perl-version'};
        return undef unless defined $version;
        return $expression->interpolate($version, { matrix => $matrix });
    }

    return undef;
}

sub _stringify {
    my ($value) = @_;

    return '' unless defined $value;
    return "$value" unless ref $value;
    return JSON::PP->new->canonical->encode($value);
}

1;

__END__

=head1 NAME

App::Actions::Workflow - parse and expand a GitHub Actions workflow

=head1 SYNOPSIS

    use App::Actions::Workflow;

    my $workflow = App::Actions::Workflow->load(
        '.github/workflows/perl-ci.yml'
    );
    my $jobs = $workflow->expand_jobs;

=head1 DESCRIPTION

This module reads a GitHub Actions workflow file and turns it into a set of
concrete jobs.  Matrix expansion, C<include>/C<exclude> handling, job display
names, and the choice of a container image are handled here.

=head1 METHODS

=head2 load

    my $workflow = App::Actions::Workflow->load($path);

Parses a workflow file.  Malformed workflows raise an exception.

=head2 jobs

    my $jobs = $workflow->jobs;

Returns the job definitions in the order in which they appear in the file.

=head2 expand_jobs

    my $instances = $workflow->expand_jobs;

Returns one hash reference per matrix combination.  Each instance contains
C<matrix>, C<matrix_index>, C<matrix_total>, C<display_name>,
C<setup_perl_version>, and C<base_id> in addition to the normal job fields.

=head2 container_image

    my $image = $workflow->container_image(
        $job, $runs_on, $fallback_image, $perl_image_template
    );

Chooses the Docker image for a job.  C<container.image> wins, then a
C<shogo82148/actions-setup-perl> step, then the image implied by C<runs-on>.

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
