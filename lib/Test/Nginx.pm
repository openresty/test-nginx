package Test::Nginx;

use strict;
use warnings;

our $VERSION = '0.28';

__END__

=encoding utf-8

=head1 NAME

Test::Nginx - Data-driven test scaffold for Nginx C module and Nginx/OpenResty-based libraries and applications

=head1 DESCRIPTION

This distribution provides two testing modules for Nginx C module development:

=over

=item *

L<Test::Nginx::Socket> (This is highly recommended.)

This library also has the following subclasses:

=over

=item *

L<Test::Nginx::Socket::Lua>

=item *

L<Test::Nginx::Socket::Lua::Stream>

=item *

L<Test::Nginx::Socket::Lua::Dgram>

=back

=item *

L<Test::Nginx::LWP> (This is obsolete.)

=back

All of them are based on L<Test::Base>.

Usually, L<Test::Nginx::Socket> is preferred because it works on a much lower
level and not that fault tolerant like L<Test::Nginx::LWP>.

Also, a lot of connection hang issues (like wrong C<< r->main->count >> value in nginx
0.8.x) can only be captured by L<Test::Nginx::Socket> because Perl's L<LWP::UserAgent> client
will close the connection itself which will conceal such issues from
the testers.

Test::Nginx automatically starts an nginx instance (from the C<PATH> env)
rooted at t/servroot/ and the default config template makes this nginx
instance listen on the port C<1984> by default. One can specify a different
port number by setting his port number to the C<TEST_NGINX_PORT> environment,
as in

    export TEST_NGINX_PORT=1989

=head1 User Guide

You can find a comprehensive user guide on this test framework in my upcoming book "Programming OpenResty":

L<https://openresty.gitbooks.io/programming-openresty/content/testing/index.html>

=head1 Nginx C modules that use Test::Nginx to drive their test suites

=over

=item ngx_echo

L<https://github.com/openresty/echo-nginx-module>

=item ngx_headers_more

L<https://github.com/openresty/headers-more-nginx-module>

=item ngx_chunkin

L<http://wiki.nginx.org/NginxHttpChunkinModule>

=item ngx_memc

L<http://wiki.nginx.org/NginxHttpMemcModule>

=item ngx_drizzle

L<https://github.com/openresty/drizzle-nginx-module>

=item ngx_rds_json

L<https://github.com/openresty/rds-json-nginx-module>

=item ngx_rds_csv

L<https://github.com/openresty/rds-csv-nginx-module>

=item ngx_xss

L<https://github.com/openresty/xss-nginx-module>

=item ngx_srcache

L<https://github.com/openresty/srcache-nginx-module>

=item ngx_lua

L<https://github.com/openresty/lua-nginx-module>

=item ngx_set_misc

L<https://github.com/openresty/set-misc-nginx-module>

=item ngx_array_var

L<https://github.com/openresty/array-var-nginx-module>

=item ngx_form_input

L<https://github.com/calio/form-input-nginx-module>

=item ngx_iconv

L<https://github.com/calio/iconv-nginx-module>

=item ngx_set_cconv

L<https://github.com/liseen/set-cconv-nginx-module>

=item ngx_postgres

L<https://github.com/FRiCKLE/ngx_postgres>

=item ngx_coolkit

L<https://github.com/FRiCKLE/ngx_coolkit>

=item Naxsi

L<https://github.com/nbs-system/naxsi>

=item ngx_shibboleth

L<https://github.com/nginx-shib/nginx-http-shibboleth>

=back

=head1 INSTALLATION

If you have `cpan` installed, you can simply run the command to install this module:

    sudo cpan Test::Nginx

If you want to install from the source code directory directly, you can run

    sudo cpan .

If you prefer F<cpanm> to F<cpan> (like I do!), you can replace C<cpan> in the commands above with C<cpanm>.

Otherwise you can install this module in the good old way below:

    perl Makefile.PL
    make
    sudo make install

=head1 SOURCE REPOSITORY

This module has a Git repository on Github, which has access for all.

L<https://github.com/openresty/test-nginx>

If you want a commit bit, feel free to drop me a line.

=head1 DEBIAN PACKAGES

António P. P. Almeida is maintaining a Debian package for this module
in his Debian repository: L<http://debian.perusio.net>

=head1 Community

=head2 English Mailing List

The C<openresty-en> mailing list is for English speakers: L<https://groups.google.com/group/openresty-en>

=head2 Chinese Mailing List

The C<openresty> mailing list is for Chinese speakers: L<https://groups.google.com/group/openresty>

=head1 AUTHORS

Yichun Zhang (agentzh) C<< <agentzh@gmail.com> >>, OpenResty Inc.

Antoine BONAVITA C<< <antoine.bonavita@gmail.com> >>

=head1 COPYRIGHT & LICENSE

Copyright (c) 2009-2017, Yichun Zhang (agentzh) C<< <agentzh@gmail.com> >>, OpenResty Inc.

Copyright (c) 2011-2012, Antoine Bonavita C<< <antoine.bonavita@gmail.com> >>.

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

L<Test::Nginx::LWP>, L<Test::Nginx::Socket>, L<Test::Base>.

