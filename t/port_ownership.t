use strict;
use warnings;

use File::Temp qw(tempdir);
use POSIX ();
use Test::More;
use Test::Nginx::Util;

plan skip_all => 'requires Linux /proc and fuser'
    unless -d '/proc/self' && length qx{command -v fuser};

my $root = tempdir(CLEANUP => 1);
my @children;
END {
    local $?;
    for my $pid (@children) {
        kill 'TERM', $pid;
        waitpid $pid, 0;
    }
}

sub listener {
    my $server_root = shift;
    pipe(my $reader, my $writer) or die "pipe: $!";
    my $pid = fork();
    defined $pid or die "fork: $!";
    if ($pid == 0) {
        close $reader;
        open STDOUT, '>&', $writer or POSIX::_exit(1);
        exec $^X, '-e', q{
            use IO::Socket::INET;
            $| = 1;
            my $socket = IO::Socket::INET->new(
                LocalAddr => '127.0.0.1', LocalPort => 0,
                Listen => 1, Proto => 'tcp') or die $!;
            print $socket->sockport, "\n";
            sleep 60;
        }, $server_root or POSIX::_exit(1);
    }
    push @children, $pid;
    close $writer;
    my $port = <$reader>;
    close $reader;
    defined $port or die 'listener did not start';
    chomp $port;
    return ($pid, $port);
}

my ($own_pid, $own_port) = listener("$root/own");
my ($foreign_pid, $foreign_port) = listener("$root/own-other");

my @killed;
my $warnings = '';
{
    no warnings 'redefine';
    local *Test::Nginx::Util::kill_process = sub { push @killed, shift };
    local $Test::Nginx::Util::ServRoot = "$root/own";
    local $SIG{__WARN__} = sub { $warnings .= shift };
    Test::Nginx::Util::_kill_port_holders('tcp', $foreign_port, 'ownership');
    is_deeply(\@killed, [], 'does not kill a parallel test with a shared root prefix');
    ok(kill(0, $foreign_pid), 'foreign port holder remains alive');
    like($warnings, qr/foreign or unverified pid/, 'reports the foreign holder');
    Test::Nginx::Util::_kill_port_holders('tcp', $own_port, 'ownership');
    is_deeply(\@killed, [$own_pid], 'cleans up the verified server root');
}

# TCP fixtures are Perl children, so normal cleanup must not send SIGQUIT.
pipe(my $ready_reader, my $ready_writer) or die "pipe: $!";
my $fixture_pid = fork();
defined $fixture_pid or die "fork: $!";
if ($fixture_pid == 0) {
    close $ready_reader;
    Test::More->builder->no_ending(1);
    my $finish = sub {
        open my $out, '>', "$root/signal" or POSIX::_exit(1);
        print {$out} shift;
        close $out;
        POSIX::_exit(0);
    };
    $SIG{TERM} = sub { $finish->('TERM') };
    $SIG{QUIT} = sub { $finish->('QUIT') };
    print {$ready_writer} "ready\n";
    close $ready_writer;
    sleep 30;
    POSIX::_exit(1);
}
close $ready_writer;
<$ready_reader>;
close $ready_reader;
{
    local $Test::Nginx::Util::TcpServerPid = $fixture_pid;
    Test::Nginx::Util::kill_process($fixture_pid, 1, 'fixture cleanup');
}
open my $signal, '<', "$root/signal" or die "missing signal result: $!";
is(do { local $/; <$signal> }, 'TERM', 'uses TERM for the Perl fixture');
close $signal;
ok(!kill(0, $fixture_pid), 'reaped the fixture process');

done_testing();
