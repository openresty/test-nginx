use lib 'lib';
use Test::Nginx::Socket;
use Test::More;

plan tests => 3;

my @json_list = (
    '{"c":"1","a":[1,2], "d":{"d":"4", "a":"1"}}',
    '["a", "b", 1, true, {"b": 1, "a": 2}]',
    '{"c":"1","a.com/test?a=":["http://test.com?d=1&c=2",2], "d":{"test2.com?d=3&a=1":"4", "a":"test3.com?f=3&a=3"}}'
);

my $idx = 0;
for my $block (blocks) {
    my $json = $json_list[$idx];

    my $raw_res = "HTTP/1.0 200 OK\r\n"
        . "Date: Fri, 31 Dec 1999 23:59:59 GMT\r\n"
        . "Content-Type: application/json; charset=utf-8\r\n"
        . "Content-Length: " . length($json)
        . "\r\n\r\n$json";

    my ($res, $raw_headers, $left) = Test::Nginx::Socket::parse_response("name", $raw_res, 0);
    Test::Nginx::Socket::transform_response_body($block, $res, 0);
    Test::Nginx::Socket::check_response_body($block, $res, undef, 0, 0, 0);

    $idx += 1;
}

__DATA__

=== TEST 1: hash sort
--- response_body_filters
json_sort
--- response_body eval
'{"a":[1,2],"c":"1","d":{"a":"1","d":"4"}}'

=== TEST 2: array json
--- response_body_filters
json_sort
--- response_body eval
'["a","b",1,true,{"a":2,"b":1}]'

=== TEST 3: json url sort
--- response_body_filters
json_sort
--- response_body eval
'{"a.com/test?a=":["http://test.com?c=2&d=1",2],"c":"1","d":{"a":"test3.com?a=3&f=3","test2.com?a=1&d=3":"4"}}'


