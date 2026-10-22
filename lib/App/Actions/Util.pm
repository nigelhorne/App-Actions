package App::Actions::Util;

use strict;
use warnings;
use utf8;
use autodie qw(:all);

use Exporter qw(import);
use JSON::PP ();
use Readonly;
use YAML::PP;
use YAML::PP::Common qw(PRESERVE_ORDER);

use App::Actions::I18N qw(throw validate_args);

use Sub::Private ();

use App::Actions::Access;

our $VERSION = '0.01';

our @EXPORT_OK = qw(load_yaml_mapping mapping normalize_step stringify trim);

# A failure in a helper is the caller's mistake, not the helper's, so Carp
# reports it from the module that asked for the helper (and, through their own
# @CARP_NOT, from that module's caller).
our @CARP_NOT = qw(App::Actions App::Actions::Workflow App::Actions::Action);

# The step fields that must be plain strings when present.  A mapping or a
# list in one of these is a YAML indentation mistake, and catching it here
# gives a message about the step rather than a crash deep inside the run.
Readonly::Array my @STRING_STEP_FIELDS => qw(run uses shell working-directory name id if);

# The step fields that hold mappings of their own and are copied, so a caller
# can change a step's env or with without changing the parsed document.
Readonly::Array my @MAPPING_STEP_FIELDS => qw(env with);

# The kinds of YAML document load_yaml_mapping knows the messages for.  Each
# names the prefix of its keys in the catalogue.
Readonly::Hash my %DOCUMENT_KINDS => (workflow => 1, action => 1);

# One canonical encoder, so equal structures always stringify identically and
# the encoder is not rebuilt for every value.
my $CANONICAL_JSON = JSON::PP->new->canonical;

=encoding utf-8

=head1 NAME

App::Actions::Util - helpers shared by the App::Actions document readers

=head1 SYNOPSIS

	use App::Actions::Util qw(load_yaml_mapping mapping normalize_step stringify trim);

	my $data  = load_yaml_mapping($file, 'workflow');
	my $env   = mapping($data->{env}, ['where.workflow_env']);
	my $step  = normalize_step($raw_step, ['where.job', { job => 'test' }]);
	my $text  = stringify(JSON::PP::true);    # 'true'

=head1 DESCRIPTION

L<App::Actions::Workflow> and L<App::Actions::Action> read two kinds of YAML
document with the same rules: the file must exist, parse, and hold a
mapping; C<env> and C<with> must be mappings; a step must say C<run> or
C<uses>.  Those rules, and the conversion of a YAML value to the string a
workflow sees, used to be written out once per module and had begun to
drift.  They live here once.

These functions are internal to the distribution.  They are public only
because more than one package calls them; their interface may change
between releases.

Where a function can fail it takes a I<place> rather than a sentence: an
array reference of a catalogue key and its arguments, such as
C<< ['where.job_env', { job => 'test' }] >>.  The place is only rendered
when there is an error to report, so the common case costs nothing, and it
is rendered in the language of the run.

=head1 FUNCTIONS

=head2 load_yaml_mapping

Reads a YAML file that must hold a mapping.

=head3 ARGUMENTS

=over 4

=item * C<$file> - the path of the file.

=item * C<$kind> - C<workflow> or C<action>; chooses the wording of the
errors.

=back

=head3 RETURNS

A hash reference of the document, with its keys in file order.

=head3 SIDE EFFECTS

Reads the file.

=head3 EXAMPLE

	my $workflow = load_yaml_mapping('.github/workflows/ci.yml', 'workflow');
	print join(', ', keys %{ $workflow->{jobs} }), "\n";

=head3 API SPECIFICATION

=head4 INPUT

	{
		file => { type => 'string', optional => 1 },
		kind => { type => 'string', memberof => [ 'workflow', 'action' ] },
	}

=head4 OUTPUT

	{ type => 'hashref' }

=head3 MESSAGES

	+--------------------------------+--------------------------------+------------------------------+
	| Message (kind = workflow)      | Meaning                        | Resolution                   |
	+--------------------------------+--------------------------------+------------------------------+
	| No workflow file given         | The path was undef or empty    | Pass a path                  |
	| Workflow file 'F' does not     | No regular file at the path    | Check the path               |
	| exist                          |                                |                              |
	| Unable to parse workflow 'F':  | The YAML is malformed          | Fix the YAML at the position |
	| E                              |                                | E names                      |
	| Workflow 'F' is empty          | The file has no document       | Add the workflow             |
	| Workflow 'F' must contain a    | The document is a list or a    | Make the top level a mapping |
	| YAML mapping                   | scalar                         |                              |
	+--------------------------------+--------------------------------+------------------------------+

The C<action> kind reports the same conditions as C<No action metadata file
given>, C<Action metadata file 'F' does not exist>, C<Unable to parse action
metadata 'F': E>, C<Action metadata 'F' is empty> and C<Action metadata 'F'
must contain a YAML mapping>.

=head3 FORMAL SPECIFICATION

	KIND ::= workflow | action

	┌─ LoadYamlMapping ─────────────────────────────────
	│ ΞFileSystem
	│ file? : optional PATH
	│ kind? : KIND
	│ doc!  : KEY ⇸ VALUE
	├───────────────────────────────────────────────────
	│ file? = ⊥ ∨ file? = ⟨⟩ ⇒ raises FileRequired(kind?)
	│ file? ∉ regularFiles ⇒ raises FileMissing(kind?, file?)
	│ ¬ parses(contents(file?)) ⇒ raises ParseFailed(kind?, file?)
	│ parse(contents(file?)) = ⊥ ⇒ raises Empty(kind?, file?)
	│ parse(contents(file?)) ∉ MAPPING ⇒ raises NotMapping(kind?, file?)
	│ otherwise doc! = parse(contents(file?))
	└───────────────────────────────────────────────────

=head3 PSEUDOCODE

	refuse an unknown kind
	refuse a missing path, then a path that is not a file
	parse the file, keeping key order, and refuse a parse error
	refuse an empty document, then one that is not a mapping
	return the mapping

=cut

sub load_yaml_mapping {
	my $params = validate_args(__PACKAGE__ . '::load_yaml_mapping', \@_, {
		file => { type => 'string', optional => 1 },
		kind => { type => 'string', memberof => [ sort keys %DOCUMENT_KINDS ] },
	}, ['file', 'kind']);
	my ($file, $kind) = @{$params}{qw(file kind)};

	throw(__PACKAGE__, "$kind.file_required") unless defined $file && length $file;
	throw(__PACKAGE__, "$kind.file_missing", { file => $file }) unless -f $file;

	# Key order is preserved because job order and step order are what the
	# user wrote, and a report that reorders them is harder to follow.
	my $data = eval { YAML::PP->new(preserve => PRESERVE_ORDER)->load_file($file) };
	if (my $error = $@) {
		throw(__PACKAGE__, "$kind.parse_failed", { file => $file, error => trim($error) });
	}

	throw(__PACKAGE__, "$kind.empty", { file => $file }) unless defined $data;
	throw(__PACKAGE__, "$kind.not_mapping", { file => $file }) unless ref $data eq 'HASH';

	return $data;
}

=head2 mapping

Returns a shallow copy of a value that must be a mapping, or an empty hash
when it is absent.

=head3 ARGUMENTS

=over 4

=item * C<$value> - the value from the document, possibly undef.

=item * C<$place> - C<[ $key, \%args ]>, the catalogue key that names where
the value came from.

=back

=head3 RETURNS

A new hash reference.

=head3 SIDE EFFECTS

None.

=head3 EXAMPLE

	my $env = mapping($job->{env}, ['where.job_env', { job => 'test' }]);
	$env->{EXTRA} = 1;    # $job->{env} is unchanged

=head3 API SPECIFICATION

=head4 INPUT

	{
		value => { type => 'hashref', optional => 1 },
		place => { type => 'arrayref', min => 1 },
	}

=head4 OUTPUT

	{ type => 'hashref' }

=head3 MESSAGES

	+--------------------------+-------------------------------+--------------------------------+
	| Message                  | Meaning                       | Resolution                     |
	+--------------------------+-------------------------------+--------------------------------+
	| PLACE must be a mapping  | The value is a list or scalar | Indent it as KEY: VALUE pairs  |
	+--------------------------+-------------------------------+--------------------------------+

=head3 FORMAL SPECIFICATION

	┌─ Mapping ─────────────────────────────────────────
	│ value? : optional VALUE
	│ place? : KEY × (NAME ⇸ VALUE)
	│ copy!  : KEY ⇸ VALUE
	├───────────────────────────────────────────────────
	│ value? = ⊥ ⇒ copy! = ∅
	│ value? ∈ MAPPING ⇒ copy! = value? ∧ copy! is a new object
	│ value? ∉ MAPPING ∪ {⊥} ⇒ raises MappingInvalid(place?)
	└───────────────────────────────────────────────────

=cut

sub mapping {
	my ($value, $place) = @_;

	# Not run through validate_args: this is called once per step field on
	# the success path, and the check below is the whole of the contract.
	throw(__PACKAGE__, 'mapping.invalid', { where => _place_text($place) })
		if defined $value && ref $value ne 'HASH';

	return defined $value ? { %{$value} } : {};
}

=head2 normalize_step

Checks one step of a job or a composite action and returns a copy whose
C<env> and C<with> are always hashes.

=head3 ARGUMENTS

=over 4

=item * C<$step> - the step as parsed.

=item * C<$place> - C<[ $key, \%args ]> naming the job or file the step is
in, such as C<< ['where.job', { job => 'test' }] >>.

=back

=head3 RETURNS

A new hash reference.

=head3 SIDE EFFECTS

None.

=head3 EXAMPLE

	my $step = normalize_step({ run => 'make test' }, ['where.job', { job => 'build' }]);
	print scalar keys %{ $step->{env} }, "\n";    # 0

=head3 API SPECIFICATION

=head4 INPUT

	{
		step  => { type => 'hashref' },
		place => { type => 'arrayref', min => 1 },
	}

=head4 OUTPUT

	{ type => 'hashref' }

=head3 MESSAGES

	+--------------------------------+--------------------------------+------------------------------+
	| Message                        | Meaning                        | Resolution                   |
	+--------------------------------+--------------------------------+------------------------------+
	| A step in PLACE is not a       | The step is a scalar or a list | Start the step with "- run:" |
	| mapping                        |                                | or "- uses:"                 |
	| env/with of a step in PLACE    | env or with is not a mapping   | Indent it as KEY: VALUE      |
	| must be a mapping              |                                |                              |
	| Step field 'F' in PLACE must   | run, uses, shell, name, id, if | Quote the value or fix the   |
	| be a string                    | or working-directory is nested | indentation                  |
	| A step in PLACE has neither    | The step does nothing          | Add run or uses              |
	| 'run' nor 'uses'               |                                |                              |
	+--------------------------------+--------------------------------+------------------------------+

=head3 FORMAL SPECIFICATION

	STRINGFIELD == {run, uses, shell, working-directory, name, id, if}

	┌─ NormalizeStep ───────────────────────────────────
	│ step?  : VALUE
	│ place? : KEY × (NAME ⇸ VALUE)
	│ step!  : KEY ⇸ VALUE
	├───────────────────────────────────────────────────
	│ step? ∉ MAPPING ⇒ raises StepNotMapping(place?)
	│ ∃ f : STRINGFIELD | f ∈ dom step? ∧ step?(f) ≠ ⊥ • step?(f) ∈ REF
	│     ⇒ raises FieldNotString(f, place?)
	│ run ∉ dom step? ∧ uses ∉ dom step? ⇒ raises NoCommand(place?)
	│ otherwise step! = step? ⊕ {env ↦ Mapping(step?.env), with ↦ Mapping(step?.with)}
	└───────────────────────────────────────────────────

=head3 PSEUDOCODE

	refuse a step that is not a mapping
	copy it, replacing env and with by checked copies
	refuse any string field that holds a reference
	refuse a step with neither run nor uses
	return the copy

=cut

sub normalize_step {
	my ($step, $place) = @_;

	# Like mapping(), this runs for every step of every job, so the checks
	# are the contract and no general validator is run first.
	throw(__PACKAGE__, 'step.not_mapping', { where => _place_text($place) }) unless ref $step eq 'HASH';

	my %copy = %{$step};
	for my $field (@MAPPING_STEP_FIELDS) {
		# The place is nested rather than rendered, so the words are only
		# built when there is an error to put them in.
		$copy{$field} = mapping($copy{$field}, ["where.step_$field", { where => $place }]);
	}

	# A reference where a string belongs is almost always YAML indentation
	# that turned a command into a nested mapping.
	for my $field (@STRING_STEP_FIELDS) {
		next unless defined $copy{$field} && ref $copy{$field};
		throw(__PACKAGE__, 'step.field_not_string', { field => $field, where => _place_text($place) });
	}

	throw(__PACKAGE__, 'step.no_command', { where => _place_text($place) })
		unless defined $copy{run} || defined $copy{uses};

	return \%copy;
}

=head2 stringify

Converts a YAML or JSON value to the string a workflow sees for it.

=head3 ARGUMENTS

=over 4

=item * C<$value> - any value.

=back

=head3 RETURNS

C<''> for undef; C<'true'> or C<'false'> for a boolean (a JSON::PP boolean,
or on Perl 5.36 and later a core boolean, which is what YAML::PP produces
for C<true> and C<false>); the value itself for any other scalar; and
canonical JSON for a reference.

=head3 SIDE EFFECTS

None.

=head3 EXAMPLE

	stringify(undef);              # ''
	stringify(1 == 0);             # 'false' on Perl 5.36+, '' before
	stringify(JSON::PP::true);     # 'true'
	stringify([ 1, 'a' ]);         # '[1,"a"]'
	stringify({ b => 1, a => 2 }); # '{"a":2,"b":1}'

=head3 API SPECIFICATION

=head4 INPUT

	{ value => { type => 'string|arrayref|hashref|object', optional => 1 } }

=head4 OUTPUT

	{ type => 'string' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ Stringify ───────────────────────────────────────
	│ value? : optional VALUE
	│ text!  : seq CHAR
	├───────────────────────────────────────────────────
	│ value? = ⊥ ⇒ text! = ⟨⟩
	│ value? ∈ BOOLEAN ⇒ (value? ⇒ text! = "true") ∧ (¬ value? ⇒ text! = "false")
	│ value? ∈ SCALAR \ BOOLEAN ⇒ text! = value?
	│ value? ∈ REF \ BOOLEAN ⇒ text! = canonicalJSON(value?)
	└───────────────────────────────────────────────────

=cut

sub stringify {
	my ($value) = @_;

	# Booleans first: a JSON::PP boolean is a reference and a core boolean
	# stringifies as '' when false, and GitHub writes both as true/false.
	my $text = !defined $value ? ''
		: JSON::PP::is_bool($value) ? ($value ? 'true' : 'false')
		: !ref $value ? "$value"
		: $CANONICAL_JSON->encode($value);

	return $text;
}

=head2 trim

Removes leading and trailing white space.

=head3 ARGUMENTS

=over 4

=item * C<$text> - a string, possibly undef.

=back

=head3 RETURNS

The trimmed string; C<''> for undef.

=head3 SIDE EFFECTS

None; the argument is not modified.

=head3 EXAMPLE

	trim("  error at line 3\n");    # 'error at line 3'

=head3 API SPECIFICATION

=head4 INPUT

	{ text => { type => 'string', optional => 1 } }

=head4 OUTPUT

	{ type => 'string' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ Trim ────────────────────────────────────────────
	│ text?  : optional seq CHAR
	│ text!  : seq CHAR
	├───────────────────────────────────────────────────
	│ text? = ⊥ ⇒ text! = ⟨⟩
	│ text? ≠ ⊥ ⇒ text! is the longest infix of text? that neither
	│             begins nor ends with white space
	└───────────────────────────────────────────────────

=cut

sub trim {
	my ($text) = @_;

	# A copy is trimmed so a caller's variable is never changed behind it.
	# The two ends are separate substitutions: as one alternation,
	# s/\A\s+|\s+\z//g, the second branch is tried at every position of
	# every inner run of white space and rescans the run each time, which is
	# quadratic in its length; on its own Perl anchors it at the end.
	my $copy = defined $text ? $text : '';
	$copy =~ s/\A\s+//;
	$copy =~ s/\s+\z//;

	return $copy;
}

# _place_text
# Purpose:     Render a place ([key, args]) into the words of an error message.
# Entry:       $place - an array reference of a catalogue key and its
#              arguments, or a plain string (rendered as itself).  An
#              argument that is itself a place is rendered first, which is
#              how "env of a step in job 'test'" is built from two keys.
# Exit status: Returns the rendered string.
# Side effects: None.
sub _place_text {
	my ($place) = @_;

	# A string is accepted too, so a caller that already has the words can
	# pass them without inventing a catalogue key.
	my $text = defined $place ? "$place" : '';

	if (ref $place eq 'ARRAY') {
		my ($key, $args) = @{$place};
		my %rendered = map { $_ => (ref $args->{$_} eq 'ARRAY' ? _place_text($args->{$_}) : $args->{$_}) }
			keys %{ $args || {} };
		$text = App::Actions::I18N->shared->message($key, \%rendered);
	}

	return $text;
}

# Every _name routine above may be called only from this package.
# Sub::Private's mode is process-wide, so it is set to enforce for this one
# call rather than for good, which would change how other modules' :Private
# routines behave.
BEGIN {
	local $Sub::Private::config{mode} = 'enforce';
	Sub::Private->import(@{ App::Actions::Access->private_names(__PACKAGE__) });
}

1;

__END__

=head1 LIMITATIONS

=over 4

=item * On Perl older than 5.36, YAML::PP loads C<true> and C<false> as
C<1> and C<''>, which are indistinguishable from the number and the empty
string, so L</stringify> cannot write them as C<true> and C<false> there.
That is the reason the distribution recommends 5.36 for workflows that use
boolean matrix values.

=item * L</normalize_step> checks shape, not meaning: an unknown key, or a
C<uses> that names no real action, is reported later by the run.

=item * L</load_yaml_mapping> reads the whole file into memory; workflow and
action files are small, and streaming would buy nothing.

=back

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
