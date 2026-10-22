package App::Actions::Access;

use strict;
use warnings;
use autodie qw(:all);

use Carp qw(croak);
use Readonly;
use Sub::Identify qw(get_code_info);

our $VERSION = '0.01';

# A routine whose name starts with this is private to its package.
Readonly::Scalar my $PRIVATE => qr/\A_[A-Za-z0-9]\w*\z/;

=encoding utf-8

=head1 NAME

App::Actions::Access - list the private routines of a package for Sub::Private

=head1 SYNOPSIS

	package App::Actions::Example;

	use Sub::Private ();
	use Sub::Protected ();
	use App::Actions::Access;

	sub run { my $self = shift; return $self->_step }
	sub _step { ... }
	sub _runner { ... }    # protected: subclasses may call it

	# At the end of the file, once every routine above is compiled.
	BEGIN {
		Sub::Protected->import('_runner');
		local $Sub::Private::config{mode} = 'enforce';
		Sub::Private->import(@{ App::Actions::Access->private_names(__PACKAGE__, '_runner') });
	}

=head1 DESCRIPTION

L<Sub::Private> has two modes, and the mode is a single process-wide
setting.  Setting it to C<enforce> once, as a module normally would, also
switches every module loaded afterwards that relies on the default mode.
This distribution therefore never changes the setting for good: each module
sets it with C<local> for the one call that names its private routines, and
uses this module to list them, so a routine added later is protected without
anyone having to remember to list it.

=head1 METHODS

=head2 private_names

Lists the routines of a package whose names start with an underscore, which
the package itself defined (not ones it imported), less the ones named as
exceptions.

=head3 ARGUMENTS

=over 4

=item * C<$package> - the package whose routines are listed.

=item * C<@except> - optional; names to leave out, such as the protected
routines a subclass may call.

=back

=head3 RETURNS

A sorted array reference of names.

=head3 SIDE EFFECTS

None.

=head3 EXAMPLE

	my $names = App::Actions::Access->private_names('App::Actions::Runner');
	print "@$names\n";    # _build_base_env _check_environment ...

=head3 API SPECIFICATION

=head4 INPUT

	{
		package => { type => 'string', matches => qr/\A\w+(?:::\w+)*\z/ },
		except  => { type => 'arrayref', optional => 1 },
	}

=head4 OUTPUT

	{ type => 'arrayref' }

=head3 MESSAGES

	+---------------------------+------------------------------+-----------------------------+
	| Message                   | Meaning                      | Resolution                  |
	+---------------------------+------------------------------+-----------------------------+
	| A package name is required| No package, or not a name    | Pass __PACKAGE__            |
	+---------------------------+------------------------------+-----------------------------+

=head3 FORMAL SPECIFICATION

	┌─ PrivateNames ────────────────────────────────────
	│ package? : PACKAGE
	│ except?  : ℙ NAME
	│ names!   : seq NAME
	├───────────────────────────────────────────────────
	│ ran names! = { n : dom stash(package?) |
	│     n matches /^_\w/ ∧ defined(code(package?, n)) ∧
	│     owner(code(package?, n)) = package? } ∖ except?
	│ names! is sorted
	└───────────────────────────────────────────────────

=cut

sub private_names {
	my (undef, $package, @except) = @_;

	# Called from a BEGIN block with a literal, so a bad name is a mistake
	# in this distribution and is reported in plain English.
	croak 'A package name is required'
		unless defined $package && $package =~ /\A\w+(?:::\w+)*\z/;

	my %skip = map { $_ => 1 } @except;
	my $stash = do { no strict 'refs'; \%{"${package}::"} };

	my @names;
	for my $name (sort keys %{$stash}) {
		next if $skip{$name} || $name !~ $PRIVATE;

		# A glob may hold only a scalar or a hash of that name.
		my $code = do { no strict 'refs'; defined &{"${package}::$name"} ? \&{"${package}::$name"} : undef };
		next unless $code;

		# A routine imported from another package belongs to that package,
		# which decides for itself whether it is private.
		my ($owner) = get_code_info($code);
		push @names, $name if defined $owner && $owner eq $package;
	}

	return \@names;
}

1;

__END__

=head1 LIMITATIONS

=over 4

=item * The listing has to run after the routines are compiled, which is
why the C<BEGIN> block goes at the end of the file.  A routine compiled
after it (by a string C<eval>, say) is not protected.

=item * Privacy is checked on every call, by walking C<caller>, so a private
routine costs more to call than a public one.  None of this distribution's
private routines is called in a tight loop.

=item * The check is bypassed under a test harness (C<HARNESS_ACTIVE>), which
is how the white-box tests reach the private routines.  Run a test file
without the harness to see the checks in force.

=item * A private routine handed to another package as a code reference is
checked when that package calls it, and fails.  Hand over a closure that
calls it instead.

=back

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
