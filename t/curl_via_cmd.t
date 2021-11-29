use lib 'lib';
use Test::Nginx::Socket 'no_plan';


run_tests();

__DATA__

=== TEST 1: sanity
--- config
    location /echo {
        echo hello;
    }
--- curl
--- http2
--- use_cmd
--- cmd: curl -i -sS --http2 --http2-prior-knowledge -X GET  http://127.0.0.1:1984/echo
--- response_body
hello
