# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

use strict;
use warnings;
use Test::More;

use HotKV::Connection;

sub parse { return HotKV::Connection::parse_url($_[0]); }

{
    my $o = parse('hotkv://127.0.0.1:6399');
    is($o->{host}, '127.0.0.1', 'host');
    is($o->{port}, 6399, 'port');
    ok(!$o->{tls}, 'hotkv:// is not TLS');
    ok(!exists $o->{db} || $o->{db} == 0, 'no db in path -> unset/0');
}

{
    my $o = parse('hotkvs://127.0.0.1:6399');
    ok($o->{tls}, 'hotkvs:// enables TLS');
}

{
    my $o = parse('redis://127.0.0.1:6379');
    ok(!$o->{tls}, 'redis:// accepted for drop-in migration, not TLS');
}

{
    my $o = parse('rediss://127.0.0.1:6379');
    ok($o->{tls}, 'rediss:// accepted for drop-in migration, TLS');
}

{
    my $o = parse('hotkv://user:s3cr3t@10.0.0.5:7000/3');
    is($o->{host}, '10.0.0.5', 'host with userinfo');
    is($o->{port}, 7000, 'port with userinfo');
    is($o->{username}, 'user', 'username parsed');
    is($o->{password}, 's3cr3t', 'password parsed');
    is($o->{db}, 3, 'db index parsed from path');
}

{
    my $o = parse('hotkv://h:7000/2?resp3=0&command_timeout=12.5&client_name=my%20app&pool_size=3&bogus=1');
    is($o->{host}, 'h', 'host with a query string');
    is($o->{db}, 2, 'db with a query string');
    is($o->{resp3}, 0, 'resp3=0');
    is($o->{command_timeout}, 12.5, 'command_timeout');
    is($o->{client_name}, 'my app', 'client_name is unescaped');
    is($o->{pool_size}, 3, 'pool_size');
    ok(!exists $o->{bogus}, 'unknown query keys are ignored');
    is(parse('hotkv://h?resp3=1')->{resp3}, 1, 'resp3=1');
    is(parse('hotkv://h:1?resp3=0')->{port}, 1, 'port before the query');
    eval { parse('hotkv://h?command_timeout=abc') };
    like($@, qr/invalid command_timeout/, 'a non numeric timeout is refused');
}

{
    my $o = parse('hotkv://:onlypass@host');
    is($o->{username}, undef, 'no username when userinfo is ":pass"');
    is($o->{password}, 'onlypass', 'password parsed from ":pass" form');
}

{
    my $o = parse('hotkv://justpass@host');
    is($o->{password}, 'justpass', 'single userinfo component with no colon is treated as a password');
}

{
    my $o = parse('hotkv://host.example.com');
    is($o->{host}, 'host.example.com', 'hostname without port');
    is($o->{port}, 6379, 'default port is 6379 when omitted');
}

{
    my $o = parse('hotkv://');
    is($o->{host}, '127.0.0.1', 'default host is 127.0.0.1 when omitted entirely');
}

{
    my $o = parse('hotkv://user:pa%3Ass@host:1234');
    is($o->{password}, 'pa:ss', 'percent-encoded password is unescaped');
}

{
    my $o = parse('hotkv://[::1]:6399');
    is($o->{host}, '::1', 'bracketed IPv6 host');
    is($o->{port}, 6399, 'port after bracketed IPv6 host');
}

for my $bad ('not a url at all', 'ftp://host:1234', 'hotkv://host/notanumber') {
    my $err = eval { parse($bad); 1 } ? undef : $@;
    ok($err, "rejects invalid URL: $bad");
}

done_testing();
