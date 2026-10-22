package App::Actions::Schema;

use strict;
use warnings;
use Exporter qw(import);
use JSON::PP ();

use App::Actions::Error;

our $VERSION = '0.01';

our @EXPORT_OK = qw(validate assert_valid describe_errors);

# A small JSON Schema subset: type, const, enum, properties, required, items
# and oneOf.  An object whose schema names properties also rejects keys the
# schema does not name, which is what keeps a key from slipping into a document
# without the schema gaining it too.
#
# It is deliberately smaller than JSON Schema.  The documents validated with it
# are this distribution's own, so every keyword here is one that is used, and a
# document that a full validator would reject for some other reason is a
# document this distribution does not print.
#
# Returns the list of errors, in document order, or an empty list when the
# value matches.  Callers that should stop on a mismatch use assert_valid.
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

# Stop when a document does not match the schema it claims to.  $what is the
# sentence's subject, such as "the action-run check --json document does not
# match App::Actions::Check->json_schema"; the first mismatch is appended, with
# a count of any others, so the message stays one readable line however far the
# document has drifted.
sub assert_valid {
    my ($value, $schema, $what) = @_;

    my @errors = validate($value, $schema);
    return 1 unless @errors;

    # An exception rather than a string: a command can tell a broken document
    # from every other way of failing, and give it the status that says so.
    # The message still carries no source location, because it reports a
    # document rather than a place in the code.
    die App::Actions::Schema::Invalid->new("$what: " . describe_errors(\@errors) . "\n");
}

# The first mismatch, with a count of the others, so a message stays one
# readable line however far a document has drifted.  Shared by assert_valid
# and "action-run validate", which report the same errors the same way.
sub describe_errors {
    my ($errors) = @_;

    my $more = @$errors > 1 ? sprintf(' (and %d more)', @$errors - 1) : '';

    return @$errors ? "$errors->[0]$more" : '';
}

# The exit status a command gives when a document of its own does not match
# the schema it ships.  EX_SOFTWARE from sysexits.h: the drift is a fault in
# this distribution, not in the environment or the workflow, so a caller that
# reads 2 as "the host needs fixing" does not mistake it for one.
sub invalid_exit { return 70 }

package App::Actions::Schema::Invalid;

# An App::Actions::Error with the code schema.invalid, so a caller can ask
# either "is it an Invalid?" or "is it the error schema.invalid?".  It reports
# a document rather than a place in the code, so it has no location, and the
# message is the whole text, which keeps message and stringification equal.
use parent -norequire, 'App::Actions::Error';

sub new {
    my ($class, $message) = @_;

    return $class->SUPER::new(code => 'schema.invalid', message => $message, location => '');
}

package App::Actions::Schema;

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

    # Two nulls are the same; a null and a value, or anything structured, are
    # not; two scalars are compared as strings, as JSON compares them.
    return (!defined $one && !defined $other) ? 1
        : (!defined $one || !defined $other || ref $one || ref $other) ? 0
        : $one eq $other ? 1
        : 0;
}

# How a value is shown in a message: a string is quoted, a number and a JSON
# boolean are shown as the document would write them, and anything else is
# named by its kind rather than dumped.
sub _show {
    my ($value) = @_;

    # A value as the JSON document spells it: a number bare, a string quoted.
    return !defined $value ? 'null'
        : JSON::PP::is_bool($value) ? ($value ? 'true' : 'false')
        : ref $value ? ref $value
        : $value =~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?\z/ ? $value
        : "'$value'";
}

1;

__END__

=head1 NAME

App::Actions::Schema - the JSON schema check behind App::Actions' own documents

=head1 SYNOPSIS

    use App::Actions::Schema;

    my @errors = App::Actions::Schema::validate($document, $schema);
    App::Actions::Schema::assert_valid($document, $schema, $sentence);

=head1 DESCRIPTION

The machine-readable documents that C<action-run check --json> and
C<action-run preflight --json> print are described by schemas that ship with
the modules that produce them, so that a CI job can fetch the contract with
C<action-run schema>.  This module is the validator those commands use to hold
their own output to it: a key that is added, removed or retyped without the
schema changing stops the document at the point it is built, rather than in
the assertion of whoever reads it.

The supported keywords are C<type>, C<const>, C<enum>, C<properties>,
C<required>, C<items> and C<oneOf>, which is the whole of the subset the
shipped schemas use.  An object whose schema names C<properties> also rejects
keys the schema does not name.

=head1 FUNCTIONS

=head2 validate

    my @errors = App::Actions::Schema::validate($value, $schema);

Returns the mismatches between C<$value> and C<$schema>, each a sentence naming
the path in the document that is at fault, in document order.  An empty list
means the value matches, which is also what an array returns in list context
with no errors in it.

=head2 assert_valid

    App::Actions::Schema::assert_valid($value, $schema, $what);

Returns 1 when C<$value> matches C<$schema>, and otherwise dies with C<$what>,
a colon, the first mismatch and a count of the others, followed by a newline.
C<$what> names the whole subject of the sentence, for example C<the action-run
check --json document does not match App::Actions::Check-E<gt>json_schema>.
The exception carries no source location, because it reports a document rather
than a place in the code.  It is a L</App::Actions::Schema::Invalid> object,
not a string, so a caller can tell it from every other failure.

=head2 describe_errors

    my $text = App::Actions::Schema::describe_errors(\@errors);

Returns the first error of the array reference, followed by C<(and N more)>
when there are others, or an empty string for no errors.  This is the
wording L</assert_valid> and C<action-run validate> both use.

=head2 invalid_exit

    my $status = App::Actions::Schema::invalid_exit();

Returns 70, the status a command should exit with after a document of its own
failed validation: C<EX_SOFTWARE> from F<sysexits.h>.  It is deliberately not
2, which the commands use for an environment that needs fixing, so a CI job
can tell a broken document from a host it has to repair.

=head1 EXCEPTIONS

=head2 App::Actions::Schema::Invalid

What L</assert_valid> dies with.  It is an L<App::Actions::Error> whose code
is C<schema.invalid> and whose location is empty, so it stringifies to its
message, newline included, and C<die> and C<warn> read as they did before.  It
offers everything an L<App::Actions::Error> does; in particular:

=over 4

=item C<message>

The same text, without relying on stringification.

=item C<is('schema.invalid')>

True, as for any error with that code.

=back

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
