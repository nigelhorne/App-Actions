package App::Actions::Runner::Support;

use strict;
use warnings;
use autodie qw(:all);

use Exporter qw(import);
use File::Spec;
use Readonly;

use App::Actions::Error;
use App::Actions::I18N qw(throw);
use App::Actions::Util ();

our $VERSION = '0.01';

our @EXPORT_OK = qw(
	action_inputs
	boolean_value
	chomp_error
	env_args
	has_status_function
	local_action_path
	redact
	resolve_env
	status_flags
	trim_error
	write_container_file
);

# How many times an environment is re-interpolated.  A variable may refer to
# another (B: ${{ env.A }}), so values are resolved until nothing changes;
# the cap stops two variables that refer to each other from looping forever.
Readonly::Scalar my $ENV_PASSES => 10;

# The words a workflow may use for a boolean without writing an expression.
Readonly::Scalar my $TRUE_WORD => qr/\A(?:true|yes|1)\z/i;
Readonly::Scalar my $FALSE_WORD => qr/\A(?:false|no|0)\z/i;

# The status functions of the expression language.  A condition that calls
# none of them is given an implicit success(), as on GitHub.
Readonly::Scalar my $STATUS_FUNCTION => qr/\b(?:success|failure|always|cancelled)\s*\(/;

=encoding utf-8

=head1 NAME

App::Actions::Runner::Support - helpers shared by the parts of the runner

=head1 SYNOPSIS

	use App::Actions::Runner::Support qw(resolve_env status_flags trim_error);

	my $env = resolve_env($expression, [ $workflow_env, $job_env ], $context);
	my $status = status_flags($failed);

=head1 DESCRIPTION

The runner is split into a planner (L<App::Actions::Runner>), an image
preparer (L<App::Actions::Runner::Images>), a container manager
(L<App::Actions::Runner::Containers>), a step executor
(L<App::Actions::Runner::Steps>), a parallel scheduler
(L<App::Actions::Runner::Parallel>) and a reporter
(L<App::Actions::Runner::Report>).  The functions here are the ones more than
one of them needs.  None keeps state.

=head1 FUNCTIONS

All are exported on request.

=head2 status_flags

	my $status = status_flags($failed);

Returns the values of the status functions for a job or a step that has, or
has not, failed so far: C<< { success => 1, failure => 0, cancelled => 0 } >>
or the reverse.  A run is never cancelled.

=head3 EXAMPLE

	$expression->condition('failure()', $context, status_flags(1));    # true

=head3 API SPECIFICATION

=head4 INPUT

	{ failed => { type => 'boolean' } }

=head4 OUTPUT

	{ type => 'hashref' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ StatusFlags ─────────────────────────────────────
	│ failed? : 𝔹
	│ s!      : {success, failure, cancelled} → 𝔹
	├───────────────────────────────────────────────────
	│ s!(success) = ¬ failed? ∧ s!(failure) = failed? ∧ s!(cancelled) = false
	└───────────────────────────────────────────────────

=cut

sub status_flags {
	my ($failed) = @_;

	return {
		success => $failed ? 0 : 1,
		failure => $failed ? 1 : 0,
		cancelled => 0,
	};
}

=head2 chomp_error

	my $text = chomp_error($@);

Returns an exception as a string without its trailing white space.  The
location, if any, is kept: this is for messages that have always shown it.

=head3 EXAMPLE

	print STDERR 'action-run: ', chomp_error($@), "\n";

=head3 API SPECIFICATION

=head4 INPUT

	{ error => { type => 'any', optional => 1 } }

=head4 OUTPUT

	{ type => 'string' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ ChompError ──────────────────────────────────────
	│ error? : VALUE
	│ s!     : seq CHAR
	├───────────────────────────────────────────────────
	│ s! = rtrim(string(error?))
	└───────────────────────────────────────────────────

=cut

sub chomp_error {
	my ($error) = @_;

	my $text = defined $error ? "$error" : '';
	$text =~ s/\s+\z//;

	return $text;
}

=head2 trim_error

	my $reason = trim_error($@);

Returns an exception as a sentence: its message without the source location
(see L<App::Actions::Error/describe>), or C<undef> when there was no error.
Everything that ends up in a summary or a report goes through here, because a
location is useful in a stack trace and noise in a report someone reads.

=head3 EXAMPLE

	my $ok = eval { $docker->pull($image); 1 };
	$record->{error} = trim_error($@) unless $ok;

=head3 API SPECIFICATION

=head4 INPUT

	{ error => { type => 'any', optional => 1 } }

=head4 OUTPUT

	{ type => 'string', optional => 1 }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ TrimError ───────────────────────────────────────
	│ error? : VALUE
	│ s!     : optional seq CHAR
	├───────────────────────────────────────────────────
	│ error? = ⊥ ∨ string(error?) = ⟨⟩ ⇒ s! = ⊥
	│ otherwise s! = Describe(error?)
	└───────────────────────────────────────────────────

=cut

sub trim_error {
	my ($error) = @_;

	return (defined $error && length "$error") ? App::Actions::Error->describe($error) : undef;
}

=head2 resolve_env

	my $env = resolve_env($expression, \@layers, $context);

Merges layers of environment variables, later layers winning, and resolves
the C<${{ }}> expressions in their values.  A value may refer to another
variable through C<env.*>, so the values are resolved again until nothing
changes, at most ten times.

=head3 ARGUMENTS

=over 4

=item * C<$expression> - an L<App::Actions::Expression>.

=item * C<\@layers> - hash references; anything else is skipped.

=item * C<$context> - the expression context; its C<env> is replaced by the
variables being resolved.

=back

=head3 RETURNS

A hash reference of name to string.

=head3 SIDE EFFECTS

None.

=head3 EXAMPLE

	my $env = resolve_env($expression, [ { A => 'x' }, { B => '${{ env.A }}y' } ], {});
	# { A => 'x', B => 'xy' }

=head3 API SPECIFICATION

=head4 INPUT

	{
		expression => { type => 'object', can => 'interpolate' },
		layers     => { type => 'arrayref' },
		context    => { type => 'hashref' },
	}

=head4 OUTPUT

	{ type => 'hashref' }

=head3 MESSAGES

	+-----------------------------+------------------------------+-----------------------------+
	| Message                     | Meaning                      | Resolution                  |
	+-----------------------------+------------------------------+-----------------------------+
	| Unable to evaluate          | A value holds an expression  | Fix the expression in the   |
	| environment variable 'X': E | that does not parse or run   | workflow's env              |
	+-----------------------------+------------------------------+-----------------------------+

=head3 FORMAL SPECIFICATION

	┌─ ResolveEnv ──────────────────────────────────────
	│ layers?  : seq (NAME ⇸ VALUE)
	│ context? : CONTEXT
	│ env!     : NAME ⇸ seq CHAR
	├───────────────────────────────────────────────────
	│ let merged == ⊕/ layers?
	│ env! = fix(λ e • {n ↦ interpolate(e(n), context? ⊕ {env ↦ e})}, merged, 10)
	└───────────────────────────────────────────────────

=head3 PSEUDOCODE

	merge the layers into one hash of strings, later layers winning
	repeat up to ten times:
		interpolate every value with the hash itself as env
		stop when no value changed
	return the hash

=cut

sub resolve_env {
	my ($expression, $layers, $context) = @_;

	# Later layers win: the workflow's env, then the job's, then the step's.
	my %env;
	for my $layer (grep { ref $_ eq 'HASH' } @{$layers}) {
		$env{$_} = App::Actions::Util::stringify($layer->{$_}) for keys %{$layer};
	}

	# Resolve until a pass changes nothing, so a chain of references settles
	# however it is ordered, and a cycle stops at the cap.
	my $changed = 1;
	for (my $pass = 1; $changed && $pass <= $ENV_PASSES; $pass++) {
		my %with_env = (%{$context}, env => { %env });
		$changed = 0;
		for my $key (keys %env) {
			my $value;
			eval { $value = $expression->interpolate($env{$key}, \%with_env); 1 }
				or __PACKAGE__->throw('runner.env_failed', { name => $key, error => chomp_error($@) });
			next if $value eq $env{$key};
			$env{$key} = $value;
			$changed = 1;
		}
	}

	return \%env;
}

=head2 boolean_value

	my $flag = boolean_value($expression, $value, $context, $status);

Reads a workflow boolean such as C<continue-on-error>: a YAML boolean, one of
the words C<true>, C<yes>, C<1>, C<false>, C<no>, C<0>, or an expression
whose result is truthy.

=head3 EXAMPLE

	boolean_value($expression, 'yes', {}, status_flags(0));                     # 1
	boolean_value($expression, '${{ matrix.experimental }}', $context, $status); # as the matrix says

=head3 API SPECIFICATION

=head4 INPUT

	{
		expression => { type => 'object', can => 'condition' },
		value      => { type => 'any', optional => 1 },
		context    => { type => 'hashref' },
		status     => { type => 'hashref', optional => 1 },
	}

=head4 OUTPUT

	{ type => 'boolean' }

=head3 MESSAGES

Whatever the expression's evaluation croaks with.

=head3 FORMAL SPECIFICATION

	┌─ BooleanValue ────────────────────────────────────
	│ value? : VALUE
	│ b!     : 𝔹
	├───────────────────────────────────────────────────
	│ value? ∈ REF ⇒ b! = truthy(value?)
	│ value? = ⊥ ∨ trim(value?) = ⟨⟩ ⇒ b! = false
	│ trim(value?) ∈ TRUE_WORD ⇒ b! = true
	│ trim(value?) ∈ FALSE_WORD ⇒ b! = false
	│ otherwise b! = condition(trim(value?))
	└───────────────────────────────────────────────────

=cut

sub boolean_value {
	my ($expression, $value, $context, $status) = @_;

	# A YAML boolean is a reference (JSON::PP::Boolean) or a core boolean;
	# either is already the answer.
	return $value ? 1 : 0 if ref $value;

	my $text = App::Actions::Util::trim($value);

	# The words are read without the evaluator, which would take "yes" for
	# a context name and "0" for a number.
	return 0 if $text eq '' || $text =~ $FALSE_WORD;
	return 1 if $text =~ $TRUE_WORD;

	return $expression->condition($text, $context, $status) ? 1 : 0;
}

=head2 has_status_function

Says whether a condition calls C<success()>, C<failure()>, C<always()> or
C<cancelled()>.  One that does not is given an implicit C<success()>.

=head3 EXAMPLE

	has_status_function('always() && matrix.os == "linux"');    # 1

=head3 API SPECIFICATION

=head4 INPUT

	{ condition => { type => 'string', optional => 1 } }

=head4 OUTPUT

	{ type => 'boolean' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ HasStatusFunction ───────────────────────────────
	│ condition? : optional seq CHAR
	│ b!         : 𝔹
	├───────────────────────────────────────────────────
	│ b! ⇔ condition? ≠ ⊥ ∧ condition? contains f( for some f ∈ STATUS
	└───────────────────────────────────────────────────

=cut

sub has_status_function {
	my ($condition) = @_;

	return (defined $condition && $condition =~ $STATUS_FUNCTION) ? 1 : 0;
}

=head2 write_container_file

	write_container_file($path, $contents, $description);

Writes a file that a container will read, in binary mode.  Scripts must keep
LF line endings: on Windows a text-mode handle would write CRLF, and bash
rejects a script whose lines end in C<\r>.

=head3 ARGUMENTS

=over 4

=item * C<$path> - where to write.

=item * C<$contents> - the bytes.

=item * C<$description> - what the file is, for the error message (for
example "the sudo shim").

=back

=head3 RETURNS

Nothing useful.

=head3 SIDE EFFECTS

Creates or replaces the file.

=head3 EXAMPLE

	write_container_file("$temp/scripts/step-1.sh", "echo hi\n", 'the step script');

=head3 API SPECIFICATION

=head4 INPUT

	{
		path        => { type => 'string', min => 1 },
		contents    => { type => 'string' },
		description => { type => 'string' },
	}

=head4 OUTPUT

	{ type => 'undef' }

=head3 MESSAGES

	+-----------------------------+------------------------------+-----------------------------+
	| Message                     | Meaning                      | Resolution                  |
	+-----------------------------+------------------------------+-----------------------------+
	| Unable to write WHAT: ERROR | The file could not be opened | Check the temporary         |
	|                             | or written                   | directory's space and mode  |
	+-----------------------------+------------------------------+-----------------------------+

=head3 FORMAL SPECIFICATION

	┌─ WriteContainerFile ──────────────────────────────
	│ ΔFileSystem
	│ path?, contents? : seq CHAR
	├───────────────────────────────────────────────────
	│ files' = files ⊕ {path? ↦ contents?}
	└───────────────────────────────────────────────────

=cut

sub write_container_file {
	my ($path, $contents, $description) = @_;

	# Checked by hand rather than by autodie, whose message would name the
	# builtin; the catalogue's names the file the run was writing, which is
	# the part a user can act on.
	my $handle;
	my $written = do {
		no autodie qw(open binmode close);
		open($handle, '>', $path)
			&& binmode($handle)
			&& print({$handle} $contents)
			&& close($handle);
	};
	__PACKAGE__->throw('runner.write_failed', { what => $description, error => "$!" })
		unless $written;

	return;
}

=head2 local_action_path

	my $relative = local_action_path('./.github/actions/test');

Resolves a C<./path/to/action> reference to a path relative to the project.
Both the run and the preflight resolve references this way, so an action is
read from one place whichever finds it first.

=head3 EXAMPLE

	local_action_path('./.github/actions/build/');    # .github/actions/build

=head3 API SPECIFICATION

=head4 INPUT

	{ uses => { type => 'string' } }

=head4 OUTPUT

	{ type => 'string', min => 1 }

=head3 MESSAGES

	+-----------------------------+------------------------------+-----------------------------+
	| Message                     | Meaning                      | Resolution                  |
	+-----------------------------+------------------------------+-----------------------------+
	| Local action 'X' does not   | The reference is "./" alone  | Name the action's directory |
	| name a directory inside the |                              |                             |
	| project                     |                              |                             |
	| Local action 'X' must not   | The path contains ".."       | Keep the action inside the  |
	| escape the project directory|                              | repository                  |
	+-----------------------------+------------------------------+-----------------------------+

=head3 FORMAL SPECIFICATION

	┌─ LocalActionPath ─────────────────────────────────
	│ uses? : seq CHAR
	│ rel!  : seq CHAR
	├───────────────────────────────────────────────────
	│ rel! = stripSlashes(stripDotSlash(uses?))
	│ rel! ≠ ⟨⟩ ∧ ".." ∉ segments(rel!)
	└───────────────────────────────────────────────────

=cut

sub local_action_path {
	my ($uses) = @_;

	# "./a/b/", "/a/b" and "a/b" all mean the directory a/b in the project.
	(my $relative = $uses) =~ s{\A\./}{};
	$relative =~ s{\A/+}{};
	$relative =~ s{/+\z}{};

	__PACKAGE__->throw('runner.local_action_empty', { uses => $uses })
		unless length $relative;
	__PACKAGE__->throw('runner.local_action_escapes', { uses => $uses })
		if $relative =~ m{(?:\A|/)\.\.(?:/|\z)};

	return $relative;
}

=head2 action_inputs

	my $inputs = action_inputs($expression, $action, $step, $uses, $context, $status);

Resolves a local action's inputs: the defaults its metadata declares,
replaced by the calling step's C<with>.  An input the action requires and
neither supplies is an error.

=head3 EXAMPLE

	my $inputs = action_inputs($expression, $action, { with => { name => 'x' } },
		'./.github/actions/greet', $context, status_flags(0));

=head3 API SPECIFICATION

=head4 INPUT

	{
		expression => { type => 'object', can => 'interpolate' },
		action     => { type => 'object', isa => 'App::Actions::Action' },
		step       => { type => 'hashref' },
		uses       => { type => 'string' },
		context    => { type => 'hashref' },
		status     => { type => 'hashref', optional => 1 },
	}

=head4 OUTPUT

	{ type => 'hashref' }

=head3 MESSAGES

	+-----------------------------+------------------------------+-----------------------------+
	| Message                     | Meaning                      | Resolution                  |
	+-----------------------------+------------------------------+-----------------------------+
	| Action 'X' requires the     | A required input has no      | Pass it with "with:"        |
	| input 'Y'                   | default and was not given    |                             |
	+-----------------------------+------------------------------+-----------------------------+

=head3 FORMAL SPECIFICATION

	┌─ ActionInputs ────────────────────────────────────
	│ declared : NAME ⇸ INPUT
	│ with?    : NAME ⇸ VALUE
	│ inputs!  : NAME ⇸ seq CHAR
	├───────────────────────────────────────────────────
	│ inputs! = {n : dom declared • n ↦ interpolate(default(n))} ⊕
	│           {n : dom with? • n ↦ interpolate(with?(n))}
	│ ∀ n : dom declared | required(n) • inputs!(n) ≠ ⟨⟩
	└───────────────────────────────────────────────────

=head3 PSEUDOCODE

	start with every declared input's default, interpolated, or ''
	overlay every value of the step's with, interpolated
	croak naming the first required input (by name) that is still empty
	return the inputs

=cut

sub action_inputs {
	my ($expression, $action, $step, $uses, $context, $status) = @_;

	my $declared = $action->inputs || {};
	my $with = ref $step->{with} eq 'HASH' ? $step->{with} : {};

	# Defaults first, so the step's own values replace them.
	my %inputs;
	for my $name (keys %{$declared}) {
		my $default = $declared->{$name}{default};
		$inputs{$name} = (defined $default && length $default)
			? $expression->interpolate($default, $context, $status)
			: '';
	}

	# A structured value (a YAML list, say) is passed as its JSON text, as
	# GitHub does; only a scalar can hold an expression.
	for my $name (keys %{$with}) {
		my $value = $with->{$name};
		$value = $expression->interpolate(App::Actions::Util::stringify($value), $context, $status)
			unless ref $value;
		$inputs{$name} = App::Actions::Util::stringify($value);
	}

	# Sorted, so the input named in the error is the same on every run.
	for my $name (sort keys %{$declared}) {
		next unless $declared->{$name}{required};
		next if defined $inputs{$name} && length $inputs{$name};
		__PACKAGE__->throw('runner.input_required', { uses => $uses, name => $name });
	}

	return \%inputs;
}

=head2 redact

	my $safe = redact($docker, $text);

Masks the secrets the Docker object knows about, when it can; a
caller-supplied Docker object need not offer redaction.

=head3 EXAMPLE

	print redact($docker, "token is $token\n");    # token is ***

=head3 API SPECIFICATION

=head4 INPUT

	{
		docker => { type => 'object' },
		text   => { type => 'string', optional => 1 },
	}

=head4 OUTPUT

	{ type => 'string', optional => 1 }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ Redact ──────────────────────────────────────────
	│ text? : optional seq CHAR
	│ s!    : optional seq CHAR
	├───────────────────────────────────────────────────
	│ text? = ⊥ ⇒ s! = ⊥
	│ docker can redact ⇒ s! = docker.redact(text?)
	│ otherwise s! = text?
	└───────────────────────────────────────────────────

=cut

sub redact {
	my ($docker, $text) = @_;

	return (defined $text && $docker->can('redact')) ? $docker->redact($text) : $text;
}

=head2 env_args

	push @args, @{ env_args(\%env) };

Turns an environment into C<docker> arguments: C<-e NAME=VALUE> for each
variable, sorted by name so the command line is the same on every run.

=head3 EXAMPLE

	env_args({ B => 2, A => 1 });    # ['-e', 'A=1', '-e', 'B=2']

=head3 API SPECIFICATION

=head4 INPUT

	{ env => { type => 'hashref' } }

=head4 OUTPUT

	{ type => 'arrayref' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ EnvArgs ─────────────────────────────────────────
	│ env? : NAME ⇸ seq CHAR
	│ a!   : seq seq CHAR
	├───────────────────────────────────────────────────
	│ a! = ⁀/ ⟨n : sorted(dom env?) • ⟨"-e", n ⁀ "=" ⁀ env?(n)⟩⟩
	└───────────────────────────────────────────────────

=cut

sub env_args {
	my ($env) = @_;

	return [ map { ('-e', "$_=$env->{$_}") } sort keys %{$env} ];
}

1;

__END__

=head1 LIMITATIONS

=over 4

=item * The functions do not validate their arguments: they are called many
times per step by the other parts of the runner, which validate what they
were given when they are constructed.

=item * L</resolve_env> gives up after ten passes.  A variable that refers to
itself, or two that refer to each other, keep whatever the tenth pass made of
them rather than being reported.

=back

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
