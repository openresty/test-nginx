use strict;
use lib '.';
use inc::Module::Install;

name            ('Test-Nginx');
license         ('bsd');
perl_version    ('5.006001');
repository      ('http://github.com/agentzh/test-nginx');
all_from        ('lib/Test/Nginx.pm');

requires        ('Test::LongString');

use_test_base();
auto_install();

#tests('t/*.t t/*/*.t');

WriteAll();

