use strict;
use warnings;

use Test::More;
use IPC::Run;
use Test::Nginx::Socket;

{
    package TimeoutBlock;
    sub name { 'curl timeout report' }
    sub curl_error { '(28) Operation timed out' }
}

{
    no warnings 'redefine';
    local *Test::Nginx::Socket::gen_curl_cmd_from_req = sub {
        return [$^X, '-e',
            'select undef, undef, undef, 0.15; '
            . 'print STDERR "curl: (28) Operation timed out\\n"; exit 28'];
    };
    local *Test::Nginx::Socket::use_http2 = sub { 0 };
    local *Test::Nginx::Socket::use_http3 = sub { 0 };
    my $block = bless {}, 'TimeoutBlock';
    my $response;
    eval {
        $response = Test::Nginx::Socket::send_http_req_by_curl(
            $block, "GET / HTTP/1.1\n\n", 0.05);
    };
    is($@, '', 'curl can report its own deadline before the outer watchdog fires');
    ok(!defined $response, 'the expected curl timeout has no HTTP response');
}

done_testing();
