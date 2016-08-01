use strict;
use warnings;

use Test::More tests => 4;

is(system("$^X -c -Ilib lib/Test/Nginx/LWP.pm"), 0, 'LWP.pm syntax OK');
is(system("$^X -c -Ilib lib/Test/Nginx/Socket.pm"), 0, 'Socket.pm syntax OK');
is(system("$^X -c -Ilib lib/Test/Nginx/Socket/Lua.pm"), 0, 'Lua.pm syntax OK');
is(system("$^X -c -Ilib lib/Test/Nginx/Socket/Lua/Dgram.pm"), 0, 'Dgram.pm syntax OK');

