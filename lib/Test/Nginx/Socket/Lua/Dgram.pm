package Test::Nginx::Socket::Lua::Dgram;

use v5.10.1;
use Test::Nginx::Socket::Lua -Base;
use Test::Nginx::Util qw( $ServerPort $ServerAddr );

sub get_best_long_bracket_level ($);
sub quote_as_lua_str ($);
sub gen_data_file ($);

my $port = $ENV{TEST_NGINX_DGRAM_PORT} // ($ServerPort + 1);
my $counter = 0;

add_block_preprocessor(sub {
    my ($block) = @_;

    my $name = $block->name;

    my $dgram_config = $block->dgram_config;
    my $dgram_server_config = $block->dgram_server_config;
    my $dgram_server_config2 = $block->dgram_server_config2;
    my $dgram_server_config3 = $block->dgram_server_config3;
    my $dgram_req = $block->dgram_request;
    my $dgram_req2 = $block->dgram_request2;
    my $dgram_req3 = $block->dgram_request3;

    if (defined $dgram_server_config || defined $dgram_config) {
        $dgram_server_config //= '';
        $dgram_config //= '';

        my $new_main_config = <<_EOC_;
stream {
$dgram_config
    server {
        listen $port udp;

$dgram_server_config
    }
_EOC_

        if (defined $dgram_server_config2) {
            my $port2 = $port + 1;
            $new_main_config .= <<_EOC_;
    server {
        listen $port2;

$dgram_server_config2
    }
_EOC_
        }


        if (defined $dgram_server_config3) {
            my $port3 = $port + 2;
            $new_main_config .= <<_EOC_;
    server {
        listen $port3;

$dgram_server_config3
    }
_EOC_
        }

        $new_main_config .= "}\n";

        my $main_config = $block->main_config;
        if (defined $main_config) {
            $main_config .= $new_main_config;
        } else {
            $main_config = $new_main_config;
        }

        $block->set_value("main_config", $main_config);

        my $new_http_server_config = <<_EOC_;
            lua_socket_log_errors off;

            location = /t {
                content_by_lua_block {
                    local sock, err = ngx.socket.udp()
                    assert(sock, err)

                    local ok, err = sock:setpeername("$ServerAddr", $port)
                    if not ok then
                        ngx.say("connect to stream server error: ", err)
                        return
                    end
_EOC_

        if (defined $dgram_req) {
            my $file = gen_data_file($dgram_req);
            $new_http_server_config .= <<_EOC_;
                    local f = assert(io.open('$file', 'r'))
                    local data = assert(f:read("*a"))
                    assert(f:close())
                    local bytes, err = sock:send(data)
                    if not bytes then
                        ngx.say("send stream request error: ", err)
                        return
                    end
_EOC_
        } else {
            $new_http_server_config .= <<_EOC_;
                    sock:send('trigger dgram req')
_EOC_
        }

        if (defined $block->abort) {
            my $timeout = Test::Nginx::Util::parse_time($block->timeout)
                          // Test::Nginx::Util::timeout();
            $timeout *= 1000;
            $new_http_server_config .= <<_EOC_;

                    sock:settimeout($timeout)
_EOC_
            $block->set_value("timeout", undef);
            $block->set_value("abort", undef);
        }

        if (defined $block->response_body
            || defined $block->response_body_like
            || defined $block->dgram_response
            || defined $block->dgram_response_like)
        {
            $new_http_server_config .= <<_EOC_;
                    local data, err = sock:receive()
                    if not data then
                      	sock:close()
                      	ngx.say("receive stream response error: ", err)
                      	return
                    end
_EOC_
            if (defined $block->log_dgram_response) {
                $new_http_server_config .= <<_EOC_;
                    print("stream response: ", data)
                    ngx.say("received ", #data, " bytes of response data.")
_EOC_
            } else {
                $new_http_server_config .= <<_EOC_;
                    ngx.print(data)
_EOC_
            }
        }

        if (defined $dgram_server_config2) {
            my $port2 = $port + 1;
            $new_http_server_config .= <<_EOC_;
                    local ok, err = sock:setpeername("$ServerAddr", $port2)
                    if not ok then
                        ngx.say("connect to stream server error: ", err)
                        return
                    end
_EOC_

            if (defined $dgram_req2) {
                my $file = gen_data_file($dgram_req2);
                $new_http_server_config .= <<_EOC_;
                    local f = assert(io.open('$file', 'r'))
                    local data = assert(f:read("*a"))
                    assert(f:close())
                    local bytes, err = sock:send(data)
                    if not bytes then
                        ngx.say("send stream request error: ", err)
                        return
                    end
_EOC_
            }

            $new_http_server_config .= <<_EOC_;
                    sock:send('trigger_dgram_req2')
_EOC_

            if (defined $block->response_body
                || defined $block->response_body_like
                || defined $block->dgram_response
                || defined $block->dgram_response_like)
            {
                $new_http_server_config .= <<_EOC_;
                    local data, err = sock:receive()
                    if not data then
                        sock:close()
                        ngx.say("receive stream response error: ", err)
                        return
                    end
                    ngx.print(data)
_EOC_
            }
        }

        if (defined $dgram_server_config3) {
            my $port3 = $port + 2;
            $new_http_server_config .= <<_EOC_;
                    local ok, err = sock:setpeername("$ServerAddr", $port3)
                    if not ok then
                        ngx.say("connect to stream server error: ", err)
                        return
                    end
_EOC_

            if (defined $dgram_req3) {
                my $file = gen_data_file($dgram_req3);
                $new_http_server_config .= <<_EOC_;
                    local f = assert(io.open('$file', 'r'))
                    local data = assert(f:read("*a"))
                    assert(f:close())
                    local bytes, err = sock:send(data)
                    if not bytes then
                        ngx.say("send stream request error: ", err)
                        return
                    end
_EOC_
            }

            $new_http_server_config .= <<_EOC_;
                    sock:send('trigger_dgram_req3')
                    local data, err = sock:receive()
                    if not data then
                        ngx.say("receive stream response error: ", err)
                        return
                    end
_EOC_

            if (defined $block->response_body
                || defined $block->response_body_like
                || defined $block->dgram_response
                || defined $block->dgram_response_like)
            {
                $new_http_server_config .= <<_EOC_;
                    local data, err = sock:receive()
                    if not data then
                        sock:close()
                        ngx.say("receive stream response error: ", err)
                        return
                    end
                    ngx.print(data)
_EOC_
            }
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

    my $dgram_response = $block->dgram_response;
    if (defined $dgram_response) {
        if (defined $block->response_body) {
            die "$name: conflicting dgram_response and response_body sections\n";
        }
        $block->set_value("response_body", $dgram_response);
    }

    my $dgram_response_like = $block->dgram_response_like;
    if (defined $dgram_response_like) {
        if (defined $block->response_body_like) {
            die "$name: conflicting dgram_response_like and response_body_like sections\n";
        }
        $block->set_value("response_body_like", $dgram_response_like);
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

sub quote_as_lua_str ($) {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/'/\\'/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\a/\\a/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\f/\\f/g;
    "'$s'";
}

sub gen_data_file ($) {
    my $s = shift;
    $counter++;
    if (!-d 't/tmp') {
        mkdir 't/tmp';
    }
    my $fname = "t/tmp/data$counter.txt";
    open my $fh, ">$fname"
        or die "cannot open $fname for writing: $!\n";
    print $fh $s;
    close $fh;
    return $fname;
}

END {
    system("rm -rf t/tmp");
}

1;
__END__

=encoding utf-8

=head1 NAME

Test::Nginx::Socket::Lua::Dgram - Subclass of Test::Nginx::Socket::Lua to test NGINX udp stream modules

=head1 SYNOPSIS

    === TEST 1: simple test for ngx_stream_echo_module
    --- dgram_server_config
    echo "Hello, stream echo!";

    --- dgram_response
    Hello, stream echo!

    --- no_error_log
    [error]
    [alert]

=head1 Description

This module subclasses L<Test::Nginx::Socket::Lua> to provide handy abstractions for testing
NGINX UDP stream-typed modules like ngx_stream_echo_module.

By default, the stream server listens on the port number N + 1 where N is the value
of the environment C<TEST_NGINX_SERVER_PORT> or C<TEST_NGINX_PORT> (both default to 1984). One can explicitly specify the
default stream server's listening port via the C<TEST_NGINX_DGRAM_PORT> environment.

=head1 Sections supported

All the existing sections of L<Test::Nginx::Socket::Lua> are automatically inherited.

The following new test sections are supported:

=head2 dgram_config

Specifies custom content in the default C<stream {}> configuration block.

=head2 dgram_server_config

Specifies custom content in the default C<server {}> configuration block (inside C<stream {}>) in F<nginx.conf>.

For example,

    --- dgram_server_config
    echo "hello";

will generate something like below in F<nginx.conf>:

    stream {
        server {
            listen 1985 udp;
            echo "Hello, stream echo!";
        }
    }

=head2 dgram_server_config2

Specifies a second stream server which listens on the port used by the first default server plus one.

=head2 dgram_server_config3

Specifies a third stream server which listens on the port used by the first default server plus two.

=head2 dgram_request

Specifies the request data sent to the first default stream server (defined by C<dgram_server_config>.

=head2 dgram_request2

Specifies the request data sent to the second default stream server (defined by C<dgram_server_config2>.

=head2 dgram_request3

Specifies the request data sent to the third default stream server (defined by C<dgram_server_config3>.

=head2 dgram_response

Specifies expected response content sent from the default stream servers. For example,

    === TEST 1: simple echo
    --- dgram_server_config
    echo "Hello, stream echo!";

    --- dgram_response
    Hello, stream echo!

When multiple default stream servers are specified (i.e., via C<dgram_server_config2> and
C<dgram_server_config3>, the responses from all these stream servers are concatenated together in the order of their specifications.

=head2 dgram_response_like

Specifies the regex pattern used to test the response data from the default stream servers.

=head2 log_dgram_response

Print out the stream response to the nginx error log with the "info" level instead
of sending it out to the stream client directly.

=head1 AUTHOR

Yichun "agentzh" Zhang (章亦春) C<< <agentzh@gmail.com> >>, CloudFlare Inc.

=head1 COPYRIGHT & LICENSE

Copyright (c) 2016, Yichun Zhang C<< <agentzh@gmail.com> >>, CloudFlare Inc.

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
