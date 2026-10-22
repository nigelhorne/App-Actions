package App::Actions::Expression;

use strict;
use warnings;
use Carp qw(croak);
use JSON::PP ();
use Readonly;
use Scalar::Util qw(looks_like_number);

use App::Actions::Util ();

# The tokenizer matches each token where the previous one ended (\G with
# pos), rather than against substr($text, $pos), which copies the rest of the
# expression for every token and so is quadratic in its length.

# A number literal: 12, 1.5, 1., .5, and any of those with an exponent.
Readonly::Scalar my $NUMBER => qr/
	\G
	(
		(?: \d++ (?: \. \d*+ )?    # 12, 1.5 or 1.
		  | \. \d++               # .5
		)
		(?: [eE] [+-]? \d++ )?     # an exponent
	)
/x;

# An identifier: a letter or underscore, then letters, digits, _ and -.
Readonly::Scalar my $IDENTIFIER => qr/\G([A-Za-z_][A-Za-z0-9_-]*+)/;

our $VERSION = '0.01';

sub new {
    my ($class) = @_;

    return bless {
        json    => JSON::PP->new->canonical,
        context => {},
        status  => {},
    }, $class;
}

# Evaluate a single GitHub Actions expression, e.g. "matrix.perl == '5.38'".
sub evaluate {
    my ($self, $expression, $context, $status) = @_;

    croak 'Cannot evaluate an undefined expression' unless defined $expression;
    my $text = "$expression";
    croak 'Cannot evaluate an empty expression' if $text =~ /^\s*$/;

    $self->{context} = $context || {};
    $self->{status}  = $status  || {};
    $self->{tokens}  = $self->_tokenize($text);
    $self->{pos}     = 0;
    # Whether a lookup found nothing, which strict interpolation turns into an
    # error.  An existing value that happens to be empty is not a miss.
    $self->{unresolved} = 0;

    my $value = $self->_parse_expression;
    my $token = $self->_peek;
    croak "Unexpected '$token->{value}' in expression '$text'" if $token->{type} ne 'eof';

    return $value;
}

# Replace every ${{ ... }} in a string.
sub interpolate {
    my ($self, $text, $context, $status) = @_;

    return $text unless defined $text;
    return $text if ref $text;

    my $out   = "$text";
    my $start = 0;

    while (1) {
        my $open = index($out, '${{', $start);
        last if $open < 0;

        my $close = index($out, '}}', $open + 3);
        croak "Unclosed expression in '$text'" if $close < 0;

        my $expression = substr($out, $open + 3, $close - $open - 3);
        my $value      = $self->evaluate($expression, $context, $status);

        if ($self->{strict} && $self->{unresolved}) {
            my $written = App::Actions::Util::trim($expression);
            croak "unable to resolve '\${{ $written }}' from the values available";
        }

        my $replacement = _stringify($value);

        substr($out, $open, $close + 2 - $open, $replacement);
        $start = $open + length($replacement);
    }

    return $out;
}

# Replace every ${{ ... }}, but treat a value that could not be found as an
# error rather than as an empty string.  This is for callers where an empty
# result would be a wrong value rather than a legitimate one, such as an
# image name assembled from values that do not exist yet.
sub interpolate_strict {
    my ($self, $text, $context, $status) = @_;

    local $self->{strict} = 1;

    return $self->interpolate($text, $context, $status);
}

# Replace the ${{ ... }} this context can resolve and leave the others as they
# were written.  A caller that knows some of the values now and the rest later
# can resolve twice, without having to guess whether an empty string means
# "empty" or "not known here".
sub interpolate_known {
    my ($self, $text, $context, $status) = @_;

    return $text unless defined $text;
    return $text if ref $text;

    my $out   = "$text";
    my $start = 0;

    while (1) {
        my $open = index($out, '${{', $start);
        last if $open < 0;

        my $close = index($out, '}}', $open + 3);
        croak "Unclosed expression in '$text'" if $close < 0;

        my $expression = substr($out, $open + 3, $close - $open - 3);
        my $value      = $self->evaluate($expression, $context, $status);

        if ($self->{unresolved}) {
            # Step over the expression, which stays in the text.
            $start = $close + 2;
            next;
        }

        my $replacement = _stringify($value);

        substr($out, $open, $close + 2 - $open, $replacement);
        $start = $open + length($replacement);
    }

    return $out;
}

# Evaluate an "if:" value.
sub condition {
    my ($self, $condition, $context, $status) = @_;

    return 1 unless defined $condition;
    return $condition ? 1 : 0 if ref $condition;

    my $text = "$condition";
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;
    return 1 if $text eq '';

    if ($text =~ /^\$\{\{(.*)\}\}$/s) {
        $text = $1;
        $text =~ s/^\s+//;
        $text =~ s/\s+$//;
    }

    return _truthy($self->evaluate($text, $context, $status));
}

sub _tokenize {
    my (undef, $text) = @_;

    my @tokens;
    my $length = length($text);
    my $pos = 0;

    while ($pos < $length) {
        my $char = substr($text, $pos, 1);

        if ($char =~ /\s/) {
            $pos++;
            next;
        }

        if ($char eq q{'}) {
            my $value = '';
            $pos++;
            my $closed = 0;
            while ($pos < $length) {
                my $c = substr($text, $pos, 1);
                if ($c eq q{'}) {
                    if (substr($text, $pos + 1, 1) eq q{'}) {
                        $value .= q{'};
                        $pos += 2;
                        next;
                    }
                    $pos++;
                    $closed = 1;
                    last;
                }
                $value .= $c;
                $pos++;
            }
            croak "Unterminated string in expression '$text'" unless $closed;
            push @tokens, { type => 'str', value => $value };
            next;
        }

        pos($text) = $pos;
        if ($text =~ /$NUMBER/gc) {
            my $number = $1;
            push @tokens, { type => 'num', value => $number + 0 };
            $pos += length($number);
            next;
        }

        pos($text) = $pos;
        if ($text =~ /$IDENTIFIER/gc) {
            my $identifier = $1;
            push @tokens, { type => 'ident', value => $identifier };
            $pos += length($identifier);
            next;
        }

        my $two = substr($text, $pos, 2);
        if ($two eq '==' || $two eq '!=' || $two eq '<=' || $two eq '>='
            || $two eq '&&' || $two eq '||') {
            push @tokens, { type => 'op', value => $two };
            $pos += 2;
            next;
        }

        if ($char eq '!' || $char eq '<' || $char eq '>') {
            push @tokens, { type => 'op', value => $char };
            $pos++;
            next;
        }

        if ($char eq '(' || $char eq ')' || $char eq '[' || $char eq ']'
            || $char eq '.' || $char eq ',') {
            push @tokens, { type => 'punct', value => $char };
            $pos++;
            next;
        }

        croak "Unexpected character '$char' in expression '$text'";
    }

    push @tokens, { type => 'eof', value => '' };

    return \@tokens;
}

sub _peek {
    my ($self) = @_;
    return $self->{tokens}[ $self->{pos} ];
}

sub _next {
    my ($self) = @_;
    my $token = $self->{tokens}[ $self->{pos} ];
    $self->{pos}++ if $token->{type} ne 'eof';
    return $token;
}

sub _peek_value {
    my ($self) = @_;
    return $self->_peek->{value};
}

sub _expect {
    my ($self, $value) = @_;
    my $token = $self->_next;
    croak "Expected '$value' in expression" unless $token->{value} eq $value;
    return $token;
}

sub _parse_expression {
    my ($self) = @_;
    return $self->_parse_or;
}

sub _parse_or {
    my ($self) = @_;

    my $left = $self->_parse_and;
    while ($self->_peek_value eq '||') {
        $self->_next;
        my $right = $self->_parse_and;
        $left = _truthy($left) ? $left : $right;
    }

    return $left;
}

sub _parse_and {
    my ($self) = @_;

    my $left = $self->_parse_equality;
    while ($self->_peek_value eq '&&') {
        $self->_next;
        my $right = $self->_parse_equality;
        $left = _truthy($left) ? $right : $left;
    }

    return $left;
}

sub _parse_equality {
    my ($self) = @_;

    my $left = $self->_parse_relational;
    while (my $operator = $self->_peek_value) {
        last unless $operator eq '==' || $operator eq '!=';
        $self->_next;
        my $right = $self->_parse_relational;
        my $equal = _equal($left, $right);
        $left = $operator eq '==' ? $equal : !$equal;
    }

    return $left;
}

sub _parse_relational {
    my ($self) = @_;

    my $left = $self->_parse_unary;
    while (my $operator = $self->_peek_value) {
        last unless $operator eq '<' || $operator eq '<=' || $operator eq '>'
            || $operator eq '>=';
        $self->_next;
        my $right = $self->_parse_unary;
        my $comparison = _compare($left, $right);
        $left = $operator eq '<'  ? $comparison < 0
              : $operator eq '<=' ? $comparison <= 0
              : $operator eq '>'  ? $comparison > 0
              :                     $comparison >= 0;
    }

    return $left;
}

sub _parse_unary {
    my ($self) = @_;

    # "!" binds tighter than any operator, and may be repeated.
    my $negated = $self->_peek_value eq '!';
    $self->_next if $negated;

    return $negated ? (_truthy($self->_parse_unary) ? 0 : 1) : $self->_parse_primary;
}

sub _parse_primary {
    my ($self) = @_;

    my $token = $self->_peek;

    if ($token->{type} eq 'eof') {
        croak 'Unexpected end of expression';
    }

    if ($token->{type} eq 'num') {
        $self->_next;
        return $self->_postfix($token->{value});
    }

    if ($token->{type} eq 'str') {
        $self->_next;
        return $self->_postfix($token->{value});
    }

    if ($token->{value} eq '(') {
        $self->_next;
        my $value = $self->_parse_expression;
        $self->_expect(')');
        return $self->_postfix($value);
    }

    if ($token->{type} eq 'ident') {
        my $name = $token->{value};
        $self->_next;

        my $lower = lc $name;
        if ($lower eq 'true') {
            return $self->_postfix(1);
        }
        if ($lower eq 'false') {
            return $self->_postfix(0);
        }
        if ($lower eq 'null') {
            return $self->_postfix(undef);
        }

        if ($self->_peek_value eq '(') {
            $self->_next;
            my @args;
            if ($self->_peek_value ne ')') {
                push @args, $self->_parse_expression;
                while ($self->_peek_value eq ',') {
                    $self->_next;
                    push @args, $self->_parse_expression;
                }
            }
            $self->_expect(')');
            return $self->_postfix($self->_call_function($name, \@args));
        }

        return $self->_postfix($self->_lookup($self->{context}, $name));
    }

    croak "Unexpected '$token->{value}' in expression";
}

sub _postfix {
    my ($self, $value) = @_;

    while (1) {
        if ($self->_peek_value eq '.') {
            $self->_next;
            my $key = $self->_next;
            croak 'Expected a property name after dot' unless $key->{type} eq 'ident';
            $value = $self->_lookup($value, $key->{value});
            next;
        }

        if ($self->_peek_value eq '[') {
            $self->_next;
            my $index = $self->_parse_expression;
            $self->_expect(']');
            $value = $self->_lookup($value, $index);
            next;
        }

        last;
    }

    return $value;
}

sub _lookup {
    my ($self, $object, $key) = @_;

    return $self->_missing unless defined $object && defined $key;
    return $self->_missing if ref $key;

    if (ref $object eq 'HASH') {
        return $object->{$key} if exists $object->{$key};
        my $lower = lc $key;
        for my $name (keys %$object) {
            return $object->{$name} if lc $name eq $lower;
        }
        return $self->_missing;
    }

    if (ref $object eq 'ARRAY') {
        return $self->_missing unless $key =~ /\A-?\d+\z/;
        return $object->[$key];
    }

    return $self->_missing;
}

# A lookup found nothing.  The value is still undef, as before; strict
# interpolation is the only caller that cares.
sub _missing {
    my ($self) = @_;

    $self->{unresolved} = 1;

    return undef;
}

sub _call_function {
    my ($self, $name, $args) = @_;

    my $function = lc $name;

    return $self->{status}{success} ? 1 : 0   if $function eq 'success';
    return $self->{status}{failure} ? 1 : 0   if $function eq 'failure';
    return 1                                  if $function eq 'always';
    return $self->{status}{cancelled} ? 1 : 0 if $function eq 'cancelled';

    if ($function eq 'contains') {
        croak 'contains() expects two arguments' unless @$args == 2;
        my ($search, $item) = @$args;
        if (ref $search eq 'ARRAY') {
            for my $candidate (@$search) {
                return 1 if _equal($candidate, $item);
            }
            return 0;
        }
        return index(lc(_stringify($search)), lc(_stringify($item))) >= 0 ? 1 : 0;
    }

    if ($function eq 'startswith' || $function eq 'endswith') {
        croak "$name() expects two arguments" unless @$args == 2;
        my ($haystack, $needle) = map { lc _stringify($_) } @$args;
        return $function eq 'startswith'
            ? (index($haystack, $needle) == 0 ? 1 : 0)
            : (length($needle) <= length($haystack)
                && substr($haystack, -length($needle)) eq $needle ? 1 : 0);
    }

    if ($function eq 'format') {
        croak 'format() expects at least one argument' unless @$args;
        my $format = _stringify(shift @$args);
        $format =~ s/\{\{/\x00/g;
        $format =~ s/\}\}/\x01/g;
        $format =~ s/\{(\d+)\}/defined $args->[$1] ? _stringify($args->[$1]) : ''/ge;
        $format =~ s/\x00/{/g;
        $format =~ s/\x01/}/g;
        return $format;
    }

    if ($function eq 'join') {
        croak 'join() expects two arguments' unless @$args == 2;
        my ($array, $separator) = @$args;
        croak 'join() first argument must be an array' unless ref $array eq 'ARRAY';
        return join(_stringify($separator), map { _stringify($_) } @$array);
    }

    if ($function eq 'tojson') {
        croak 'toJSON() expects one argument' unless @$args == 1;
        return $self->{json}->encode($args->[0]);
    }

    if ($function eq 'fromjson') {
        croak 'fromJSON() expects one argument' unless @$args == 1;
        my $value = eval { $self->{json}->decode(_stringify($args->[0])) };
        croak "fromJSON() failed: $@" if $@;
        return $value;
    }

    if ($function eq 'hashfiles') {
        croak 'hashFiles() is not supported by local action-run';
    }

    croak "Unknown function '$name()' in expression";
}

sub _truthy {
    my ($value) = @_;

    return 0 unless defined $value;
    # A boolean (JSON::PP's, or a core one from YAML::PP) is its own truth;
    # a JSON::PP false is a reference, so this must come before the ref test.
    return $value ? 1 : 0 if JSON::PP::is_bool($value);
    return 1 if ref $value;
    return 0 if $value eq '';
    return 0 if $value eq '0';
    return 1;
}

sub _equal {
    my ($left, $right) = @_;

    return _compare($left, $right) == 0 ? 1 : 0;
}

sub _compare {
    my ($left, $right) = @_;

    # Numbers compare as numbers; anything else as text, ignoring case.
    return (_is_number($left) && _is_number($right))
        ? $left <=> $right
        : lc(_stringify($left)) cmp lc(_stringify($right));
}

sub _is_number {
    my ($value) = @_;
    # GitHub compares a boolean with a number as 1 or 0, which is what lets
    # "matrix.debug == false" match a matrix value of false.
    return !defined $value ? 0
        : JSON::PP::is_bool($value) ? 1
        : (ref $value || $value eq '') ? 0
        : looks_like_number($value) ? 1
        : 0;
}

# The string a workflow sees for a value: one definition for the whole
# distribution, so a boolean interpolates as true/false here exactly as it is
# shown in a job's display name.
sub _stringify {
    return App::Actions::Util::stringify($_[0]);
}

1;

__END__

=head1 NAME

App::Actions::Expression - evaluate GitHub Actions expressions

=head1 SYNOPSIS

    use App::Actions::Expression;

    my $expression = App::Actions::Expression->new;
    my $value = $expression->evaluate(
        q{matrix.perl == '5.38'},
        { matrix => { perl => '5.38' } },
        { success => 1 },
    );

    my $text = $expression->interpolate(
        'Testing Perl ${{ matrix.perl }}',
        { matrix => { perl => '5.38' } },
    );

=head1 DESCRIPTION

This module implements the subset of the GitHub Actions expression language
that is useful when running workflows locally.  It supports property and
index access, comparisons, logical operators, and the common expression
functions such as C<contains()>, C<startsWith()>, C<format()>, C<toJSON()>,
and C<fromJSON()>.  The status functions C<success()>, C<failure()>,
C<always()>, and C<cancelled()> are supplied by the caller.

=head1 METHODS

=head2 evaluate

    my $value = $expression->evaluate($expression, \%context, \%status);

Evaluates one expression and returns its value.

=head2 interpolate

    my $text = $expression->interpolate($string, \%context, \%status);

Expands every C<${{ ... }}> sequence in a string.

=head2 condition

    my $boolean = $expression->condition($if, \%context, \%status);

Evaluates a workflow C<if:> value.

=head1 LIMITATIONS

C<hashFiles()> is not supported.  Arithmetic is not part of the GitHub Actions
expression language and is not implemented.

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
