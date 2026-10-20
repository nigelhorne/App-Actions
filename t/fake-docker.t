use strict;
use warnings;
use Test::Most;
use FindBin;
use File::Spec;

use lib "$FindBin::Bin/lib";

use App::Actions::FakeDocker qw(split_volume mounts to_host);

is_deeply(
    [ split_volume('/tmp/project:/github/workspace') ],
    [ '/tmp/project', '/github/workspace' ],
    'a Unix volume specification is split at the colon',
);

is_deeply(
    [ split_volume('C:\\Users\\me\\project:/github/workspace') ],
    [ 'C:\\Users\\me\\project', '/github/workspace' ],
    'a Windows drive letter is not mistaken for the separator',
);

is_deeply(
    [ split_volume('C:/Users/me/project:/github/workspace') ],
    [ 'C:/Users/me/project', '/github/workspace' ],
    'a Windows path with forward slashes is split correctly',
);

is_deeply(
    [ split_volume('/tmp/project:/github/workspace:ro') ],
    [ '/tmp/project', '/github/workspace' ],
    'a read-only mode is dropped',
);

is_deeply(
    [ split_volume('C:\\project:/github/workspace:rw') ],
    [ 'C:\\project', '/github/workspace' ],
    'a Windows host path with a mode is split correctly',
);

is_deeply(
    [ split_volume('data:/var/lib/postgresql/data') ],
    [ 'data', '/var/lib/postgresql/data' ],
    'named volumes are supported',
);

is_deeply([ split_volume('C:\\project') ], [], 'a bare Windows path is not a volume');
is_deeply([ split_volume('/tmp/project') ], [], 'a bare Unix path is not a volume');
is_deeply([ split_volume('') ], [], 'an empty specification is ignored');
is_deeply([ split_volume(undef) ], [], 'an undefined specification is ignored');

my $mounts = mounts([
    'run', '-d',
    '-v', 'C:\\project:/github/workspace',
    '-v', 'data:/var/lib',
    '--volume', '/tmp/runner:/github/actions-runner',
    'alpine:3.20',
]);

is_deeply(
    $mounts,
    {
        '/github/workspace'       => 'C:\\project',
        '/var/lib'                => 'data',
        '/github/actions-runner'  => '/tmp/runner',
    },
    'mounts are collected from a Docker command line',
);

is(
    to_host('/github/workspace/scripts/step-1.sh', $mounts),
    File::Spec->catfile('C:\\project', 'scripts', 'step-1.sh'),
    'container paths are mapped to the host using its own separator',
);

is(
    to_host('/github/actions-runner/env/step-1.env', $mounts),
    File::Spec->catfile('/tmp/runner', 'env', 'step-1.env'),
    'nested container paths are mapped',
);

is(to_host('/elsewhere/step-1.sh', $mounts), undef, 'unmounted paths are not mapped');
is(to_host(undef, $mounts), undef, 'an undefined container path is not mapped');

my $nested = mounts([ '-v', '/a:/github', '-v', '/a/b:/github/workspace' ]);
is(
    to_host('/github/workspace/step.sh', $nested),
    File::Spec->catfile('/a/b', 'step.sh'),
    'the longest matching mount wins',
);

done_testing;
