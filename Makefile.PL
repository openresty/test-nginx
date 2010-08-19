use strict;
use lib '.';
use inc::Module::Install;

name            ('Test-Nginx');
license         ('bsd');
perl_version    ('5.006001');
repository      ('http://github.com/agentzh/test-nginx');
all_from        ('lib/Test/Nginx.pm');

requires        ('Test::LongString');
requires        ('IO::Socket');
requires        ('Time::HiRes');
requires        ('LWP::UserAgent');
requires        ('HTTP::Response');
requires        ('Fcntl');
requires        ('POSIX');
requires        ('IO::Select');
requires        ('List::MoreUtils');
requires        ('ExtUtils::MakeMaker');

use_test_base();
auto_install();

#tests('t/*.t t/*/*.t');

WriteAll();

