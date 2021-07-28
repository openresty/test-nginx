use lib 'lib';
use Test::Nginx::Socket;

plan tests => 1;

for my $block (blocks) {
    my $len = 1;

    # 如果测试用例包含 request 请求参数,则需要发送 http 请求
    if (ref $block->request || ref $block->request_eval) {
        my $r_req_list = Test::Nginx::Socket::get_req_from_block($block);
        $len = $#$r_req_list + 1; # # 是读取数组长度
    }

    my $json = '{"c":"1","a":[1,2], "d":{"d":"4", "a":"1"}}';
    my $raw_res = "HTTP/1.0 200 OK\r\n"
        . "Date: Fri, 31 Dec 1999 23:59:59 GMT\r\n"
        . "Content-Type: application/json; charset=utf-8\r\n"
        . "Content-Length: " . length($json)
        . "\r\n\r\n$json";

    for my $i (0 .. $len - 1) {
        my ($res, $raw_headers, $left) = Test::Nginx::Socket::parse_response("name", $raw_res, 0);
        # 这里执行了 filter, 并采用引用的方式改写了 $res
        Test::Nginx::Socket::transform_response_body($block, $res, $i);

        # 读取测试用例中的  response_body_like 模块,并和 $res 结果叫校验
        Test::Nginx::Socket::check_response_body($block, $res, undef, $i, 0, $len > 1);
    }
}

__DATA__

=== TEST 1: 测试
--- response_body_filters
json_sort
--- response_body eval
'{"a":[1,2],"c":"1","d":{"a":"1","d":"4"}}'



