package Test::Nginx::Socket::Lua::Stream;

use 5.010001;
use Test::Nginx::Socket::Lua -Base;
use Test::Nginx::Util qw( $ServerPort $ServerAddr );

sub get_best_long_bracket_level ($);

my $port = $ENV{TEST_NGINX_STREAM_PORT} // ($ServerPort + 1);

add_block_preprocessor(sub {
    my ($block) = @_;

    my $name = $block->name;

    my $stream_config = $block->stream_config;
    my $stream_server_config = $block->stream_server_config;
    my $stream_req = $block->stream_request;

    if (defined $stream_server_config || defined $stream_config) {
        $stream_server_config //= '';
        $stream_config //= '';

        my $new_main_config = <<_EOC_;
stream {
$stream_config
    server {
        listen $port;

$stream_server_config
    }
}
_EOC_
        my $main_config = $block->main_config;
        if (defined $main_config) {
            $main_config .= $new_main_config;
        } else {
            $main_config = $new_main_config;
        }

        $block->set_value("main_config", $main_config);

        my $new_http_server_config = <<_EOC_;
            location = /t {
                content_by_lua_block {
                    local sock, err = ngx.socket.tcp()
                    assert(sock, err)

                    local ok, err = sock:connect("$ServerAddr", $port)
                    if not ok then
                        ngx.say("connect to stream server error: ", err)
                        return
                    end
_EOC_

        if (defined $stream_req) {
            my $level = get_best_long_bracket_level($stream_req);
            my $equals = "=" x $level;
            $new_http_server_config .= <<_EOC_;

                    local bytes, err = sock:send([$equals\[$stream_req\]$equals])
                    if not bytes then
                        ngx.say("send stream request error: ", err)
                        return
                    end
_EOC_
        }

        $new_http_server_config .= <<_EOC_;

                    local data, err = sock:receive("*a")
                    if not data then
                        ngx.say("receive stream response error: ", err)
                        return
                    end
_EOC_

        if (defined $block->response_body || defined $block->stream_response) {
            $new_http_server_config .= <<_EOC_;
                    ngx.print(data)
_EOC_
        }

        $new_http_server_config .= <<_EOC_;
                }
            }
_EOC_

        my $http_server_config = $block->config;
        if (defined $http_server_config) {
            $http_server_config .= $new_http_server_config;
        } else {
            $http_server_config = $new_http_server_config;
        }
        $block->set_value("config", $http_server_config);

        if (!defined $block->request) {
            $block->set_value("request", "GET /t\n");
        }
    }

    my $stream_response = $block->stream_response;
    if (defined $stream_response) {
        if (defined $block->response_body) {
            die "$name: conflicting response and response_body sections\n";
        }
        $block->set_value("response_body", $stream_response);
    }
});

sub get_best_long_bracket_level ($) {
    my ($s) = @_;

    my $equals = '';
    for (my $i = 0; $i < 100; $i++) {
        if ($s !~ /\[$equals\[|\]$equals\]/) {
            return $i;
        }

        my $equals .= "=";
    }

    die "failed to get the bets long bracket level\n";
}

1;
__END__

=encoding utf-8

=head1 NAME

Test::Nginx::Socket::Lua::Stream - Subclass of Test::Nginx::Socket::Lua to test NGINX stream modules

=head1 SYNOPSIS

    === TEST 1: simple test for ngx_stream_echo_module
    --- stream_server_config
    echo "Hello, stream echo!";

    --- stream_response
    Hello, stream echo!

    --- no_error_log
    [error]
    [alert]

=head1 Description

This module subclasses L<Test::Nginx::Socket::Lua> to provide handy abstractions for testing
NGINX stream-typed modules like ngx_stream_echo_module.

By default, the stream server listens on the port number N + 1 where N is the value
of the environment C<TEST_NGINX_SERVER_PORT> or C<TEST_NGINX_PORT> (both default to 1984). One can explicitly specify the
default stream serve's listening port via the C<TEST_NGINX_STREAM_PORT> environment.

=head1 Sections supported

All the existing sections of L<Test::Nginx::Socket::Lua> are automatically inherited.

The following new test sections are supported:

=head2 stream_server_config

Specifies custom content in the default C<server {}> configuration block (inside C<stream {}>) in F<nginx.conf>.

For example,

    --- stream_server_config
    echo "hello";

will generate something like below in F<nginx.conf>:

    stream {
        server {
            listen 1985;
            echo "Hello, stream echo!";
        }
    }

=head2 stream_response

Specifies expected response content sent from the default stream server. For example,

    === TEST 1: simple echo
    --- stream_server_config
    echo "Hello, stream echo!";

    --- stream_response
    Hello, stream echo!

=head1 AUTHOR

Yichun "agentzh" Zhang (章亦春) C<< <agentzh@gmail.com> >>, CloudFlare Inc.

=head1 COPYRIGHT & LICENSE

Copyright (c) 2009-2016, Yichun Zhang C<< <agentzh@gmail.com> >>, CloudFlare Inc.

This module is licensed under the terms of the BSD license.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

=over

=item *

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

=item *

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

=item *

Neither the name of the authors nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

=back

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=head1 SEE ALSO

L<Test::Nginx::Socket::Lua>, L<Test::Base>.
