use lib 'lib';
use Test::Nginx::Socket;

plan tests => 15;

sub uc {
    return uc(shift);
}

sub lc {
    return lc(shift);
}

for my $block (blocks) {
    my $len = 1;

    if (ref $block->request || ref $block->request_eval) {
        my $r_req_list =  Test::Nginx::Socket::get_req_from_block($block);
        $len = $#$r_req_list + 1;
    }

    my $html = "<html><head><title>Google</title></head><body>Search me...</body></html>";
    my $raw_res = "HTTP/1.0 200 OK\r\n"
                . "Date: Fri, 31 Dec 1999 23:59:59 GMT\r\n"
                . "Content-Type: text/html\r\n"
                . "Content-Length: " . length($html)
                . "\r\n\r\n$html";

    for my $i (0 .. $len - 1) {
        my ($res, $raw_headers, $left) = Test::Nginx::Socket::parse_response("name", $raw_res, 0);
        Test::Nginx::Socket::transform_response_body($block, $res, $i);
        Test::Nginx::Socket::check_response_body($block, $res, undef, $i, 0, $len > 1);
    }
}

__DATA__

=== TEST 1: filter chain (uc + lc) - perl sub ref
--- response_body_filters eval
[\&::uc, \&::lc]
--- response_body_like eval
"<title>google</title>"



=== TEST 2: filter chain (uc + lc) - strings
--- response_body_filters eval
['uc', 'lc']
--- response_body_like eval
"<title>google</title>"



=== TEST 3: filter chain (uc + lc) - strings
--- response_body_filters: uc lc
--- response_body_like eval
"<title>google</title>"



=== TEST 4: filter chain (uc) - perl subs
--- response_body_filters eval
\&::uc
--- response_body_like eval
"<TITLE>GOOGLE</TITLE>"



=== TEST 5: filter chain (uc) - strings
--- response_body_filters
uc
--- response_body_like eval
"<TITLE>GOOGLE</TITLE>"



=== TEST 6: md5_hex
--- response_body_filters
md5_hex
--- response_body chop
127e6fbe19a927fd0b9282134ce045b2



=== TEST 7: sha1_hex
--- response_body_filters
sha1_hex
--- response_body chop
134d22ffe50c343216c553954f04e528f15c2325



=== TEST 8: two-dimensional array with one request
--- response_body_filters eval
[['sha1_hex']]
--- response_body chop
134d22ffe50c343216c553954f04e528f15c2325



=== TEST 9: two-dimensional array with one request and custom filter
--- response_body_filters eval
[[\&::uc]]
--- response_body_like eval
"<TITLE>GOOGLE</TITLE>"



=== TEST 10: two-dimensional array with mutli request
--- request eval
['GET /', 'GET /', 'GET /', 'GET /']
--- response_body_filters eval
[['sha1_hex'], ['md5_hex'], ['uc'], ['lc']]
--- response_body eval
[
'134d22ffe50c343216c553954f04e528f15c2325',
'127e6fbe19a927fd0b9282134ce045b2',
'<HTML><HEAD><TITLE>GOOGLE</TITLE></HEAD><BODY>SEARCH ME...</BODY></HTML>',
'<html><head><title>google</title></head><body>search me...</body></html>',
]



=== TEST 11: two-dimensional array with mutli requests and multi filters
--- request eval
['GET /', 'GET /']
--- response_body_filters eval
[['sha1_hex', 'uc'], ['md5_hex', 'uc']]
--- response_body eval
['134D22FFE50C343216C553954F04E528F15C2325', '127E6FBE19A927FD0B9282134CE045B2']
