use lib 'lib';
use Test::Nginx::Socket;
use Test::Nginx::Util;
use Test::More;

for (blocks()) {
    Test::Nginx::Util::run_test($_);
}

done_testing();

__DATA__
=== todo: basic
--- config
--- todo: 1: reason
