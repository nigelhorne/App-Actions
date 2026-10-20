package App::Actions::Action;

use strict;
use warnings;
use Carp qw(croak);
use File::Spec;
use JSON::PP ();
use YAML::PP;
use YAML::PP::Common qw(PRESERVE_ORDER);

our $VERSION = '0.01';

# Load an action's metadata from an action.yml or action.yaml in $dir.
sub load_from_dir {
    my ($class, $dir) = @_;

    croak 'No action directory given' unless defined $dir && length $dir;
    croak "Action directory '$dir' does not exist" unless -d $dir;

    for my $name (qw(action.yml action.yaml)) {
        my $file = File::Spec->catfile($dir, $name);
        return $class->load($file) if -f $file;
    }

    croak "No action.yml or action.yaml found in '$dir'";
}

sub load {
    my ($class, $file) = @_;

    croak 'No action metadata file given' unless defined $file && length $file;
    croak "Action metadata file '$file' does not exist" unless -f $file;

    my $yaml = YAML::PP->new(preserve => PRESERVE_ORDER);
    my $data = eval { $yaml->load_file($file) };
    if ($@) {
        my $error = $@;
        $error =~ s/\s+$//;
        croak "Unable to parse action metadata '$file': $error";
    }
    croak "Action metadata '$file' is empty" unless defined $data;
    croak "Action metadata '$file' must contain a YAML mapping"
        unless ref $data eq 'HASH';

    my $runs = $data->{runs};
    croak "Action metadata '$file' has no 'runs' mapping"
        unless ref $runs eq 'HASH';

    my $using = defined $runs->{using} ? lc "$runs->{using}" : '';
    croak "Action metadata '$file' has no 'runs.using'" unless length $using;

    my $kind;
    my $steps = [];

    if ($using eq 'composite') {
        croak "Composite action '$file' has no 'runs.steps' list"
            unless ref $runs->{steps} eq 'ARRAY';
        $kind = 'composite';
        $steps = [ map { _normalize_step($_, $file) } @{ $runs->{steps} } ];
    } elsif ($using =~ /^node\d+$/) {
        croak "JavaScript action '$file' has no 'runs.main'"
            unless defined $runs->{main} && length "$runs->{main}" && !ref $runs->{main};
        $kind = 'javascript';
    } elsif ($using eq 'docker') {
        $kind = 'docker';
    } else {
        $kind = $using;
    }

    my $dir = $file;
    $dir =~ s{[/\\][^/\\]+$}{};

    return bless {
        file        => $file,
        dir         => length $dir ? $dir : '.',
        name        => defined $data->{name} ? "$data->{name}" : '',
        description => defined $data->{description} ? "$data->{description}" : '',
        using       => $using,
        kind        => $kind,
        inputs      => _inputs($data->{inputs}, $file),
        outputs     => _outputs($data->{outputs}, $file),
        runs        => { %$runs },
        steps       => $steps,
    }, $class;
}

sub file        { return $_[0]->{file} }
sub dir         { return $_[0]->{dir} }
sub name        { return $_[0]->{name} }
sub description { return $_[0]->{description} }
sub using       { return $_[0]->{using} }
sub kind        { return $_[0]->{kind} }
sub inputs      { return $_[0]->{inputs} }
sub outputs     { return $_[0]->{outputs} }
sub runs        { return $_[0]->{runs} }
sub steps       { return $_[0]->{steps} }

sub is_composite  { return $_[0]->{kind} eq 'composite' }
sub is_javascript { return $_[0]->{kind} eq 'javascript' }

# Inputs are declared as a mapping of name to { description, required, default }.
sub _inputs {
    my ($inputs, $file) = @_;

    my %declared;
    return \%declared unless defined $inputs;
    croak "The 'inputs' of '$file' must be a mapping" unless ref $inputs eq 'HASH';

    for my $name (keys %$inputs) {
        my $input = $inputs->{$name};
        if (!defined $input) {
            $declared{$name} = { default => '', required => 0 };
            next;
        }
        if (!ref $input) {
            $declared{$name} = { default => "$input", required => 0 };
            next;
        }
        croak "Input '$name' of '$file' must be a mapping" unless ref $input eq 'HASH';
        $declared{$name} = {
            description => defined $input->{description} ? "$input->{description}" : undef,
            required    => _boolean($input->{required}) ? 1 : 0,
            default     => defined $input->{default} ? _stringify($input->{default}) : '',
        };
    }

    return \%declared;
}

sub _outputs {
    my ($outputs, $file) = @_;

    my %declared;
    return \%declared unless defined $outputs;
    croak "The 'outputs' of '$file' must be a mapping" unless ref $outputs eq 'HASH';

    for my $name (keys %$outputs) {
        my $output = $outputs->{$name};
        if (!defined $output) {
            $declared{$name} = { value => '' };
            next;
        }
        if (!ref $output) {
            $declared{$name} = { value => "$output" };
            next;
        }
        croak "Output '$name' of '$file' must be a mapping" unless ref $output eq 'HASH';
        $declared{$name} = {
            description => defined $output->{description} ? "$output->{description}" : undef,
            value       => defined $output->{value} ? _stringify($output->{value}) : '',
        };
    }

    return \%declared;
}

sub _normalize_step {
    my ($step, $file) = @_;

    croak "A step in '$file' is not a mapping" unless ref $step eq 'HASH';

    my %copy = %$step;
    $copy{env}  = _mapping($copy{env},  "env of a step in '$file'");
    $copy{with} = _mapping($copy{with}, "with of a step in '$file'");

    for my $field (qw(run uses shell working-directory name id if)) {
        croak "Step field '$field' in '$file' must be a string"
            if defined $copy{$field} && ref $copy{$field};
    }

    croak "A step in '$file' has neither 'run' nor 'uses'"
        unless defined $copy{run} || defined $copy{uses};

    return \%copy;
}

sub _mapping {
    my ($value, $description) = @_;

    return {} unless defined $value;
    croak "$description must be a mapping" unless ref $value eq 'HASH';
    return { %$value };
}

sub _boolean {
    my ($value) = @_;

    return 0 unless defined $value;
    return 1 if ref $value;
    return 1 if "$value" =~ /^(?:true|yes|1)$/i;
    return 0;
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

App::Actions::Action - read the metadata of a local GitHub action

=head1 SYNOPSIS

    use App::Actions::Action;

    my $action = App::Actions::Action->load_from_dir('path/to/action');
    print $action->kind;  # composite or javascript

=head1 DESCRIPTION

Reads C<action.yml> (or C<action.yaml>) and exposes the action's inputs,
outputs, and C<runs> section.  Composite action steps are normalised in the
same way as workflow steps.

=head1 METHODS

=head2 load_from_dir

    my $action = App::Actions::Action->load_from_dir($directory);

Looks for C<action.yml> then C<action.yaml> in the directory.

=head2 load

    my $action = App::Actions::Action->load($file);

Parses a single metadata file.  Malformed metadata raises an exception.

=head2 kind

Returns C<composite>, C<javascript>, C<docker>, or the raw C<runs.using>
value for anything else.

=head2 inputs, outputs, runs, steps

Return the parsed metadata.  C<steps> is empty unless the action is composite.

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
