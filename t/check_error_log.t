# Unit tests for the expansion of $TEST_NGINX_* in Test::Nginx::Socket's
# --- error_log and --- no_error_log sections
use lib 'lib';
use Test::Nginx::Socket;
use File::Temp qw(tempfile);

plan tests => 3;

my ($fh, $err_log_file) = tempfile(UNLINK => 1);
print $fh "2026/01/01 00:00:00 [debug] 1#1: *1 Host: 127.0.0.1:1988\n";
close $fh;

$ENV{TEST_NGINX_CHECK_ERROR_LOG_ADDR} = '127.0.0.1';
$Test::Nginx::Util::ErrLogFile = $err_log_file;
$Test::Nginx::Util::TestNginxSleep = 0;
$Test::Nginx::Util::CheckAccumErrLog = 1;

my @results;
{
    no warnings 'redefine';
    local *Test::Nginx::Socket::pass = sub { push @results, "pass: $_[0]" };
    local *Test::Nginx::Socket::fail = sub { push @results, "fail: $_[0]" };

    for my $block (blocks) {
        local $Test::Nginx::Util::RandPorts = {
            TEST_NGINX_RAND_PORT_1 => 1988,
            TEST_NGINX_RAND_PORT_2 => 1992,
        };
        &Test::Nginx::Socket::check_error_log($block, undef, 0, 0, 0);
    }
}

my @failed = grep { /^fail/ } @results;
is(scalar(@failed), 1, 'only the no_error_log pattern of the logged port fails')
    or diag(join "\n", @results);
like($failed[0], qr/pattern "Host: 127\.0\.0\.1:1988" should not match/,
     'no_error_log is expanded');
is(scalar(@results), 6, 'every pattern is checked')
    or diag(join "\n", @results);

__DATA__

=== error_log: plain patterns
--- error_log
Host: $TEST_NGINX_CHECK_ERROR_LOG_ADDR:$TEST_NGINX_RAND_PORT_1



=== error_log: an array of strings and regexes
--- error_log eval
['Host: 127.0.0.1:$TEST_NGINX_RAND_PORT_1', qr/Host: [\d.]+:1988/]



=== no_error_log: plain patterns
--- no_error_log
Host: 127.0.0.1:$TEST_NGINX_RAND_PORT_2
Host: 127.0.0.1:$TEST_NGINX_RAND_PORT_1



=== no_error_log: an array
--- no_error_log eval
['Host: 127.0.0.1:$TEST_NGINX_RAND_PORT_2']
