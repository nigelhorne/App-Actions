use strict;
use warnings;
use Test::Most;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

use App::Actions::Process;

my $root = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
my $script = File::Spec->catfile($root, 't', 'bin', 'check-archive-crlf');

BAIL_OUT("cannot find '$script'; the archive audit is missing from the distribution")
    unless -f $script;

sub write_bytes {
    my ($path, $bytes) = @_;

    my $parent = dirname($path);
    make_path($parent) unless -d $parent;

    open my $handle, '>:raw', $path
        or die "cannot write '$path': $!\n";
    print {$handle} $bytes
        or die "cannot write '$path': $!\n";
    close $handle
        or die "cannot write '$path': $!\n";

    return;
}

# A minimal archive: enough CRLF source files to pass the completeness guard,
# a CRLF source file at the top level, the generated files make dist writes
# with LF, and a binary file that has a NUL and an LF but no line endings to
# check.  The named variations replace the source file or add the failure the
# audit exists to catch.
sub make_archive {
    my (%options) = @_;

    my $directory = tempdir(CLEANUP => 1);

    write_bytes(
        File::Spec->catfile($directory, 'src', "file-$_.txt"),
        "source line $_\r\n",
    ) for 1 .. 40;

    write_bytes(
        File::Spec->catfile($directory, 'README.md'),
        $options{normalised} ? "source line\n" : "source line\r\n",
    );

    write_bytes(File::Spec->catfile($directory, 'META.yml'), "meta: yaml\n");
    write_bytes(File::Spec->catfile($directory, 'META.json'), "{\"meta\":1}\n");
    write_bytes(File::Spec->catfile($directory, 'MANIFEST'), "README.md\n");
    write_bytes(File::Spec->catfile($directory, 'asset.bin'), "binary\0with\n");

    write_bytes(File::Spec->catfile($directory, 'CR.txt'), "bare\r")
        if $options{bare_cr};

    return $directory;
}

sub audit {
    my ($directory) = @_;

    my ($output, $status) = App::Actions::Process::capture(
        [ $^X, $script, $directory ],
        merge_stderr => 1,
    );

    $output =~ s/\r\n/\n/g;

    return ($output, $status);
}

{
    my ($output, $status) = audit(make_archive());

    is($status, 0,
        'the audit accepts CRLF sources with LF in the generated files');
    like(
        $output,
        qr/^verified 41 source files keep CRLF in the archive$/m,
        'the audit counts the source files and reports them',
    );
}

{
    my ($output, $status) = audit(make_archive(normalised => 1));

    isnt($status, 0, 'the audit refuses a source file normalised to LF');
    like(
        $output,
        qr/^check-archive-crlf: archive line endings were normalised to LF: README\.md$/m,
        'the failure names the file whose line endings changed',
    );
}

{
    my ($output, $status) = audit(make_archive(bare_cr => 1));

    isnt($status, 0, 'the audit refuses a source file without CRLF');
    like(
        $output,
        qr/^check-archive-crlf: archive source files without CRLF: CR\.txt$/m,
        'the failure names the file with no CRLF ending',
    );
}

{
    my ($output, $status) = audit(tempdir(CLEANUP => 1));

    isnt($status, 0, 'the audit refuses an archive with no source files');
    like(
        $output,
        qr/^check-archive-crlf: the archive has no source files to check$/m,
        'the failure says why an empty archive cannot pass',
    );
}

done_testing;
