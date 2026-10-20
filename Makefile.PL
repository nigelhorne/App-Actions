use strict;
use warnings;
use ExtUtils::MakeMaker;

my $dist = {
    COMPRESS => 'gzip -9f',
    SUFFIX   => 'gz',
};

if ($^O eq 'darwin') {
    $dist->{'TAR'} = 'gtar';
}

WriteMakefile(
    NAME           => 'App::Actions',
    ABSTRACT_FROM  => 'lib/App/Actions.pm',
    VERSION_FROM   => 'lib/App/Actions.pm',
    AUTHOR         => 'Nigel Horne (njh@nigelhorne.com)',
    ((defined($ExtUtils::MakeMaker::VERSION) && ($ExtUtils::MakeMaker::VERSION >= 6.3002))
        ? ('LICENSE' => 'GPL')
        : ()),
    EXE_FILES      => ['bin/action-run'],
    PREREQ_PM      => {
        'Carp'             => 0,
        'Cwd'              => 0,
        'File::Basename'   => 0,
        'File::Path'       => 0,
        'File::Spec'       => 0,
        'File::Temp'       => 0,
        'Getopt::Long'     => 0,
        'JSON::PP'         => 0,
        'Pod::Usage'       => 0,
        'Scalar::Util'     => 0,
        'Text::ParseWords' => 0,
        'Time::HiRes'      => 0,
        'YAML::PP'         => 0,
        'YAML::PP::Common' => 0,
    },
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => 6.64,
    },
    TEST_REQUIRES  => {
        'Capture::Tiny'    => 0,
        'File::Temp'       => 0,
        'JSON::PP'         => 0,
        'Test::DescribeMe' => 0,
        'Test::Exception'  => 0,
        'Test::Most'       => 0,
    },
    MIN_PERL_VERSION => '5.010',
    dist             => $dist,
    clean            => { FILES => 'App-Actions-*' },
    META_MERGE       => {
        'meta-spec' => { version => 2 },
        resources   => {
            homepage   => 'https://metacpan.org/pod/App::Actions',
            repository => {
                repository => 'https://github.com/nigelhorne/App-Actions',
                type       => 'git',
                url        => 'git://github.com/nigelhorne/App-Actions.git',
                web        => 'https://github.com/nigelhorne/App-Actions',
            },
            bugtracker => {
                web    => 'https://rt.cpan.org/Public/Dist/Display.html?Name=App-Actions',
                url    => 'https://rt.cpan.org/Public/Dist/Display.html?Name=App-Actions',
                mailto => 'bug-App-Actions@rt.cpan.org',
            },
        },
    },
);
