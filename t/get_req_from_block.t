# Unit tests for Test::Nginx::Socket::get_req_from_block
use Test::Nginx::Socket tests => 4;

my @block_list = blocks();
is_deeply(Test::Nginx::Socket::get_req_from_block($block_list[0]),
          [["GET / HTTP/1.1\r\nHost: localhost\r\nConnection: Close\r\n\r\n"]],
          $block_list[0]->name);
is_deeply(Test::Nginx::Socket::get_req_from_block($block_list[1]),
          [["POST /rrd/taratata HTTP/1.1\r\nHost: localhost\r\nConnection: Close"
            ."\r\nContent-Length: 15\r\n\r\nvalue=N%3A12345"]],
          $block_list[1]->name);
is_deeply(Test::Nginx::Socket::get_req_from_block($block_list[2]),
          [["HEAD /foo HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n".
            "GET /bar HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"]],
          $block_list[2]->name);
is_deeply(Test::Nginx::Socket::get_req_from_block($block_list[3]),
          [["POST /foo HTTP/1.1\r
Host: localhost\r
Connection: Close\r
Content-Type: application/x-www-form-urlencoded\r
Content-Length:3\r\n\r\nA", -1,
"B", -1,
"C"]],
          $block_list[3]->name);
__DATA__

=== request: basic string
--- request
GET /
=== request: with eval
--- request eval
use URI::Escape;
"POST /rrd/taratata
value=".uri_escape("N:12345")
=== pipelined_requests: simple array
--- pipelined_requests eval
["HEAD /foo", "GET /bar"]
=== raw_request: array
--- raw_request eval
["POST /foo HTTP/1.1\r
Host: localhost\r
Connection: Close\r
Content-Type: application/x-www-form-urlencoded\r
Content-Length:3\r\n\r\nA",
"B",
"C"]
