# NAME

Test::Nginx - Data-driven test scaffold for Nginx C module and Nginx/OpenResty-based libraries and applications

Table of Contents
=================

* [NAME](#name)
* [DESCRIPTION](#description)
* [User Guide](#user-guide)
* [Nginx C modules that use Test::Nginx to drive their test suites](#nginx-c-modules-that-use-testnginx-to-drive-their-test-suites)
* [SOURCE REPOSITORY](#source-repository)
* [DEBIAN PACKAGES](#debian-packages)
* [Community](#community)
    * [English Mailing List](#english-mailing-list)
    * [Chinese Mailing List](#chinese-mailing-list)
* [AUTHORS](#authors)
* [COPYRIGHT & LICENSE](#copyright--license)
* [SEE ALSO](#see-also)

# DESCRIPTION

This distribution provides two testing modules for Nginx C module development:

- [Test::Nginx::Socket](https://metacpan.org/pod/Test::Nginx::Socket) (This is highly recommended.)

    This library also has the following subclasses:

    - [Test::Nginx::Socket::Lua](https://metacpan.org/pod/Test::Nginx::Socket::Lua)
    - [Test::Nginx::Socket::Lua::Stream](https://metacpan.org/pod/Test::Nginx::Socket::Lua::Stream)

- [Test::Nginx::LWP](https://metacpan.org/pod/Test::Nginx::LWP) (This is obsolete.)

All of them are based on [Test::Base](https://metacpan.org/pod/Test::Base).

Usually, [Test::Nginx::Socket](https://metacpan.org/pod/Test::Nginx::Socket) is preferred because it works on a much lower
level and not that fault tolerant like [Test::Nginx::LWP](https://metacpan.org/pod/Test::Nginx::LWP).

Also, a lot of connection hang issues (like wrong `r->main->count` value in nginx
0.8.x) can only be captured by [Test::Nginx::Socket](https://metacpan.org/pod/Test::Nginx::Socket) because Perl's [LWP::UserAgent](https://metacpan.org/pod/LWP::UserAgent) client
will close the connection itself which will conceal such issues from
the testers.

Test::Nginx automatically starts an nginx instance (from the `PATH` env)
rooted at t/servroot/ and the default config template makes this nginx
instance listen on the port `1984` by default. One can specify a different
port number by setting his port number to the `TEST_NGINX_PORT` environment,
as in

    export TEST_NGINX_PORT=1989

# User Guide

You can find a comprehensive user guide on this test framework in my upcoming book "Programming OpenResty":

[https://openresty.gitbooks.io/programming-openresty/content/testing/index.html](https://openresty.gitbooks.io/programming-openresty/content/testing/index.html)

# Nginx C modules that use Test::Nginx to drive their test suites

- ngx\_echo

    [https://github.com/openresty/echo-nginx-module](https://github.com/openresty/echo-nginx-module)

- ngx\_headers\_more

    [https://github.com/openresty/headers-more-nginx-module](https://github.com/openresty/headers-more-nginx-module)

- ngx\_chunkin

    [http://wiki.nginx.org/NginxHttpChunkinModule](http://wiki.nginx.org/NginxHttpChunkinModule)

- ngx\_memc

    [http://wiki.nginx.org/NginxHttpMemcModule](http://wiki.nginx.org/NginxHttpMemcModule)

- ngx\_drizzle

    [https://github.com/openresty/drizzle-nginx-module](https://github.com/openresty/drizzle-nginx-module)

- ngx\_rds\_json

    [https://github.com/openresty/rds-json-nginx-module](https://github.com/openresty/rds-json-nginx-module)

- ngx\_rds\_csv

    [https://github.com/openresty/rds-csv-nginx-module](https://github.com/openresty/rds-csv-nginx-module)

- ngx\_xss

    [https://github.com/openresty/xss-nginx-module](https://github.com/openresty/xss-nginx-module)

- ngx\_srcache

    [https://github.com/openresty/srcache-nginx-module](https://github.com/openresty/srcache-nginx-module)

- ngx\_lua

    [https://github.com/openresty/lua-nginx-module](https://github.com/openresty/lua-nginx-module)

- ngx\_set\_misc

    [https://github.com/openresty/set-misc-nginx-module](https://github.com/openresty/set-misc-nginx-module)

- ngx\_array\_var

    [https://github.com/openresty/array-var-nginx-module](https://github.com/openresty/array-var-nginx-module)

- ngx\_form\_input

    [https://github.com/calio/form-input-nginx-module](https://github.com/calio/form-input-nginx-module)

- ngx\_iconv

    [https://github.com/calio/iconv-nginx-module](https://github.com/calio/iconv-nginx-module)

- ngx\_set\_cconv

    [https://github.com/liseen/set-cconv-nginx-module](https://github.com/liseen/set-cconv-nginx-module)

- ngx\_postgres

    [https://github.com/FRiCKLE/ngx\_postgres](https://github.com/FRiCKLE/ngx_postgres)

- ngx\_coolkit

    [https://github.com/FRiCKLE/ngx\_coolkit](https://github.com/FRiCKLE/ngx_coolkit)

- Naxsi

    [https://github.com/nbs-system/naxsi](https://github.com/nbs-system/naxsi)

- ngx\_shibboleth

    [https://github.com/nginx-shib/nginx-http-shibboleth](https://github.com/nginx-shib/nginx-http-shibboleth)

[Back to TOC](#table-of-contents)

# SOURCE REPOSITORY

This module has a Git repository on Github, which has access for all.

[https://github.com/openresty/test-nginx](https://github.com/openresty/test-nginx)

If you want a commit bit, feel free to drop me a line.

[Back to TOC](#table-of-contents)

# DEBIAN PACKAGES

António P. P. Almeida is maintaining a Debian package for this module
in his Debian repository: [http://debian.perusio.net](http://debian.perusio.net)

[Back to TOC](#table-of-contents)

# Community

## English Mailing List

The `openresty-en` mailing list is for English speakers: [https://groups.google.com/group/openresty-en](https://groups.google.com/group/openresty-en)

[Back to TOC](#table-of-contents)

## Chinese Mailing List

The `openresty` mailing list is for Chinese speakers: [https://groups.google.com/group/openresty](https://groups.google.com/group/openresty)

[Back to TOC](#table-of-contents)

# AUTHORS

Yichun Zhang (agentzh) `<agentzh@gmail.com>`

Antoine BONAVITA `<antoine.bonavita@gmail.com>`

[Back to TOC](#table-of-contents)

# COPYRIGHT & LICENSE

Copyright (c) 2009-2016, Yichun Zhang (agentzh) `<agentzh@gmail.com>`.

Copyright (c) 2011-2012, Antoine Bonavita `<antoine.bonavita@gmail.com>`.

This module is licensed under the terms of the BSD license.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
- Neither the name of the authors nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

[Back to TOC](#table-of-contents)

# SEE ALSO

[Test::Nginx::LWP](https://metacpan.org/pod/Test::Nginx::LWP), [Test::Nginx::Socket](https://metacpan.org/pod/Test::Nginx::Socket), [Test::Base](https://metacpan.org/pod/Test::Base).

[Back to TOC](#table-of-contents)

