use strict;
use warnings;

use Cwd qw(getcwd);
use File::Temp qw(tempdir);
use Test::More;
use Test::Nginx::Util;

my $original_dir = getcwd();
my $temp_dir = tempdir(CLEANUP => 1);
chdir $temp_dir or die "failed to chdir to $temp_dir: $!";

{
    local $Test::Nginx::Util::UseValgrind = 1;
    local $Test::Nginx::Util::ValgrindQuick = 1;

    is(Test::Nginx::Util::_build_valgrind_command('nginx', 1),
       'valgrind -q --tool=memcheck --leak-check=no --track-origins=no '
       . '--read-inline-info=no --num-callers=30 --error-exitcode=1 '
       . '--exit-on-first-error=yes nginx',
       'quick mode uses the fast Memcheck options');
}

{
    local $Test::Nginx::Util::UseValgrind = '--tool=helgrind';
    local $Test::Nginx::Util::ValgrindQuick = 1;

    is(Test::Nginx::Util::_build_valgrind_command('nginx', 1),
       'valgrind -q --tool=memcheck --leak-check=no --track-origins=no '
       . '--read-inline-info=no --num-callers=30 --error-exitcode=1 '
       . '--exit-on-first-error=yes nginx',
       'quick mode overrides custom Valgrind options');
}

{
    local $Test::Nginx::Util::UseValgrind = 1;
    local $Test::Nginx::Util::ValgrindQuick = 1;
    my $warning = '';

    local $SIG{__WARN__} = sub { $warning .= shift };

    is(Test::Nginx::Util::_build_valgrind_command('nginx', 0),
       'valgrind -q --tool=memcheck --leak-check=no --track-origins=no '
       . '--read-inline-info=no --num-callers=30 --error-exitcode=1 nginx',
       'quick mode supports Valgrind without exit-on-first-error');
    like($warning, qr/does not support --exit-on-first-error/,
         'quick mode warns about unavailable exit-on-first-error');
}

{
    open my $suppress, '>', 'valgrind.suppress'
        or die "failed to create valgrind.suppress: $!";
    close $suppress;

    local $Test::Nginx::Util::UseValgrind = 1;
    local $Test::Nginx::Util::ValgrindQuick = 1;

    like(Test::Nginx::Util::_build_valgrind_command('nginx', 1),
         qr/--suppressions=valgrind\.suppress nginx\z/,
         'quick mode uses the project suppression file');
}

{
    local $Test::Nginx::Util::UseValgrind = 1;
    local $Test::Nginx::Util::ValgrindQuick = 0;

    like(Test::Nginx::Util::_build_valgrind_command('nginx', 1),
         qr/--leak-check=full .*--gen-suppressions=all/,
         'numeric Valgrind mode keeps the existing full configuration');
}

{
    local $Test::Nginx::Util::UseValgrind = '--tool=helgrind';
    local $Test::Nginx::Util::ValgrindQuick = 0;

    is(Test::Nginx::Util::_build_valgrind_command('nginx', 1),
       'valgrind -q --tool=helgrind nginx',
       'custom Valgrind options are unchanged outside quick mode');
}

chdir $original_dir or die "failed to chdir to $original_dir: $!";

done_testing();
