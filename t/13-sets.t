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
my $s1 = unique_name('s1');
my $s2 = unique_name('s2');

is($kv->sadd($s1, 'a', 'b', 'c'), 3, 'SADD');
is($kv->sadd($s1, 'a'), 0, 'SADD of an existing member adds nothing');
is($kv->scard($s1), 3, 'SCARD');
is($kv->sismember($s1, 'a'), 1, 'SISMEMBER true');
is($kv->sismember($s1, 'z'), 0, 'SISMEMBER false');
is_deeply($kv->smismember($s1, 'a', 'z', 'b'), [1, 0, 1], 'SMISMEMBER');
is_deeply([sort @{ $kv->smembers($s1) }], ['a', 'b', 'c'], 'SMEMBERS');

$kv->sadd($s2, 'b', 'c', 'd');
is_deeply([sort @{ $kv->sinter($s1, $s2) }], ['b', 'c'], 'SINTER');
is_deeply([sort @{ $kv->sunion($s1, $s2) }], ['a', 'b', 'c', 'd'], 'SUNION');
is_deeply([sort @{ $kv->sdiff($s1, $s2) }], ['a'], 'SDIFF');

my $dstI = unique_name('interdst');
my $dstU = unique_name('uniondst');
my $dstD = unique_name('diffdst');
is($kv->sinterstore($dstI, $s1, $s2), 2, 'SINTERSTORE');
is($kv->sunionstore($dstU, $s1, $s2), 4, 'SUNIONSTORE');
is($kv->sdiffstore($dstD, $s1, $s2), 1, 'SDIFFSTORE');

is($kv->smove($s1, $s2, 'a'), 1, 'SMOVE');
is($kv->sismember($s1, 'a'), 0, 'SMOVE removed from source');
is($kv->sismember($s2, 'a'), 1, 'SMOVE added to destination');

my $popped = $kv->spop($s2, 1);
is(ref($popped), 'ARRAY', 'SPOP with count returns an arrayref');
my $rand = $kv->srandmember($s2);
ok(defined $rand, 'SRANDMEMBER returns a member');
is($kv->srem($s2, @$popped), 0, 'SREM of an already-popped member removes nothing');

is($kv->sintercard([$s1, $s2]), scalar(@{ $kv->sinter($s1, $s2) }), 'SINTERCARD matches SINTER size');
is($kv->sintercard([$s1, $s2], { limit => 1 }), 1, 'SINTERCARD honors LIMIT');

$kv->del($s1, $s2, $dstI, $dstU, $dstD);
$kv->close;
done_testing();
