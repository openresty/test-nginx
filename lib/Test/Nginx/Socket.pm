package Test::Nginx::Socket;

use lib 'lib';
use lib 'inc';

use Test::Base -Base;

our $VERSION = '0.13';

use Encode;
use Data::Dumper;
use Time::HiRes qw(sleep time);
use Test::LongString;
use Test::More;
use List::MoreUtils qw( any );
use IO::Select ();

our $ServerAddr = 'localhost';
our $Timeout = $ENV{TEST_NGINX_TIMEOUT} || 2;

use Test::Nginx::Util qw(
  setup_server_root
  write_config_file
  get_canon_version
  get_nginx_version
  trim
  show_all_chars
  parse_headers
  run_tests
  $ServerPortForClient
  $ServerPort
  $PidFile
  $ServRoot
  $ConfFile
  $RunTestHelper
  $RepeatEach
  worker_connections
  master_process_enabled
  config_preamble
  repeat_each
  workers
  master_on
  log_level
  no_shuffle
  no_root_location
  server_root
  html_dir
  server_port
  no_nginx_manager
);

#use Smart::Comments::JSON '###';
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use POSIX qw(EAGAIN);
use IO::Socket;

#our ($PrevRequest, $PrevConfig);

our $NoLongString = undef;

our @EXPORT = qw( plan run_tests run_test
  repeat_each config_preamble worker_connections
  master_process_enabled
  no_long_string workers master_on
  log_level no_shuffle no_root_location
  server_addr server_root html_dir server_port
  timeout no_nginx_manager
);

sub send_request ($$$$);

sub run_test_helper ($$);

sub error_event_handler ($);
sub read_event_handler ($);
sub write_event_handler ($);

sub no_long_string () {
    $NoLongString = 1;
}

sub server_addr (@) {
    if (@_) {

        #warn "setting server addr to $_[0]\n";
        $ServerAddr = shift;
    }
    else {
        return $ServerAddr;
    }
}

sub timeout (@) {
    if (@_) {
        $Timeout = shift;
    }
    else {
        $Timeout;
    }
}

$RunTestHelper = \&run_test_helper;

sub parse_request ($$) {
    my ( $name, $rrequest ) = @_;
    open my $in, '<', $rrequest;
    my $first = <$in>;
    if ( !$first ) {
        Test::More::BAIL_OUT("$name - Request line should be non-empty");
        die;
    }
    #$first =~ s/^\s+|\s+$//gs;
    my ($before_meth, $meth, $after_meth);
    my ($rel_url, $rel_url_size, $after_rel_url);
    my ($http_ver, $http_ver_size, $after_http_ver);
    my $end_line_size;
    if ($first =~ /^(\s*)(\S+)( *)((\S+)( *))?((\S+)( *))?(\s*)/) {
        $before_meth = length($1);
        $meth = $2;
        $after_meth = length($3);
        $rel_url = $5;
        $rel_url_size = length($5);
        $after_rel_url = length($6);
        $http_ver = $8;
        $http_ver_size = length($8);
        $after_http_ver = length($9);
        $end_line_size = length($10);
    } else {
        Test::More::BAIL_OUT("$name - Request line is not valid. Should be 'meth [url [version]]'");
        die;
    }
    if ( !defined $rel_url ) {
        $rel_url = '/';
        $rel_url_size = 0;
        $after_rel_url = 0;
    }
    if ( !defined $http_ver ) {
        $http_ver = 'HTTP/1.1';
        $http_ver_size = 0;
        $after_http_ver = 0;
    }

    #my $url = "http://localhost:$ServerPortForClient" . $rel_url;

    my $content = do { local $/; <$in> };
    my $content_size;
    if ( !defined $content ) {
        $content = "";
        $content_size = 0;
    } else {
        $content_size = length($content);
    }

    #warn Dumper($content);

    close $in;

    return {
        method  => $meth,
        url     => $rel_url,
        content => $content,
        http_ver => $http_ver,
        skipped_before_method => $before_meth,
        method_size => length($meth),
        skipped_after_method => $after_meth,
        url_size => $rel_url_size,
        skipped_after_url => $after_rel_url,
        http_ver_size => $http_ver_size,
        skipped_after_http_ver => $after_http_ver + $end_line_size,
        content_size => $content_size,
    };
}

sub get_moves($) {
    my ($parsed_req) = @_;
    return ({d => $parsed_req->{skipped_before_method}},
                          {s_s => $parsed_req->{method_size},
                           s_v => $parsed_req->{method}},
                          {d => $parsed_req->{skipped_after_method}},
                          {s_s => $parsed_req->{url_size},
                           s_v => $parsed_req->{url}},
                          {d => $parsed_req->{skipped_after_url}},
                          {s_s => $parsed_req->{http_ver_size},
                           s_v => $parsed_req->{http_ver}},
                          {d => $parsed_req->{skipped_after_http_ver}},
                          {s_s => 0,
                           s_v => $parsed_req->{headers}},
                          {s_s => $parsed_req->{content_size},
                           s_v => $parsed_req->{content}}
                         );
}

sub apply_moves($$) {
    my ($r_packet, $r_move) = @_;
    my $current_packet = shift @$r_packet;
    my $current_move = shift @$r_move;
    my $in_packet_cursor = 0;
    my @result = ();
    while (defined $current_packet) {
        if (!defined $current_move) {
            push @result, $current_packet;
            $current_packet = shift @$r_packet;
            $in_packet_cursor = 0;
        } elsif (defined $current_move->{d}) {
            # Remove stuff from packet
            if ($current_move->{d} > length($current_packet) - $in_packet_cursor) {
                # Eat up what is left of packet.
                $current_move->{d} -= length($current_packet) - $in_packet_cursor;
                if ($in_packet_cursor > 0) {
                    # Something in packet from previous iteration.
                    push @result, $current_packet;
                }
                $current_packet = shift @$r_packet;
                $in_packet_cursor = 0;
            } else {
                # Remove from current point in current packet
                substr($current_packet, $in_packet_cursor, $current_move->{d}) = '';
                $current_move = shift @$r_move;
            }
        } else {
            # Substitute stuff
            if ($current_move->{s_s} > length($current_packet) - $in_packet_cursor) {
                #   {s_s=>3, s_v=>GET} on ['GE', 'T /foo']
                $current_move->{s_s} -= length($current_packet) - $in_packet_cursor;
                substr($current_packet, $in_packet_cursor) = substr($current_move->{s_v}, 0, length($current_packet) - $in_packet_cursor);
                push @result, $current_packet;
                $current_move->{s_v} = substr($current_move->{s_v}, length($current_packet) - $in_packet_cursor);
                $current_packet = shift @$r_packet;
                $in_packet_cursor = 0;
            } else {
                substr($current_packet, $in_packet_cursor, $current_move->{s_s}) = $current_move->{s_v};
                $in_packet_cursor += length($current_move->{s_v});
                $current_move = shift @$r_move;
            }
        }
    }
    return \@result;
}
sub build_request_from_packets($$$$$) {
    my ( $name, $more_headers, $is_chunked, $conn_header, $request_packets ) = @_;
    # Request expressed as a serie of packets
    my $parsable_request = '';
    my @packet_length;
    for my $one_packet (@$request_packets) {
        $parsable_request .= $one_packet;
        push @packet_length, length($one_packet);
    }
    my $parsed_req = parse_request( $name, \$parsable_request );

    my $len_header = '';
    if (   !$is_chunked
        && defined $parsed_req->{content}
        && $parsed_req->{content} ne ''
        && $more_headers !~ /\bContent-Length:/ )
    {
        $parsed_req->{content} =~ s/^\s+|\s+$//gs;

        $len_header .=
          "Content-Length: " . length( $parsed_req->{content} ) . "\r\n";
    }

    $parsed_req->{method} .= ' ';
    $parsed_req->{url} .= ' ';
    $parsed_req->{http_ver} .= "\r\n";
    $parsed_req->{headers} = "Host: localhost\r\nConnection: $conn_header\r\n$more_headers$len_header\r\n";

    my @elements_moves = get_moves($parsed_req);
    return apply_moves($request_packets, \@elements_moves);
}

#  Returns an array of array of hashes. Each element of the first array is a
# request.
# Each request is an array of the "packets" to be sent, with an (optionnal)
# delay between packets to send.
#  Raw requests might be malformed intentionnaly (find what is wrong ;) ) :
# [[{value =>"POST /test HTTP/1.1\r\nHost: localhost\r\nConnection:keep-alive\r\n"},
#   {value =>"Content-Length:"},
#   {value=>"2\r\n\r\n"},
#   {value=>"ABZGET /test HTTP/1.0", delay_before => 15000}]]
# When sending, this will pause by the default delay between "POST..."
# and "Content-Length:" but also between "Content-Length:"
# and "2". It will also pause by 15 seconds before the body.
sub get_req_from_block ($) {
    my ($block) = @_;
    my $name = $block->name;

    my @req_list = ();

    if ( defined $block->raw_request ) {

        # Should be deprecated.
        if ( ref $block->raw_request && ref $block->raw_request eq 'ARRAY' ) {

            #  User already provided an array. So, he/she specified where the
            # data should be split. This allows for backward compatibility but
            # should use request with arrays as it provides the same functionnality.
            my @rr_list = ();
            my $i = 0;
            for my $elt ( @{ $block->raw_request } ) {
                if ($i == 0) {
                    push @rr_list, {value => $elt};
                } else {
                    push @rr_list, {value => $elt};
                }
                $i++;
            }
            push @req_list, \@rr_list;
        }
        else {
            push @req_list, [{value => $block->raw_request}];
        }
    }
    else {
        my $request;
        if ( defined $block->request_eval ) {

            # Should be deprecated.
            $request = eval $block->request_eval;
            if ($@) {
                warn $@;
            }
        }
        else {
            $request = $block->request;
        }

        my $is_chunked   = 0;
        my $more_headers = '';
        if ( $block->more_headers ) {
            my @headers = split /\n+/, $block->more_headers;
            for my $header (@headers) {
                next if $header =~ /^\s*\#/;
                my ( $key, $val ) = split /:\s*/, $header, 2;
                if ( lc($key) eq 'transfer-encoding' and $val eq 'chunked' ) {
                    $is_chunked = 1;
                }

                #warn "[$key, $val]\n";
                $more_headers .= "$key: $val\r\n";
            }
        }

        if ( $block->pipelined_requests ) {
            my $reqs = $block->pipelined_requests;
            if ( !ref $reqs || ref $reqs ne 'ARRAY' ) {
                Test::More::BAIL_OUT(
                    "$name - invalid entries in --- pipelined_requests");
            }
            my $i = 0;
            my $prq = "";
            for my $request (@$reqs) {
                my $conn_type;
                if ( $i++ == @$reqs - 1 ) {
                    $conn_type = 'close';
                }
                else {
                    $conn_type = 'keep-alive';
                }
                my $r_br = build_request_from_packets($name, $more_headers,
                                      $is_chunked, $conn_type,
                                      [$request] );
                $prq .= $$r_br[0];
            }
            push @req_list, [{value =>$prq}];
        }
        else {
            # request section.
            if (!ref $request) {
                # One request and it is a good old string.
                my $r_br = build_request_from_packets($name, $more_headers,
                                                      $is_chunked, 'Close',
                                                      [$request] );
                push @req_list, [{value => $$r_br[0]}];
            } elsif (ref $request eq 'ARRAY') {
                # A bunch of requests...
                for my $one_req (@$request) {
                    if (!ref $one_req) {
                        # This request is a good old string.
                        my $r_br = build_request_from_packets($name, $more_headers,
                                                      $is_chunked, 'Close',
                                                      [$one_req] );
                        push @req_list, [{value => $$r_br[0]}];
                    } elsif (ref $one_req eq 'ARRAY') {
                        # Request expressed as a serie of packets
                        my @packet_array = ();
                        for my $one_packet (@$one_req) {
                            if (!ref $one_packet) {
                                push @packet_array, $one_packet;
                            } else {
                                # Packet is a hash with a value...
                                push @packet_array, $one_packet->{value};
                            }
                        }
                        my $transformed_packet_array = build_request_from_packets($name, $more_headers,
                                                   $is_chunked, 'Close',
                                                   \@packet_array);
                        my @transformed_req = ();
                        my $idx = 0;
                        for my $one_transformed_packet (@$transformed_packet_array) {
                            if (!ref $$one_req[$idx]) {
                                push @transformed_req, {value => $one_transformed_packet};
                            } else {
                                $$one_req[$idx]->{value} = $one_transformed_packet;
                                push @transformed_req, $$one_req[$idx];
                            }
                            $idx++;
                        }
                        push @req_list, \@transformed_req;
                    }
                }
            } else {
                Test::More::BAIL_OUT(
                    "$name - invalid ---request : MUST be string or array of requests");
            }
        }

    }
    return \@req_list;
}

sub run_test_helper ($$) {
    my ( $block, $dry_run ) = @_;

    my $name = $block->name;

    my @req = get_req_from_block($block);

    if ( $#req < 0 ) {
        Test::More::BAIL_OUT("$name - request empty");
    }

    #warn "request: $req\n";

    my $timeout = $block->timeout;
    if ( !defined $timeout ) {
        $timeout = $Timeout;
    }

    my $raw_resp;

    if ($dry_run) {
        $raw_resp = "200 OK HTTP/1.0\r\nContent-Length: 0\r\n\r\n";
    }
    else {
        $raw_resp = send_request( $req[0][0], $block->raw_request_middle_delay,
            $timeout, $block->name );
    }

    #warn "raw resonse: [$raw_resp]\n";

    my ( $res, $raw_headers ) = parse_response( $name, $raw_resp );
    check_error_code($block, $res, $dry_run);
    check_raw_response_headers($block, $raw_headers, $dry_run);
    check_response_headers($block, $res, $raw_headers, $dry_run);
    check_response_body($block, $res, $dry_run);
}
sub check_error_code($$$) {
    my ($block, $res, $dry_run) = @_;
    my $name = $block->name;
    SKIP: {
        skip "$name - tests skipped due to the lack of directive $dry_run", 1 if $dry_run;
        if ( defined $block->error_code ) {
            is( $res->code || '', $block->error_code, "$name - status code ok" );
        } else {
            is( $res->code || '', 200, "$name - status code ok" );
        }
    }
}
sub check_raw_response_headers($$$) {
    my ($block, $raw_headers, $dry_run) = @_;
    my $name = $block->name;
    if ( defined $block->raw_response_headers_like ) {
        SKIP: {
            skip "$name - tests skipped due to the lack of directive $dry_run", 1 if $dry_run;
            my $expected = $block->raw_response_headers_like;
            like $raw_headers, qr/$expected/s, "$name - raw resp headers like";
        }
    }
}
sub check_response_headers($$$) {
    my ($block, $res, $raw_headers, $dry_run) = @_;
    my $name = $block->name;
    if ( defined $block->response_headers ) {
        my $headers = parse_headers( $block->response_headers );
        while ( my ( $key, $val ) = each %$headers ) {
            if ( !defined $val ) {

                #warn "HIT";
                SKIP: {
                    skip "$name - tests skipped due to the lack of directive $dry_run", 1 if $dry_run;
                    unlike $raw_headers, qr/^\s*\Q$key\E\s*:/ms,
                      "$name - header $key not present in the raw headers";
                }
                next;
            }

            my $actual_val = $res->header($key);
            if ( !defined $actual_val ) {
                $actual_val = '';
            }

            SKIP: {
                skip "$name - tests skipped due to the lack of directive $dry_run", 1 if $dry_run;
                is $actual_val, $val, "$name - header $key ok";
            }
        }
    }
    elsif ( defined $block->response_headers_like ) {
        my $headers = parse_headers( $block->response_headers_like );
        while ( my ( $key, $val ) = each %$headers ) {
            my $expected_val = $res->header($key);
            if ( !defined $expected_val ) {
                $expected_val = '';
            }
            SKIP: {
                skip "$name - tests skipped due to the lack of directive $dry_run", 1 if $dry_run;
                like $expected_val, qr/^$val$/, "$name - header $key like ok";
            }
        }
    }
}
sub check_response_body() {
    my ($block, $res, $dry_run) = @_;
    my $name = $block->name;
    if (   defined $block->response_body
        || defined $block->response_body_eval )
    {
        my $content = $res->content;
        if ( defined $content ) {
            $content =~ s/^TE: deflate,gzip;q=0\.3\r\n//gms;
            $content =~ s/^Connection: TE, close\r\n//gms;
        }

        my $expected;
        if ( $block->response_body_eval ) {
            $expected = eval $block->response_body_eval;
            if ($@) {
                warn $@;
            }
        }
        else {
            $expected = $block->response_body;
        }

        if ( $block->charset ) {
            Encode::from_to( $expected, 'UTF-8', $block->charset );
        }

        $expected =~ s/\$ServerPort\b/$ServerPort/g;
        $expected =~ s/\$ServerPortForClient\b/$ServerPortForClient/g;

        #warn show_all_chars($content);

        #warn "no long string: $NoLongString";
        SKIP: {
            skip "$name - tests skipped due to the lack of directive $dry_run", 1 if $dry_run;
            if ($NoLongString) {
                is( $content, $expected,
                    "$name - response_body - response is expected" );
            }
            else {
                is_string( $content, $expected,
                    "$name - response_body - response is expected" );
            }
        }

    }
    elsif ( defined $block->response_body_like ) {
        my $content = $res->content;
        if ( defined $content ) {
            $content =~ s/^TE: deflate,gzip;q=0\.3\r\n//gms;
        }
        $content =~ s/^Connection: TE, close\r\n//gms;
        my $expected_pat = $block->response_body_like;
        $expected_pat =~ s/\$ServerPort\b/$ServerPort/g;
        $expected_pat =~ s/\$ServerPortForClient\b/$ServerPortForClient/g;
        my $summary = trim($content);

        SKIP: {
            skip "$name - tests skipped due to the lack of directive $dry_run", 1 if $dry_run;
            like( $content, qr/$expected_pat/s,
                "$name - response_body_like - response is expected ($summary)"
            );
        }
    }
}
sub parse_response($$) {
    my ( $name, $raw_resp ) = @_;

    my $raw_headers = '';
    if ( $raw_resp =~ /(.*?)\r\n\r\n/s ) {

        #warn "\$1: $1";
        $raw_headers = $1;
    }

    #warn "raw headers: $raw_headers\n";

    my $res = HTTP::Response->parse($raw_resp);
    my $enc = $res->header('Transfer-Encoding');

    if ( defined $enc && $enc eq 'chunked' ) {

        #warn "Found chunked!";
        my $raw = $res->content;
        if ( !defined $raw ) {
            $raw = '';
        }

        my $decoded = '';
        while (1) {
            if ( $raw =~ /\G 0 [\ \t]* \r\n \r\n /gcsx ) {
                last;
            }
            if ( $raw =~ m{ \G [\ \t]* ( [A-Fa-f0-9]+ ) [\ \t]* \r\n }gcsx ) {
                my $rest = hex($1);

                #warn "chunk size: $rest\n";
                my $bit_sz = 32765;
                while ( $rest > 0 ) {
                    my $bit = $rest < $bit_sz ? $rest : $bit_sz;

                    #warn "bit: $bit\n";
                    if ( $raw =~ /\G(.{$bit})/gcs ) {
                        $decoded .= $1;

                        #warn "decoded: [$1]\n";
                    }
                    else {
                        fail(
"$name - invalid chunked data received (not enought octets for the data section)"
                        );
                        return;
                    }

                    $rest -= $bit;
                }
                if ( $raw !~ /\G\r\n/gcs ) {
                    fail(
                        "$name - invalid chunked data received (expected CRLF)."
                    );
                    return;
                }
            }
            elsif ( $raw =~ /\G.+/gcs ) {
                fail "$name - invalid chunked body received: $&";
                return;
            }
            else {
                fail "$name - no last chunk found - $raw";
                return;
            }
        }

        #warn "decoded: $decoded\n";
        $res->content($decoded);
    }
    return ( $res, $raw_headers );
}

sub send_request ($$$$) {
    my ( $req, $middle_delay, $timeout, $name ) = @_;

    my @req_bits = ref $req ? @$req : ($req);

    my $sock = IO::Socket::INET->new(
        PeerAddr => $ServerAddr,
        PeerPort => $ServerPortForClient,
        Proto    => 'tcp'
    ) or die "Can't connect to $ServerAddr:$ServerPortForClient: $!\n";

    my $flags = fcntl $sock, F_GETFL, 0
      or die "Failed to get flags: $!\n";

    fcntl $sock, F_SETFL, $flags | O_NONBLOCK
      or die "Failed to set flags: $!\n";

    my $ctx = {
        resp         => '',
        write_offset => 0,
        buf_size     => 1024,
        req_bits     => \@req_bits,
        write_buf    => (shift @req_bits)->{"value"},
        middle_delay => $middle_delay,
        sock         => $sock,
        name         => $name,
    };

    my $readable_hdls = IO::Select->new($sock);
    my $writable_hdls = IO::Select->new($sock);
    my $err_hdls      = IO::Select->new($sock);

    while (1) {
        if (   $readable_hdls->count == 0
            && $writable_hdls->count == 0
            && $err_hdls->count == 0 )
        {
            last;
        }

        my ( $new_readable, $new_writable, $new_err ) =
          IO::Select->select( $readable_hdls, $writable_hdls, $err_hdls,
            $timeout );

        if (   !defined $new_err
            && !defined $new_readable
            && !defined $new_writable )
        {

            # timed out
            timeout_event_handler($ctx);
            last;
        }

        for my $hdl (@$new_err) {
            next if !defined $hdl;

            error_event_handler($ctx);

            if ( $err_hdls->exists($hdl) ) {
                $err_hdls->remove($hdl);
            }

            if ( $readable_hdls->exists($hdl) ) {
                $readable_hdls->remove($hdl);
            }

            if ( $writable_hdls->exists($hdl) ) {
                $writable_hdls->remove($hdl);
            }

            for my $h (@$readable_hdls) {
                next if !defined $h;
                if ( $h eq $hdl ) {
                    undef $h;
                    last;
                }
            }

            for my $h (@$writable_hdls) {
                next if !defined $h;
                if ( $h eq $hdl ) {
                    undef $h;
                    last;
                }
            }

            close $hdl;
        }

        for my $hdl (@$new_readable) {
            next if !defined $hdl;

            my $res = read_event_handler($ctx);
            if ( !$res ) {

                # error occured
                if ( $err_hdls->exists($hdl) ) {
                    $err_hdls->remove($hdl);
                }

                if ( $readable_hdls->exists($hdl) ) {
                    $readable_hdls->remove($hdl);
                }

                if ( $writable_hdls->exists($hdl) ) {
                    $writable_hdls->remove($hdl);
                }

                for my $h (@$writable_hdls) {
                    next if !defined $h;
                    if ( $h eq $hdl ) {
                        undef $h;
                        last;
                    }
                }

                close $hdl;
            }
        }

        for my $hdl (@$new_writable) {
            next if !defined $hdl;

            my $res = write_event_handler($ctx);
            if ( !$res ) {

                # error occured
                if ( $err_hdls->exists($hdl) ) {
                    $err_hdls->remove($hdl);
                }

                if ( $readable_hdls->exists($hdl) ) {
                    $readable_hdls->remove($hdl);
                }

                if ( $writable_hdls->exists($hdl) ) {
                    $writable_hdls->remove($hdl);
                }

                close $hdl;
            }

            if ( $res == 2 ) {
                if ( $writable_hdls->exists($hdl) ) {
                    $writable_hdls->remove($hdl);
                }
            }
        }
    }

    return $ctx->{resp};
}

sub timeout_event_handler ($) {
    my $ctx = shift;
    warn "ERROR: socket client: timed out - $ctx->{name}\n";
}

sub error_event_handler ($) {
    warn "exception occurs on the socket: $!\n";
}

sub write_event_handler ($) {
    my ($ctx) = @_;

    while (1) {
        return undef if !defined $ctx->{write_buf};

        my $rest = length( $ctx->{write_buf} ) - $ctx->{write_offset};

  #warn "offset: $write_offset, rest: $rest, length ", length($write_buf), "\n";
  #die;

        if ( $rest > 0 ) {
            my $bytes = syswrite(
                $ctx->{sock}, $ctx->{write_buf},
                $rest,        $ctx->{write_offset}
            );

            if ( !defined $bytes ) {
                if ( $! == EAGAIN ) {

                    #warn "write again...";
                    #sleep 0.002;
                    return 1;
                }
                my $errmsg = "write failed: $!";
                warn "$errmsg\n";
                if ( !$ctx->{resp} ) {
                    $ctx->{resp} = "$errmsg";
                }
                return undef;
            }

            #warn "wrote $bytes bytes.\n";
            $ctx->{write_offset} += $bytes;
        }
        else {
            my $next_send = shift @{ $ctx->{req_bits} } or return 2;
            $ctx->{write_buf} = $next_send->{'value'};
            $ctx->{write_offset} = 0;
            my $wait_time;
            if (!defined $next_send->{'delay_before'}) {
                if (defined $ctx->{middle_delay}) {
                    $wait_time = $ctx->{middle_delay};
                }
            } else {
                $wait_time = $next_send->{'delay_before'};
            }
            if ($wait_time) {
                #warn "sleeping..";
                sleep $wait_time;
            }
        }
    }

    # impossible to reach here...
    return undef;
}

sub read_event_handler ($) {
    my ($ctx) = @_;
    while (1) {
        my $read_buf;
        my $bytes = sysread( $ctx->{sock}, $read_buf, $ctx->{buf_size} );

        if ( !defined $bytes ) {
            if ( $! == EAGAIN ) {

                #warn "read again...";
                #sleep 0.002;
                return 1;
            }
            $ctx->{resp} = "500 read failed: $!";
            return undef;
        }

        if ( $bytes == 0 ) {
            return undef;    # connection closed
        }

        $ctx->{resp} .= $read_buf;

        #warn "read $bytes ($read_buf) bytes.\n";
    }

    # impossible to reach here...
    return undef;
}

1;
__END__

=encoding utf-8

=head1 NAME

Test::Nginx::Socket - Socket-backed test scaffold for the Nginx C modules

=head1 SYNOPSIS

    use Test::Nginx::Socket;

    plan tests => $Test::Nginx::Socket::RepeatEach * 2 * blocks();

    run_tests();

    __DATA__

    === TEST 1: sanity
    --- config
        location /echo {
            echo_before_body hello;
            echo world;
        }
    --- request
        GET /echo
    --- response_body
    hello
    world
    --- error_code: 200


    === TEST 2: set Server
    --- config
        location /foo {
            echo hi;
            more_set_headers 'Server: Foo';
        }
    --- request
        GET /foo
    --- response_headers
    Server: Foo
    --- response_body
    hi


    === TEST 3: clear Server
    --- config
        location /foo {
            echo hi;
            more_clear_headers 'Server: ';
        }
    --- request
        GET /foo
    --- response_headers_like
    Server: nginx.*
    --- response_body
    hi


    === TEST 3: chunk size too small
    --- config
        chunkin on;
        location /main {
            echo_request_body;
        }
    --- more_headers
    Transfer-Encoding: chunked
    --- request eval
    "POST /main
    4\r
    hello\r
    0\r
    \r
    "
    --- error_code: 400
    --- response_body_like: 400 Bad Request

=head1 DESCRIPTION

This module provides a test scaffold based on non-blocking L<IO::Socket> for automated testing in Nginx C module development.

This class inherits from L<Test::Base>, thus bringing all its
declarative power to the Nginx C module testing practices.

You need to terminate or kill any Nginx processes before running the test suite if you have changed the Nginx server binary. Normally it's as simple as

  killall nginx
  PATH=/path/to/your/nginx-with-memc-module:$PATH prove -r t

This module will create a temporary server root under t/servroot/ of the current working directory and starts and uses the nginx executable in the PATH environment.

You will often want to look into F<t/servroot/logs/error.log>
when things go wrong ;)

=head1 Sections supported

The following sections are supported:

=over

=item config

=item http_config

=item request

=item request_eval

=item more_headers

=item response_body

=item response_body_eval

=item response_body_like

=item response_headers

=item response_headers_like

=item error_code

=item raw_request

=item user_files

=item skip_nginx

=item skip_nginx2

Both string scalar and string arrays are supported as values.

=item raw_request_middle_delay

Delay in sec between sending successive packets in the "raw_request" array value.

=back

=head1 Samples

You'll find live samples in the following Nginx 3rd-party modules:

=over

=item ngx_echo

L<http://github.com/agentzh/echo-nginx-module>

=item ngx_chunkin

L<http://wiki.nginx.org/NginxHttpChunkinModule>

=item ngx_memc

L<http://wiki.nginx.org/NginxHttpMemcModule>

=item ngx_drizzle

L<http://github.com/chaoslawful/drizzle-nginx-module>

=item ngx_rds_json

L<http://github.com/agentzh/rds-json-nginx-module>

=item ngx_xss

L<http://github.com/agentzh/xss-nginx-module>

=item ngx_srcache

L<http://github.com/agentzh/srcache-nginx-module>

=item ngx_lua

L<http://github.com/chaoslawful/lua-nginx-module>

=item ngx_set_misc

L<http://github.com/agentzh/set-misc-nginx-module>

=item ngx_array_var

L<http://github.com/agentzh/array-var-nginx-module>

=item ngx_form_input

L<http://github.com/calio/form-input-nginx-module>

=item ngx_iconv

L<http://github.com/calio/iconv-nginx-module>

=item ngx_set_cconv

L<http://github.com/liseen/set-cconv-nginx-module>

=item ngx_postgres

L<http://github.com/FRiCKLE/ngx_postgres>

=item ngx_coolkit

L<http://github.com/FRiCKLE/ngx_coolkit>

=back

=head1 SOURCE REPOSITORY

This module has a Git repository on Github, which has access for all.

    http://github.com/agentzh/test-nginx

If you want a commit bit, feel free to drop me a line.

=head1 AUTHOR

agentzh (章亦春) C<< <agentzh@gmail.com> >>

=head1 COPYRIGHT & LICENSE

Copyright (c) 2009-2011, Taobao Inc., Alibaba Group (L<http://www.taobao.com>).

Copyright (c) 2009-2011, agentzh C<< <agentzh@gmail.com> >>.

This module is licensed under the terms of the BSD license.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

=over

=item *

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

=item *

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

=item *

Neither the name of the Taobao Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission. 

=back

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 

=head1 SEE ALSO

L<Test::Nginx::LWP>, L<Test::Base>.

