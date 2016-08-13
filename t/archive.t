# Unit test for TEST_NGINX_ARCHIVE_PATH, requires 0-archive.t runs ahead
use Test::Nginx::Socket;
use File::Spec::Functions 'catfile';

plan tests => 5;

my $archive = catfile($ENV{TEST_NGINX_ARCHIVE_PATH},
    't.0-archive.TEST_1:_create_files_to_be_archived');
ok(-f catfile($archive, 'logs', 'error.log'), 'Archive error.log');
ok(-f catfile($archive, 'logs', 'access.log'), 'Archive access.log');
ok(-f catfile($archive, 'conf', 'nginx.conf'), 'Archive nginx.conf');

sub count_occurrence_in_file($$) {
    my ($filename, $pattern) = @_;
    # Fail directly if output file is missing.
    open my $fh, '<', $filename or die "error opening $filename: $!";
    my $text = do { local $/; <$fh> };
    my $count = () = $text =~ /$pattern/g;
    return $count;
}

my $filename = catfile($archive, 'output');
is(count_occurrence_in_file($filename, "200 OK"), 4, "Archive output for TEST 1");
$archive = catfile($ENV{TEST_NGINX_ARCHIVE_PATH},
    't.0-archive.TEST_2:_each_test_block_has_its_own_output');
$filename = catfile($archive, 'output');
is(count_occurrence_in_file($filename, "200 OK"), 4, "Archive output for TEST 2");
