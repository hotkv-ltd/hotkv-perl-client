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
my $h  = unique_name('hash');

is($kv->hset($h, 'f1', 'v1', 'f2', 'v2'), 2, 'HSET returns number of new fields');
is($kv->hset($h, 'f1', 'v1x'), 0, 'HSET on an existing field returns 0 new fields');
is($kv->hget($h, 'f1'), 'v1x', 'HGET');
is_deeply($kv->hmget($h, 'f1', 'f2', 'missing'), ['v1x', 'v2', undef], 'HMGET');
is($kv->hlen($h), 2, 'HLEN');
is($kv->hexists($h, 'f1'), 1, 'HEXISTS true');
is($kv->hexists($h, 'nope'), 0, 'HEXISTS false');
is($kv->hsetnx($h, 'f1', 'ignored'), 0, 'HSETNX on an existing field is a no-op');
is($kv->hsetnx($h, 'f3', 'v3'), 1, 'HSETNX on a missing field sets it');
is_deeply($kv->hgetall($h), { f1 => 'v1x', f2 => 'v2', f3 => 'v3' }, 'HGETALL (RESP3 map decodes to a hashref)');
is_deeply([sort @{ $kv->hkeys($h) }], ['f1', 'f2', 'f3'], 'HKEYS');
is_deeply([sort @{ $kv->hvals($h) }], ['v1x', 'v2', 'v3'], 'HVALS');
is($kv->hdel($h, 'f3'), 1, 'HDEL');
is($kv->hlen($h), 2, 'HLEN after HDEL');

my $hn = unique_name('hnum');
$kv->hset($hn, 'n', 10);
is($kv->hincrby($hn, 'n', 5), 15, 'HINCRBY');
is($kv->hincrbyfloat($hn, 'n', '0.5'), 15.5, 'HINCRBYFLOAT');

my $rf = $kv->hrandfield($h);
ok(defined $rf, 'HRANDFIELD returns a field name');
my $rf2 = $kv->hrandfield($h, { count => 2, withvalues => 1 });
is(ref($rf2), 'ARRAY', 'HRANDFIELD COUNT WITHVALUES returns an arrayref');

# --- hash field expiry: HEXPIRE / HTTL / HPERSIST / HPEXPIRE / HPTTL ------

my $he = unique_name('hexp');
$kv->hset($he, 'a', '1', 'b', '2');
my $hexpire_ok = eval { $kv->hexpire($he, 100, ['a']); 1 };
SKIP: {
    skip 'hash field TTL (HEXPIRE family) not available on this server build', 8 unless $hexpire_ok;

    my $r = $kv->hexpire($he, 100, ['a']);
    is_deeply($r, [1], 'HEXPIRE on a single field');
    my $ttl = $kv->httl($he, ['a']);
    ok($ttl->[0] > 0 && $ttl->[0] <= 100, 'HTTL reports a positive remaining TTL');
    is_deeply($kv->httl($he, ['b']), [-1], 'HTTL is -1 for a field with no TTL');
    is_deeply($kv->httl($he, ['nofield']), [-2], 'HTTL is -2 for a missing field');

    is_deeply($kv->hpersist($he, ['a']), [1], 'HPERSIST clears the field TTL');
    is_deeply($kv->httl($he, ['a']), [-1], 'HTTL is -1 after HPERSIST');

    is_deeply($kv->hpexpire($he, 100000, ['a']), [1], 'HPEXPIRE');
    my $pttl = $kv->hpttl($he, ['a']);
    ok($pttl->[0] > 0, 'HPTTL reports a positive remaining TTL');
}

# HSCAN (with and without NOVALUES)
my $hs = unique_name('hscan');
$kv->hset($hs, 'x', '1', 'y', '2', 'z', '3');
my $cursor = 0;
my %seen;
do {
    my $reply = $kv->hscan($hs, $cursor);
    $cursor = $reply->[0];
    my @flat = @{ $reply->[1] };
    while (@flat) { my ($f, $v) = (shift @flat, shift @flat); $seen{$f} = $v; }
} while ($cursor ne '0');
is_deeply(\%seen, { x => 1, y => 2, z => 3 }, 'HSCAN iterates all fields');

my $novalues_ok = eval { $kv->hscan($hs, 0, { novalues => 1 }); 1 };
SKIP: {
    skip 'HSCAN NOVALUES not available on this server build', 1 unless $novalues_ok;
    my $reply = $kv->hscan($hs, 0, { novalues => 1 });
    is_deeply([sort @{ $reply->[1] }], ['x', 'y', 'z'], 'HSCAN NOVALUES returns field names only');
}

$kv->del($h, $hn, $he, $hs);
$kv->close;
done_testing();
