requires 'perl', '5.010';

requires 'Carp';
requires 'Config';
requires 'Cwd';
requires 'File::Basename';
requires 'File::Path';
requires 'File::Spec';
requires 'File::Temp';
requires 'Getopt::Long';
requires 'IO::Handle';
requires 'JSON::PP';
requires 'Pod::Usage';
requires 'Scalar::Util';
requires 'Text::ParseWords';
requires 'Time::HiRes';
requires 'YAML::PP';
requires 'YAML::PP::Common';

on 'configure' => sub {
    requires 'ExtUtils::MakeMaker', '6.64';
};

on 'test' => sub {
    requires 'Capture::Tiny';
    requires 'Exporter';
    requires 'File::Copy';
    requires 'File::Find';
    requires 'File::Temp';
    requires 'FindBin';
    requires 'JSON::PP';
    requires 'Test::DescribeMe';
    requires 'Test::Exception';
    requires 'Test::Most';
};

on 'develop' => sub {
    requires 'Devel::Cover';
    requires 'Perl::Critic';
    requires 'Test::Pod';
    requires 'Test::Pod::Coverage';
};
