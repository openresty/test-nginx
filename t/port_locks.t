use strict;
use warnings;

use Test::More;
use Test::Nginx::Util;

{
    package TestBlock;

    sub new {
        return bless {}, shift;
    }

    sub name {
        return 'port lock cleanup test';
    }
}

my $server_port = Test::Nginx::Util::gen_rand_port();
ok(defined $server_port, 'allocated a process-wide server port');

my $server_locks = $Test::Nginx::Util::PortLockHandles{$server_port};
ok(defined $server_locks, 'retained the process-wide port lock');
ok(defined fileno($server_locks->[0]), 'process-wide port lock is open');

my $block_port = Test::Nginx::Util::gen_rand_port();
ok(defined $block_port, 'allocated a block-scoped random port');

my $block_locks = $Test::Nginx::Util::PortLockHandles{$block_port};
ok(defined $block_locks, 'retained the block-scoped port lock');
ok(defined fileno($block_locks->[0]), 'block-scoped port lock is open');

$Test::Nginx::Util::RandPorts = {
    TEST_NGINX_RAND_PORT_1 => $block_port,
};
Test::Nginx::Util::cleanup_test(TestBlock->new());

ok(!exists $Test::Nginx::Util::PortLockHandles{$block_port},
   'released the block-scoped port lock during cleanup');
ok(!defined fileno($block_locks->[0]), 'closed the block-scoped lock handle');
ok(exists $Test::Nginx::Util::PortLockHandles{$server_port},
   'kept the process-wide server-port lock');
ok(defined fileno($server_locks->[0]),
   'process-wide server-port lock remains open');

Test::Nginx::Util::release_port_locks($server_port);

SKIP: {
    open my $range, '<', '/proc/sys/net/ipv4/ip_local_port_range'
        or skip 'no Linux ephemeral port range', 1;
    my ($first, $last) = split /\s+/, <$range>;
    close $range;
    my @ports;
    for (1 .. 20) {
        push @ports, Test::Nginx::Util::gen_rand_port(1000, {}, 8);
    }
    my $overlap = grep {
        !defined $_ || ($_ <= $last && $_ + 7 >= $first)
    } @ports;
    is($overlap, 0, 'whole port blocks avoid the effective ephemeral range');
    Test::Nginx::Util::release_port_locks(grep { defined $_ } @ports);
}

done_testing();
