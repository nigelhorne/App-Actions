package App::Actions::Runner::Report;

use strict;
use warnings;
use autodie qw(:all);

use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use IO::Handle ();
use POSIX ();
use Readonly;
use Sub::Private ();

use App::Actions::Access;
use App::Actions::I18N qw(i18n validate_args);
use App::Actions::Runner::Support qw(chomp_error redact);

our $VERSION = '0.01';

# The width of the job-name column of the summary.
Readonly::Scalar my $NAME_WIDTH => 50;

# Kept logs may quote secrets from a job's environment, so they are private.
Readonly::Scalar my $DIRECTORY_MODE => oct('0700');
Readonly::Scalar my $FILE_MODE => oct('0600');

=encoding utf-8

=head1 NAME

App::Actions::Runner::Report - what a run tells its user at the end

=head1 SYNOPSIS

	my $report = App::Actions::Runner::Report->new(docker => $docker);

	$report->record('test (perl=5.40)', 'success');
	$report->record('lint', 'failure')->fail;
	$report->print_summary;    # === Workflow summary === ... Workflow FAILED

=head1 DESCRIPTION

Collects one line per job as the run goes, says at the end whether the
workflow succeeded, and keeps the logs of the jobs that ran in parallel: they
are copied out of the temporary directory before it is removed, so a failed
job's own account of what went wrong can be read after the run (and
C<action-run logs> lists them).

=head1 METHODS

=head2 new

=head3 ARGUMENTS

=over 4

=item * C<docker> - used to mask secrets in job names.

=item * C<quiet> - optional; print nothing.

=back

=head3 RETURNS

An C<App::Actions::Runner::Report> object.

=head3 SIDE EFFECTS

None.

=head3 EXAMPLE

	my $report = App::Actions::Runner::Report->new(docker => $docker, quiet => 0);

=head3 API SPECIFICATION

=head4 INPUT

	{
		docker => { type => 'object' },
		quiet  => { type => 'boolean', optional => 1 },
	}

=head4 OUTPUT

	{ type => 'object', isa => 'App::Actions::Runner::Report' }

=head3 MESSAGES

	+---------------------------+------------------------------+-----------------------------+
	| Message                   | Meaning                      | Resolution                  |
	+---------------------------+------------------------------+-----------------------------+
	| Invalid arguments to      | docker is missing            | Pass the Docker object      |
	| ...Report::new: REASON    |                              |                             |
	+---------------------------+------------------------------+-----------------------------+

=head3 FORMAL SPECIFICATION

	┌─ Report ──────────────────────────────────────────
	│ entries : seq (NAME × RESULT)
	│ failed  : 𝔹
	│ kept    : optional DIRECTORY
	├───────────────────────────────────────────────────
	│ true
	└───────────────────────────────────────────────────

=cut

sub new {
	my $class = shift;

	my $params = validate_args(__PACKAGE__ . '::new', \@_, {
		docker => { type => 'object' },
		quiet => { type => 'boolean', optional => 1 },
	});

	return bless { %{$params}, entries => [], failed => 0, kept_dir => undef, kept_logs => [] }, $class;
}

=head2 record

	$report->record($display_name, $result);

Adds a job's line to the summary.  Returns the object.

=head3 EXAMPLE

	$report->record('lint', 'skipped');

=head3 API SPECIFICATION

=head4 INPUT

	{
		name   => { type => 'string' },
		result => { type => 'string', memberof => [ 'success', 'failure', 'skipped' ] },
	}

=head4 OUTPUT

	{ type => 'object', isa => 'App::Actions::Runner::Report' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ Record ──────────────────────────────────────────
	│ ΔReport
	│ name?, result? : seq CHAR
	├───────────────────────────────────────────────────
	│ entries' = entries ⁀ ⟨(name?, result?)⟩
	└───────────────────────────────────────────────────

=cut

sub record {
	my ($self, $name, $result) = @_;

	push @{ $self->{entries} }, { name => $name, result => $result };

	return $self;
}

=head2 fail

Marks the workflow as failed.  Returns the object.

=head3 EXAMPLE

	$report->record($name, 'failure')->fail unless $continue_on_error;

=head3 API SPECIFICATION

=head4 INPUT

	{}

=head4 OUTPUT

	{ type => 'object', isa => 'App::Actions::Runner::Report' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ Fail ────────────────────────────────────────────
	│ ΔReport
	├───────────────────────────────────────────────────
	│ failed' = true
	└───────────────────────────────────────────────────

=cut

sub fail {
	my ($self) = @_;

	$self->{failed} = 1;

	return $self;
}

=head2 failed

Says whether the workflow has failed: 1 or 0.

=head3 EXAMPLE

	return $report->failed ? 1 : 0;

=head3 API SPECIFICATION

=head4 INPUT

	{}

=head4 OUTPUT

	{ type => 'boolean' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ Failed ──────────────────────────────────────────
	│ ΞReport
	│ f! : 𝔹
	├───────────────────────────────────────────────────
	│ f! = failed
	└───────────────────────────────────────────────────

=cut

sub failed {
	my ($self) = @_;

	return $self->{failed} ? 1 : 0;
}

=head2 print_summary

Prints one line per job and whether the workflow succeeded, unless quiet.
Returns the object.

=head3 EXAMPLE

	$report->print_summary;
	#
	# === Workflow summary ===
	#   test (perl=5.40)                                   success
	# Workflow succeeded

=head3 API SPECIFICATION

=head4 INPUT

	{}

=head4 OUTPUT

	{ type => 'object', isa => 'App::Actions::Runner::Report' }

=head3 MESSAGES

	+---------------------------+------------------------------+-----------------------------+
	| Message                   | Meaning                      | Resolution                  |
	+---------------------------+------------------------------+-----------------------------+
	| No jobs were run.         | Every job was skipped or     | Check --job and the jobs'   |
	|                           | none was selected            | conditions                  |
	| Workflow FAILED           | A job failed without         | Read the job's output       |
	|                           | continue-on-error            |                             |
	+---------------------------+------------------------------+-----------------------------+

=head3 FORMAL SPECIFICATION

	┌─ PrintSummary ────────────────────────────────────
	│ ΞReport
	│ out! : seq LINE
	├───────────────────────────────────────────────────
	│ quiet ⇒ out! = ⟨⟩
	│ ¬ quiet ⇒ out! = ⟨header⟩ ⁀ lines(entries) ⁀ ⟨verdict(failed)⟩
	└───────────────────────────────────────────────────

=cut

sub print_summary {
	my ($self) = @_;

	return $self if $self->{quiet};

	print "\n", $self->i18n('runner.summary.header'), "\n";
	print $self->i18n('runner.summary.none'), "\n" unless @{ $self->{entries} };
	printf "  %-${NAME_WIDTH}s %s\n", redact($self->{docker}, $_->{name}), $_->{result} for @{ $self->{entries} };
	print $self->i18n($self->{failed} ? 'runner.summary.failed' : 'runner.summary.succeeded'), "\n";

	return $self;
}

=head2 report_images

	$report->report_images($records);

Prints one line per image for a preflight that reports as text: what needs
it, and whether it was pulled, present, failed, skipped or deferred.  A
deferred image is named by its expression and followed by the reason it
could not be resolved, which the reader could not see otherwise.  Returns
the object.

=head3 EXAMPLE

	$report->report_images($prepared->{records});
	#   image     perl:5.40 (job 'test'): present

=head3 API SPECIFICATION

=head4 INPUT

	{ records => { type => 'arrayref' } }

=head4 OUTPUT

	{ type => 'object', isa => 'App::Actions::Runner::Report' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ ReportImages ────────────────────────────────────
	│ ΞReport
	│ records? : seq RECORD
	│ out!     : seq LINE
	├───────────────────────────────────────────────────
	│ #out! = #records? + #{r : ran records? | r.status = deferred ∧ r.error ≠ ⊥}
	└───────────────────────────────────────────────────

=cut

sub report_images {
	my ($self, $records) = @_;

	for my $record (@{$records}) {
		my ($name) = grep { defined && length } ($record->{image}, $record->{expression});
		my $source = $record->{source};

		print $self->i18n('runner.preflight.image', {
			name => defined $name ? $name : $self->i18n('runner.preflight.unnamed'),
			source => (defined $source && length $source) ? $source : $self->i18n('runner.preflight.workflow'),
			status => $record->{status},
		}), "\n";

		print $self->i18n('runner.preflight.deferred', { error => $record->{error} }), "\n"
			if $record->{status} eq 'deferred' && defined $record->{error} && length $record->{error};
	}

	return $self;
}

=head2 keep_logs

	$report->keep_logs($logs, $root, $run_id);

Copies the logs of a parallel run into a directory of their own under
C<$root>, named after the time and the run, so C<--keep> is not needed to
read them afterwards.  A failure to copy them is a warning, not a failed
run.  Returns the object.

=head3 ARGUMENTS

=over 4

=item * C<$logs> - from L<App::Actions::Runner::Parallel/logs>.

=item * C<$root> - where the run's log directories go.

=item * C<$run_id> - the run's identifier.

=back

=head3 SIDE EFFECTS

Creates a private directory and copies the logs into it; warns on failure.

=head3 EXAMPLE

	$report->keep_logs($parallel->logs, App::Actions::Logs->default_directory, $run_id);

=head3 API SPECIFICATION

=head4 INPUT

	{
		logs   => { type => 'arrayref' },
		root   => { type => 'string', min => 1 },
		run_id => { type => 'string', min => 1 },
	}

=head4 OUTPUT

	{ type => 'object', isa => 'App::Actions::Runner::Report' }

=head3 MESSAGES

	+-----------------------------+------------------------------+-----------------------------+
	| Message                     | Meaning                      | Resolution                  |
	+-----------------------------+------------------------------+-----------------------------+
	| action-run: could not keep  | The directory could not be   | Check the log directory's   |
	| the job logs: cannot copy   | made or a log copied         | space and permissions       |
	| 'X' to 'Y': E               |                              |                             |
	+-----------------------------+------------------------------+-----------------------------+

=head3 FORMAL SPECIFICATION

	┌─ KeepLogs ────────────────────────────────────────
	│ ΔReport
	│ logs? : seq LOG
	├───────────────────────────────────────────────────
	│ let present == {l : ran logs? | exists(l.path)}
	│ present = ∅ ⇒ kept' = kept
	│ present ≠ ∅ ∧ copied ⇒ kept' = dir ∧ files(dir) = {l.file | l ∈ present}
	└───────────────────────────────────────────────────

=cut

sub keep_logs {
	my ($self, $logs, $root, $run_id) = @_;

	my @present = grep { defined $_->{path} && -f $_->{path} } @{ $logs || [] };
	return $self unless @present;

	my $directory = File::Spec->catdir($root, POSIX::strftime('%Y%m%d-%H%M%S', localtime) . "-$run_id");

	my $kept = eval {
		# A filesystem that will not take the mode still holds the logs, so
		# a failed chmod does not cost the copies.
		no autodie qw(chmod);
		make_path($directory);
		chmod $DIRECTORY_MODE, $directory;
		for my $entry (@present) {
			my $target = File::Spec->catfile($directory, $entry->{file});
			copy($entry->{path}, $target)
				or die $self->i18n('runner.logs.copy_failed', { from => $entry->{path}, to => $target, error => "$!" }), "\n";
			chmod $FILE_MODE, $target;
			$entry->{kept} = $target;
		}
		1;
	};

	if ($kept) {
		$self->{kept_dir} = $directory;
		$self->{kept_logs} = [ grep { $_->{kept} } @present ];
	} else {
		warn $self->i18n('runner.logs.keep_failed', { error => chomp_error($@) }), "\n";
	}

	return $self;
}

=head2 print_kept_logs

Says where L</keep_logs> put the logs, one line per job, unless quiet or
there were none.  Returns the object.

=head3 EXAMPLE

	$report->print_kept_logs;
	#
	# Job logs kept in /home/me/.cache/action-run/logs/20260101-120000-65f0a1b2c3
	#   test (n=one)  job-1-test_n_one.log

=head3 API SPECIFICATION

=head4 INPUT

	{}

=head4 OUTPUT

	{ type => 'object', isa => 'App::Actions::Runner::Report' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ PrintKeptLogs ───────────────────────────────────
	│ ΞReport
	├───────────────────────────────────────────────────
	│ quiet ∨ kept = ⊥ ⇒ out! = ⟨⟩
	└───────────────────────────────────────────────────

=cut

sub print_kept_logs {
	my ($self) = @_;

	my $directory = $self->{kept_dir};
	return $self if $self->{quiet} || !defined $directory;

	print "\n", $self->i18n('runner.logs.kept', { dir => $directory }), "\n";
	print "  $_->{name}  $_->{file}\n" for @{ $self->{kept_logs} };
	STDOUT->flush;

	return $self;
}

=head2 print_kept_resources

	$report->print_kept_resources($containers->remaining, $temp_path);

Lists what a run that keeps its resources left behind: its containers, its
networks and its temporary directory, so they can be inspected and removed.
Prints nothing when there are none.  Returns the object.

=head3 EXAMPLE

	$report->print_kept_resources({ containers => [ 'c1' ], networks => [ 'n1' ] }, '/tmp/x');
	# Kept Docker resources:
	#   container c1
	#   network n1
	#   temporary directory /tmp/x

=head3 API SPECIFICATION

=head4 INPUT

	{
		remaining => { type => 'hashref' },
		temp_path => { type => 'string', optional => 1 },
	}

=head4 OUTPUT

	{ type => 'object', isa => 'App::Actions::Runner::Report' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

	┌─ PrintKeptResources ──────────────────────────────
	│ ΞReport
	│ r?    : RESOURCES
	│ temp? : optional DIRECTORY
	├───────────────────────────────────────────────────
	│ r?.containers = ⟨⟩ ∧ r?.networks = ⟨⟩ ∧ temp? = ⊥ ⇒ out! = ⟨⟩
	└───────────────────────────────────────────────────

=cut

sub print_kept_resources {
	my ($self, $remaining, $temp_path) = @_;

	my @containers = @{ $remaining->{containers} || [] };
	my @networks = @{ $remaining->{networks} || [] };
	return $self unless @containers || @networks || $temp_path;

	# The list is what the user needs to clean up by hand, so even a quiet
	# run prints it; only the heading is left out.
	print $self->i18n('runner.kept.header'), "\n" unless $self->{quiet};
	print $self->i18n('runner.kept.container', { name => $_ }), "\n" for @containers;
	print $self->i18n('runner.kept.network', { name => $_ }), "\n" for @networks;
	print $self->i18n('runner.kept.temp', { dir => $temp_path }), "\n" if $temp_path;

	return $self;
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

=item * The summary's name column is 50 characters wide; a longer matrix name
pushes its result to the right.

=item * Logs are kept by copying, so a run's logs briefly take twice the
space.  Nothing expires them except C<action-run logs --prune>.

=item * The result words (C<success>, C<failure>, C<skipped>) and image
statuses are left untranslated: they are values a script may match, as in
the JSON documents.

=back

=head1 AUTHOR

Nigel Horne, C<njh@nigelhorne.com>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
