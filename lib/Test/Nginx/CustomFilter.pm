package Test::Nginx::CustomFilter;

# 导出当前命名空间
use base 'Exporter';
our @EXPORT = qw(
    json_sort
    arg_sort
    m3u8_sort
);

our $VERSION = '0.29';

use Data::Dumper;
use JSON;
use URI;
use URI::URL;
use Test::More;

sub debug {
    my $content = shift;
    diag("\n-------------------\n");
    diag(Dumper($content));
    diag("\n-------------------\n");
}

sub traverse_json {
    my $data = shift;
    if (ref($data) eq "HASH") {
        my %new;
        foreach my $key (keys %{$data}) {
            $new{traverse_json($key)} = traverse_json($data->{$key});
        }
        return \%new;
    }
    elsif (ref($data) eq "ARRAY") {
        foreach my $item (@{$data}) {
            $item = traverse_json($item);
        }
        return $data;
    }
    else {
        return arg_sort($data);
    }
}

sub json_sort {
    my $content = shift;
    my @list = ("a", "b", "c");

    my $json = JSON->new->canonical(1);
    my $data = $json->decode($content);

    # 遍历所有 json, 如果有 url 则遍历 url
    my $handled = traverse_json($data);

    # 判断是否为 json,如果是 json 则需要排序
    # debug($json->encode($handled));
    return $json->encode($handled);
}


sub arg_sort {
    my $content = shift;

    # 判断是否包含 url arg 结构 ?a=b
    if ($content !~ /\?.+=.+/) {
        return $content;
    }

    my $uri = URI->new($content);
    my %query = $uri->query_form;
    if (!%query) {
        return $content;
    }

    my @keys = sort {$a cmp $b} keys %query;
    my @query_list;
    foreach my $key (@keys) {
        push @query_list, join("=", $key, $query{$key});
    }
    my $query = join('&', @query_list);
    $query = "?" . $query;

    # 清空 url param
    $uri->query_form("");

    return $uri->as_string . $query;
}

sub m3u8_sort {
    # 遍历每一行,如果是 url 就改写字符串
    my $content = shift;
    my @list = split(/\n/, $content, -1);
    foreach my $item (@list) {
        $item = arg_sort($item);
    }

    return join("\n", @list);
}

1;