# Unit test for TEST_NGINX_ARCHIVE_PATH
use Cwd qw(cwd);
BEGIN {
    my $pwd = cwd();
    $ENV{TEST_NGINX_ARCHIVE_PATH} = 't/servroot';
    $ENV{TEST_NGINX_SERVROOT} = "$pwd/t/archive";
}

use Test::Nginx::Socket;
use File::Path 'remove_tree';
use File::Spec::Functions 'catfile';

plan skip_all => "nginx is required but not found" if system('nginx -h >/dev/null 2>&1') != 0;
repeat_each(2);
plan tests => 8 * blocks();

remove_tree($ENV{TEST_NGINX_ARCHIVE_PATH});
run_tests();

__DATA__

=== TEST 1: create files to be archived
--- config
    location /t {
        return 200;
    }
--- pipelined_requests eval
["GET /t", "GET /t"]

--- response_body eval
["", ""]
=== TEST 1: create files to be archived
--- config
    location /t {
        return 200;
    }
--- pipelined_requests eval
["GET /t", "GET /t"]

--- response_body eval
["", ""]
