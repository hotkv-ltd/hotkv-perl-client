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

# --- geospatial --------------------------------------------------------

my $g = unique_name('geo');
is($kv->geoadd($g, '13.361389', '38.115556', 'Palermo', '15.087269', '37.502669', 'Catania'), 2, 'GEOADD');
my $pos = $kv->geopos($g, 'Palermo');
ok(abs($pos->[0][0] - 13.361389) < 0.001, 'GEOPOS longitude is close to the inserted value');
my $dist = $kv->geodist($g, 'Palermo', 'Catania', { unit => 'km' });
ok($dist > 160 && $dist < 170, 'GEODIST Palermo-Catania is approximately 166km');
my $search = $kv->geosearch($g, { fromlonlat => ['15', '37'], byradius => [200, 'km'], withdist => 1 });
is(scalar(@$search), 2, 'GEOSEARCH BYRADIUS finds both members within 200km');
is($kv->geoadd($g, '13.361389', '38.115556', 'Palermo', { nx => 1 }), 0, 'GEOADD NX does not touch an existing member');
$kv->del($g);

# --- bitmaps -------------------------------------------------------------

my $b = unique_name('bits');
is($kv->setbit($b, 7, 1), 0, 'SETBIT returns the previous bit value');
is($kv->getbit($b, 7), 1, 'GETBIT reflects the SETBIT');
is($kv->get($b), "\x01", 'the byte underneath is 0x01 after setting bit 7');
is($kv->bitcount($b), 1, 'BITCOUNT with no range');
$kv->set($b, 'foobar');
is($kv->bitcount($b), 26, 'BITCOUNT of "foobar"');
is($kv->bitcount($b, { start => 1, end => 1 }), 6, 'BITCOUNT BYTE range');
is($kv->bitcount($b, { start => 5, end => 30, unit => 'bit' }), 17, 'BITCOUNT BIT range');
is($kv->bitpos($b, 1, { start => 0 }), 1, 'BITPOS finds the first set bit');

my ($ba, $bb, $bdest) = (unique_name('ba'), unique_name('bb'), unique_name('bdest'));
$kv->set($ba, "\xff\xff");
$kv->set($bb, "\x0f\x0f");
is($kv->bitop('AND', $bdest, $ba, $bb), 2, 'BITOP AND');
is($kv->get($bdest), "\x0f\x0f", 'BITOP AND result');

# --- hyperloglog -----------------------------------------------------------

my ($h1, $h2, $hmerge) = (unique_name('hll1'), unique_name('hll2'), unique_name('hllmerge'));
is($kv->pfadd($h1, 'a', 'b', 'c'), 1, 'PFADD reports a cardinality-changing add');
is($kv->pfadd($h2, 'c', 'd', 'e'), 1, 'PFADD on the second key');
my $count1 = $kv->pfcount($h1);
is($count1, 3, 'PFCOUNT single key is exact for a small set');
is($kv->pfmerge($hmerge, $h1, $h2), 'OK', 'PFMERGE');
is($kv->pfcount($hmerge), 5, 'PFCOUNT of the merged key (a,b,c,d,e)');
is($kv->pfcount($h1, $h2), 5, 'PFCOUNT across multiple keys computes the union');

$kv->del($b, $ba, $bb, $bdest, $h1, $h2, $hmerge);
$kv->close;
done_testing();
