package App::Actions::Error;

use strict;
use warnings;
use autodie qw(:all);

use Carp qw(croak);
use Params::Get qw(get_params);
use Params::Validate::Strict qw(validate_strict);
use Readonly;
use Scalar::Util qw(blessed);

# Stringifying the object gives what croak would have printed, so code that
# reads "$@", matches it with a regex or prints it sees no difference; code
# that wants to tell failures apart asks for the code instead.
use overload
	'""' => sub { $_[0]->text },
	bool => sub { 1 },
	fallback => 1;

our $VERSION = '0.01';

# What Carp appends to a message: " at FILE line N.".  It is found in two
# steps, the tail and then the " at " before it, because one pattern that
# does both - \A(.*)\s+at\s+.+?\s+line\s+\d+\.?\z - tries every " at " and
# scans to the end from each, which is quadratic: 40,000 characters of
# "x at f line " took three seconds.  Each step below is linear.
#
# The tail: " line N." at the very end.  It is tried only where a run of
# white space starts, and its quantifiers never give back, so no run of
# spaces is scanned twice.
Readonly::Scalar my $LOCATION_TAIL => qr/
	(?<!\s)        # the start of a run of white space, or of the text
	\s++ line      # " line"
	\s++ \d++      # " N"
	\.?            # Carp's full stop
	\z
/x;

# The message: everything before the last " at " that is followed by a file
# name.  The greedy prefix is what makes it the last, because a message may
# quote a position of its own ("at character offset 9") and a file name may
# contain spaces; ending the prefix at a non-space (or leaving it empty)
# means each run of white space is tried from its start only.
Readonly::Scalar my $LOCATION_HEAD => qr/
	\A
	(.*\S|)        # the message: ends at a non-space, or is empty
	\s+ at \s+     # " at "
	\S             # the start of the file name
/xs;

# A message key is a dotted lower-case name such as workflow.no_jobs.
Readonly::Scalar my $CODE => qr/\A[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+\z/;

=encoding utf-8

=head1 NAME

App::Actions::Error - an exception that carries a stable code

=head1 SYNOPSIS

	use App::Actions::Error;

	my $ok = eval { App::Actions::Workflow->load($file); 1 };
	if (!$ok) {
		my $error = App::Actions::Error->caught($@);
		if ($error && $error->is('workflow.file_missing')) {
			print "No workflow at $error->args->{file}\n";
		}
		print STDERR App::Actions::Error->describe($@), "\n";
	}

=head1 DESCRIPTION

Every message of the catalogue in L<App::Actions::I18N> is thrown as one of
these.  The C<code> is the catalogue key, which does not change when the
message is translated or reworded, so a caller can tell failures apart without
matching text.  The object stringifies to exactly what C<croak> would have
died with - the rendered message and C<" at FILE line N.\n"> - so code written
for string exceptions keeps working.

=head1 METHODS

=head2 new

Creates an exception without throwing it.  Most code never calls this: it
uses C<< $self->throw($key, \%args) >> from L<App::Actions::I18N>, which
renders the message and records where it was thrown from.

=head3 ARGUMENTS

=over 4

=item * C<code> - the catalogue key, such as C<workflow.no_jobs>.

=item * C<message> - the rendered text, without a location.

=item * C<args> - optional; the values the message was rendered with.

=item * C<location> - optional; what follows the message when it is
stringified, normally C<" at FILE line N.\n">.  Defaults to C<"\n">.

=back

=head3 RETURNS

An C<App::Actions::Error> object.

=head3 SIDE EFFECTS

None.

=head3 EXAMPLE

	my $error = App::Actions::Error->new(
		code    => 'workflow.empty',
		message => "Workflow 'ci.yml' is empty",
		args    => { file => 'ci.yml' },
	);
	die $error;

=head3 API SPECIFICATION

=head4 INPUT

	{
		code     => { type => 'string', matches => qr/\A[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+\z/ },
		message  => { type => 'string' },
		args     => { type => 'hashref', optional => 1 },
		location => { type => 'string', optional => 1 },
	}

=head4 OUTPUT

	{ type => 'object', isa => 'App::Actions::Error' }

=head3 MESSAGES

	+---------------------------+------------------------------+-----------------------------+
	| Message                   | Meaning                      | Resolution                  |
	+---------------------------+------------------------------+-----------------------------+
	| Invalid arguments to      | A required argument is       | Pass a dotted code and a    |
	| App::Actions::Error::new  | missing or has the wrong type| message string              |
	+---------------------------+------------------------------+-----------------------------+

=head3 FORMAL SPECIFICATION

	┌─ NewError ────────────────────────────────────────
	│ code?     : KEY
	│ message?  : seq CHAR
	│ args?     : optional (NAME ⇸ VALUE)
	│ location? : optional seq CHAR
	│ e!        : Error
	├───────────────────────────────────────────────────
	│ e!.code = code? ∧ e!.message = message?
	│ e!.args = (if args? = ⊥ then ∅ else args?)
	│ e!.location = (if location? = ⊥ then "\n" else location?)
	│ text(e!) = e!.message ⁀ e!.location
	└───────────────────────────────────────────────────

=cut

sub new {
	my $class = shift;

	# The validator is called directly rather than through
	# App::Actions::I18N::validate_args, because that module throws these
	# objects and so loads this one first.
	my $params = eval {
		validate_strict({
			args => get_params(undef, @_),
			schema => {
				code => { type => 'string', matches => $CODE },
				message => { type => 'string' },
				args => { type => 'hashref', optional => 1 },
				location => { type => 'string', optional => 1 },
			},
		});
	};
	if (!$params) {
		(my $reason = $@) =~ s/\s+\z//;
		croak("Invalid arguments to ${class}::new: $reason");
	}

	return bless {
		code => $params->{code},
		message => $params->{message},
		args => { %{ $params->{args} || {} } },
		location => defined $params->{location} ? $params->{location} : "\n",
	}, $class;
}

=head2 code

Returns the catalogue key the exception was raised with.

=head3 EXAMPLE

	print $error->code;    # workflow.file_missing

=head3 API SPECIFICATION

=head4 INPUT

	{}

=head4 OUTPUT

	{ type => 'string' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ Code ────────────────────────────────────────────
	│ ΞError
	│ code! : KEY
	├───────────────────────────────────────────────────
	│ code! = θError.code
	└───────────────────────────────────────────────────

=cut

sub code { return $_[0]->{code} }

=head2 message

Returns the rendered message without the location, as a person would want to
read it.

=head3 EXAMPLE

	print STDERR 'action-run: ', $error->message, "\n";

=head3 API SPECIFICATION

=head4 INPUT

	{}

=head4 OUTPUT

	{ type => 'string' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ Message ─────────────────────────────────────────
	│ ΞError
	│ message! : seq CHAR
	├───────────────────────────────────────────────────
	│ message! = θError.message
	└───────────────────────────────────────────────────

=cut

sub message { return $_[0]->{message} }

=head2 args

Returns a copy of the values the message was rendered with, so a caller can
act on the file, job or image the failure is about.

=head3 EXAMPLE

	my $file = $error->args->{file};

=head3 API SPECIFICATION

=head4 INPUT

	{}

=head4 OUTPUT

	{ type => 'hashref' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ Args ────────────────────────────────────────────
	│ ΞError
	│ args! : NAME ⇸ VALUE
	├───────────────────────────────────────────────────
	│ args! = θError.args
	└───────────────────────────────────────────────────

=cut

sub args { return { %{ $_[0]->{args} } } }

=head2 location

Returns what follows the message when it is stringified: C<" at FILE line
N.\n">, a stack trace for an exception raised with C<< trace => 1 >>, or
C<"\n"> for one that names no place in the code.

=head3 EXAMPLE

	warn 'raised', $error->location;

=head3 API SPECIFICATION

=head4 INPUT

	{}

=head4 OUTPUT

	{ type => 'string' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ Location ────────────────────────────────────────
	│ ΞError
	│ location! : seq CHAR
	├───────────────────────────────────────────────────
	│ location! = θError.location
	└───────────────────────────────────────────────────

=cut

sub location { return $_[0]->{location} }

=head2 text

Returns the message followed by the location: what the object stringifies
to, and what C<croak> would have died with.

=head3 EXAMPLE

	is("$error", $error->text, 'stringification is the text');

=head3 API SPECIFICATION

=head4 INPUT

	{}

=head4 OUTPUT

	{ type => 'string' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ Text ────────────────────────────────────────────
	│ ΞError
	│ text! : seq CHAR
	├───────────────────────────────────────────────────
	│ text! = θError.message ⁀ θError.location
	└───────────────────────────────────────────────────

=cut

sub text { return $_[0]->{message} . $_[0]->{location} }

=head2 is

Says whether the exception has a code, or belongs to a family of codes.

=head3 ARGUMENTS

=over 4

=item * C<$code> - a full code (C<workflow.no_jobs>), or a prefix ending in a
dot (C<workflow.>) for every code that starts with it.

=back

=head3 RETURNS

1 or 0.

=head3 EXAMPLE

	if ($error->is('runner.image.')) { ... }    # any image failure

=head3 API SPECIFICATION

=head4 INPUT

	{ code => { type => 'string', min => 1 } }

=head4 OUTPUT

	{ type => 'boolean' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ Is ──────────────────────────────────────────────
	│ ΞError
	│ code? : seq CHAR
	│ r!    : 𝔹
	├───────────────────────────────────────────────────
	│ last(code?) = '.' ⇒ (r! ⇔ code? prefix θError.code)
	│ last(code?) ≠ '.' ⇒ (r! ⇔ code? = θError.code)
	└───────────────────────────────────────────────────

=cut

sub is {
	my ($self, $code) = @_;

	my $mine = $self->{code};

	# A trailing dot names a family, so a caller can handle every image
	# failure without listing their codes.
	return ($code =~ /\.\z/ ? index($mine, $code) == 0 : $mine eq $code) ? 1 : 0;
}

=head2 caught

	my $error = App::Actions::Error->caught($@);

Returns the value if it is an C<App::Actions::Error> (or a subclass of the
class it is called on), and C<undef> otherwise, so a caller can ask for the
code without first checking what kind of value C<$@> holds.

=head3 EXAMPLE

	if (my $error = App::Actions::Error->caught($@)) {
		exit 70 if $error->is('schema.invalid');
	}

=head3 API SPECIFICATION

=head4 INPUT

	{ error => { type => 'any', optional => 1 } }

=head4 OUTPUT

	{ type => 'object', isa => 'App::Actions::Error', optional => 1 }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ Caught ──────────────────────────────────────────
	│ class? : CLASS
	│ value? : VALUE
	│ e!     : optional Error
	├───────────────────────────────────────────────────
	│ value? ∈ class? ⇒ e! = value?
	│ value? ∉ class? ⇒ e! = ⊥
	└───────────────────────────────────────────────────

=cut

sub caught {
	my ($class, $error) = @_;

	return (blessed($error) && $error->isa($class)) ? $error : undef;
}

=head2 describe

	print STDERR 'action-run: ', App::Actions::Error->describe($@), "\n";

Returns any exception as a sentence for a person: the message of an
C<App::Actions::Error>, or a string exception with its final
C<" at FILE line N."> and trailing white space removed.  A position the
message gives of its own, such as JSON::PP's C<at character offset 9>, is
kept, because it is part of the diagnosis.

=head3 ARGUMENTS

=over 4

=item * C<$error> - an exception: an object or a string.  C<undef> gives
the empty string.

=back

=head3 RETURNS

A string.

=head3 EXAMPLE

	App::Actions::Error->describe("No job matched 'x' at lib/App/Actions.pm line 9.\n");
	# No job matched 'x'

=head3 API SPECIFICATION

=head4 INPUT

	{ error => { type => 'any', optional => 1 } }

=head4 OUTPUT

	{ type => 'string' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ Describe ────────────────────────────────────────
	│ error? : VALUE
	│ s!     : seq CHAR
	├───────────────────────────────────────────────────
	│ error? ∈ Error ⇒ s! = rtrim(error?.message)
	│ error? = ⊥ ⇒ s! = ⟨⟩
	│ otherwise s! = rtrim(stripLocation(rtrim(error?)))
	└───────────────────────────────────────────────────

=cut

sub describe {
	my ($class, $error) = @_;

	# An exception of this kind knows its message apart from its location;
	# anything else is a string and has the location cut off.
	my $text = !defined $error ? ''
		: $class->caught($error) ? $error->message
		: "$error";
	$text =~ s/\s+\z//;
	if ($text =~ $LOCATION_TAIL) {
		my $before = substr($text, 0, $-[0]);
		$text = $1 if $before =~ $LOCATION_HEAD;
	}
	$text =~ s/\s+\z//;

	return $text;
}

1;

__END__

=head1 LIMITATIONS

=over 4

=item * Only messages raised through the catalogue are objects.  Errors from
Perl itself, from CPAN modules and from code that still calls C<croak> with a
literal are strings; L</describe> and L</caught> accept both so a caller does
not have to know which it was given.

=item * The code is the catalogue key, so renaming a key is an interface
change.  The keys are listed in the language modules under
L<App::Actions::I18N>.

=item * The arguments are copied when the exception is made, but values in
them that are references are shared with the code that threw it.

=back

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
