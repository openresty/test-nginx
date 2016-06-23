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

=== TEST 1: filter chain (uc + lc)
--- response_body_filters eval
[\&::uc, \&::lc]
--- response_body_like eval
"<title>google</title>"


=== TEST 2: filter chain (uc)
--- response_body_filters eval
\&::uc
--- response_body_like eval
"<TITLE>GOOGLE</TITLE>"
