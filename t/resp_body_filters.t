use lib 'lib';
use Test::Nginx::Socket tests => 1;

sub uc {
    return uc(shift);
}

sub lc {
    return lc(shift);
}

my @block_list = blocks();
my $i = 0;  # Use $i to make copy/paste of tests easier.

my $html = "<html><head><title>Google</title></head><body>Search me...</body></html>";
my $raw_res="HTTP/1.0 200 OK\r\nDate: Fri, 31 Dec 1999 23:59:59 GMT\r\nContent-Type: text/html\r\nContent-Length: ".length($html)."\r\n\r\n".$html;
my ( $res, $raw_headers, $left ) = Test::Nginx::Socket::parse_response("name", $raw_res, 0);
Test::Nginx::Socket::transform_response_body($block_list[$i], $res);
Test::Nginx::Socket::check_response_body($block_list[$i], $res, undef, 0, 0, 0);

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
