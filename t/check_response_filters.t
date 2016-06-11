use lib 'lib';
use Test::Nginx::Socket tests => 1;

my @block_list = blocks();
my $i = 0;  # Use $i to make copy/paste of tests easier.

my $html = "<html><head><title>Google</title></head><body>Search me...</body></html>";
my $raw_res="HTTP/1.0 200 OK\r\nDate: Fri, 31 Dec 1999 23:59:59 GMT\r\nContent-Type: text/html\r\nContent-Length: ".length($html)."\r\n\r\n".$html;
my ( $res, $raw_headers, $left ) = Test::Nginx::Socket::parse_response("name", $raw_res, 0);
Test::Nginx::Socket::check_response_filters($block_list[$i], $res);
Test::Nginx::Socket::check_response_body($block_list[$i], $res, undef, 0, 0, 0);

__DATA__

=== response_body_filters: filter chain
--- response_body_filters eval
[\&CORE::uc, \&CORE::lc, \&CORE::uc]
--- response_body_like eval
"<TITLE>GOOGLE</TITLE>"
