use strict;
use warnings;

use Test::More tests => 5;

is(system("$^X -c -Ilib lib/Test/Nginx/LWP.pm"), 0, 'LWP.pm syntax OK');
is(system("$^X -c -Ilib lib/Test/Nginx/Socket.pm"), 0, 'Socket.pm syntax OK');
is(system("$^X -c -Ilib lib/Test/Nginx/Socket/Lua.pm"), 0, 'Lua.pm syntax OK');
is(system("$^X -c -Ilib lib/Test/Nginx/Socket/Lua/Stream.pm"), 0, 'Stream.pm syntax OK');
is(system("$^X -c -Ilib lib/Test/Nginx/Socket/Lua/Dgram.pm"), 0, 'Dgram.pm syntax OK');

