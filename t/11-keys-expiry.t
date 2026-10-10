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

# --- generic key commands --------------------------------------------------

my ($a, $b, $c) = (unique_name('a'), unique_name('b'), unique_name('c'));
$kv->set($a, '1');
is($kv->exists($a), 1, 'EXISTS true');
is($kv->exists($b), 0, 'EXISTS false');
is($kv->type($a), 'string', 'TYPE');
is($kv->rename($a, $b), 'OK', 'RENAME');
is($kv->exists($a), 0, 'old name gone after RENAME');
is($kv->get($b), '1', 'new name has the value after RENAME');
is($kv->renamenx($b, $c), 1, 'RENAMENX to a free name succeeds');
$kv->set($b, 'other');
is($kv->renamenx($b, $c), 0, 'RENAMENX to an existing name fails');
is($kv->copy($b, $a), 1, 'COPY');
is($kv->get($a), 'other', 'COPY duplicated the value');
is($kv->touch($a, $c), 2, 'TOUCH counts existing keys');
my @keys_found = @{ $kv->keys($a) };
is_deeply(\@keys_found, [$a], 'KEYS with an exact pattern');
ok(defined $kv->randomkey, 'RANDOMKEY returns something (data exists)');
is($kv->del($a, $b, $c), 3, 'DEL removes all three');
is($kv->unlink($a, $b, $c), 0, 'UNLINK on already-gone keys returns 0');

# DUMP / RESTORE
my $dk = unique_name('dump');
$kv->set($dk, 'dumpme');
my $blob = $kv->dump($dk);
ok(defined $blob && length($blob), 'DUMP returns a non-empty blob');
$kv->del($dk);
is($kv->restore($dk, 0, $blob), 'OK', 'RESTORE from the dumped blob');
is($kv->get($dk), 'dumpme', 'restored value matches');
$kv->del($dk);

# --- expiry ------------------------------------------------------------

my $ek = unique_name('expire');
$kv->set($ek, 'v');
is($kv->expire($ek, 100), 1, 'EXPIRE');
ok($kv->ttl($ek) > 0, 'TTL positive after EXPIRE');
is($kv->persist($ek), 1, 'PERSIST');
is($kv->ttl($ek), -1, 'TTL -1 after PERSIST');
is($kv->pexpire($ek, 100000), 1, 'PEXPIRE');
ok($kv->pttl($ek) > 0, 'PTTL positive after PEXPIRE');
is($kv->expireat($ek, time() + 1000), 1, 'EXPIREAT');
is($kv->pexpireat($ek, (time() + 1000) * 1000), 1, 'PEXPIREAT');

# EXPIRE NX/XX/GT/LT option flags
$kv->persist($ek);
is($kv->expire($ek, 100, { nx => 1 }), 1, 'EXPIRE NX sets a TTL when none exists');
is($kv->expire($ek, 200, { nx => 1 }), 0, 'EXPIRE NX is a no-op when a TTL already exists');
is($kv->expire($ek, 50, { gt => 1 }), 0, 'EXPIRE GT refuses to shorten the TTL');
is($kv->expire($ek, 500, { gt => 1 }), 1, 'EXPIRE GT allows lengthening the TTL');
is($kv->expire($ek, 10000, { lt => 1 }), 0, 'EXPIRE LT refuses to lengthen the TTL');
is($kv->expire($ek, 10, { lt => 1 }), 1, 'EXPIRE LT allows shortening the TTL');
$kv->del($ek);
is($kv->ttl($ek), -2, 'TTL is -2 for a missing key');

# --- HotKV nanosecond TTL: NEXPIRE / NTTL / NEXPIREAT (core) --

my $nk = unique_name('nano');
$kv->set($nk, 'v');
is($kv->nttl($nk), -1, 'NTTL is -1 for a key with no TTL');
is($kv->nexpire($nk, 60_000_000_000), 1, 'NEXPIRE sets a nanosecond TTL');
my $nttl = $kv->nttl($nk);
ok($nttl > 0 && $nttl <= 60_000_000_000, 'NTTL reports a remaining nanosecond TTL');
my $future_ns = (time() + 120) * 1_000_000_000;
is($kv->nexpireat($nk, $future_ns), 1, 'NEXPIREAT sets an absolute nanosecond TTL');
ok($kv->nttl($nk) > 60_000_000_000, 'NTTL reflects the later NEXPIREAT deadline');
$kv->del($nk);
is($kv->nttl($nk), -2, 'NTTL is -2 for a missing key');
is($kv->nexpire($nk, 1_000_000_000), 0, 'NEXPIRE on a missing key returns 0');

# --- HOTKEYS (core, admin) ------------------------------------

my $hk_ok = eval { $kv->hotkeys_top(5); 1 };
SKIP: {
    skip 'HOTKEYS not available on this server build', 2 unless $hk_ok;
    my $top = $kv->hotkeys_top(5);
    is(ref($top), 'ARRAY', 'HOTKEYS TOP returns an arrayref');
    is($kv->hotkeys_reset, 'OK', 'HOTKEYS RESET');
}

$kv->close;
done_testing();
