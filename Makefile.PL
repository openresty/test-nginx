use strict;
use lib '.';
use inc::Module::Install;

name            ('Test-Nginx');
license         ('bsd');
perl_version    ('5.006001');
repository      ('https://github.com/openresty/test-nginx');
all_from        ('lib/Test/Nginx.pm');

requires        ('Test::Base');
requires        ('Text::Diff');
requires        ('Test::LongString');
requires        ('IO::Socket');
requires        ('Time::HiRes');
requires        ('LWP::UserAgent');
requires        ('HTTP::Response');
requires        ('Fcntl');
requires        ('POSIX');
requires        ('URI::Escape');
requires        ('IO::Select');
requires        ('File::Path');
requires        ('File::Temp');
requires        ('List::MoreUtils');
requires        ('List::Util');
requires        ('Encode');
requires        ('File::Find');
requires        ('IO::Socket::INET');
requires        ('File::Copy::Recursive');

use_test_base();
auto_install();

#tests('t/*.t t/*/*.t');

WriteAll();

