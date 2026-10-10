# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url unique_name);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();

use HotKV;

my $kv = HotKV->new(url => test_url());
my $k  = unique_name('str');
my @cleanup = ($k);

is($kv->set($k, 'hello'), 'OK', 'SET');
is($kv->get($k), 'hello', 'GET');
is($kv->strlen($k), 5, 'STRLEN');
is($kv->append($k, ' world'), 11, 'APPEND returns new length');
is($kv->get($k), 'hello world', 'GET after APPEND');

is($kv->getset($k, 'replaced'), 'hello world', 'GETSET returns the old value');
is($kv->get($k), 'replaced', 'GETSET stored the new value');

is($kv->getdel($k), 'replaced', 'GETDEL returns the value');
is($kv->exists($k), 0, 'GETDEL removed the key');

# SET options: NX / XX / GET / EX / KEEPTTL
is($kv->set($k, 'v1', { nx => 1 }), 'OK', 'SET NX on a missing key succeeds');
is($kv->set($k, 'v2', { nx => 1 }), undef, 'SET NX on an existing key is a no-op (nil reply)');
is($kv->get($k), 'v1', 'value unchanged after failed SET NX');
is($kv->set($k, 'v3', { xx => 1 }), 'OK', 'SET XX on an existing key succeeds');
is($kv->set($k . ':missing', 'v', { xx => 1 }), undef, 'SET XX on a missing key is a no-op');
is($kv->set($k, 'v4', { get => 1 }), 'v3', 'SET GET returns the previous value');
is($kv->set($k, 'v5', { ex => 100 }), 'OK', 'SET EX');
ok($kv->ttl($k) > 0 && $kv->ttl($k) <= 100, 'TTL reflects SET EX');
is($kv->set($k, 'v6', { keepttl => 1 }), 'OK', 'SET KEEPTTL');
ok($kv->ttl($k) > 0, 'TTL preserved by SET KEEPTTL');
is($kv->set($k, 'v7'), 'OK', 'plain SET clears the TTL');
is($kv->ttl($k), -1, 'TTL is -1 (no expiry) after a plain SET');

# GETEX
is($kv->getex($k, { ex => 50 }), 'v7', 'GETEX returns the value');
ok($kv->ttl($k) > 0 && $kv->ttl($k) <= 50, 'GETEX EX set a TTL');
is($kv->getex($k, { persist => 1 }), 'v7', 'GETEX PERSIST returns the value');
is($kv->ttl($k), -1, 'GETEX PERSIST cleared the TTL');

# INCR family
my $ck = unique_name('counter');
push @cleanup, $ck;
is($kv->incr($ck), 1, 'INCR from missing key starts at 1');
is($kv->incrby($ck, 9), 10, 'INCRBY');
is($kv->decr($ck), 9, 'DECR');
is($kv->decrby($ck, 4), 5, 'DECRBY');
is($kv->incrbyfloat($ck, '0.5'), 5.5, 'INCRBYFLOAT');

# SETRANGE / GETRANGE
my $rk = unique_name('range');
push @cleanup, $rk;
$kv->set($rk, 'Hello World');
is($kv->getrange($rk, 0, 4), 'Hello', 'GETRANGE');
is($kv->setrange($rk, 6, 'Perl!'), 11, 'SETRANGE returns new length');
is($kv->get($rk), 'Hello Perl!', 'GETRANGE/SETRANGE round trip');

# MSET / MGET / MSETNX / SETNX / SETEX / PSETEX
my ($m1, $m2, $m3) = (unique_name('m1'), unique_name('m2'), unique_name('m3'));
push @cleanup, ($m1, $m2, $m3);
is($kv->mset($m1, 'a', $m2, 'b'), 'OK', 'MSET');
is_deeply($kv->mget($m1, $m2, $m3), ['a', 'b', undef], 'MGET (including a missing key)');
is($kv->msetnx($m1, 'x', $m3, 'y'), 0, 'MSETNX fails entirely when any key already exists');
is($kv->get($m3), undef, 'MSETNX did not set the other key either');
is($kv->setnx($m3, 'z'), 1, 'SETNX on a missing key');
is($kv->setnx($m3, 'zz'), 0, 'SETNX on an existing key');
is($kv->setex($m3, 100, 'withttl'), 'OK', 'SETEX');
ok($kv->ttl($m3) > 0, 'SETEX applied a TTL');
is($kv->psetex($m3, 100000, 'withttlms'), 'OK', 'PSETEX');
ok($kv->pttl($m3) > 0, 'PSETEX applied a TTL');

# binary-safe values
my $bk = unique_name('binary');
push @cleanup, $bk;
my $binary = "a\x00b\r\nc\xffd";
is($kv->set($bk, $binary), 'OK', 'SET with embedded NUL/CRLF/high byte');
is($kv->get($bk), $binary, 'GET returns the exact binary value');

$kv->del(@cleanup);
$kv->close;
done_testing();
