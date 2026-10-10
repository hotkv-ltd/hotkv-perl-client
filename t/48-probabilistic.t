# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# BF.*, CMS.* and TOPK.* (core, no license needed), live.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url unique_name);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();

use HotKV;

my $kv = HotKV->new(url => test_url());
my @cleanup;
sub key { my $k = unique_name(shift); push @cleanup, $k; return $k; }

# --- Bloom filter ------------------------------------------------------------

{
    my $k = key('bf');
    is($kv->bf->reserve($k, 0.01, 1000), 'OK', 'BF.RESERVE');
    is($kv->bf->add($k, 'alice'), 1, 'BF.ADD a new item');
    is($kv->bf->add($k, 'alice'), 0, 'BF.ADD the same item again');
    is_deeply($kv->bf->madd($k, 'bob', 'carol', 'alice'), [1, 1, 0], 'BF.MADD');
    is($kv->bf->exists($k, 'bob'), 1, 'BF.EXISTS present');
    is($kv->bf->exists($k, 'zed'), 0, 'BF.EXISTS absent');
    is_deeply($kv->bf->mexists($k, 'alice', 'zed'), [1, 0], 'BF.MEXISTS');
    is($kv->bf->card($k), 3, 'BF.CARD');
    my $info = $kv->bf->info($k);
    is(ref($info), 'HASH', 'BF.INFO is a hashref');
    is($info->{Capacity}, 1000, 'BF.INFO Capacity');
    is($info->{'Number of items inserted'}, 3, 'BF.INFO items');
    is($kv->bf->info($k, 'capacity'), 1000, 'BF.INFO CAPACITY');
    is($kv->bf->info($k, 'items'), 3, 'BF.INFO ITEMS');

    my $k2 = key('bfins');
    is_deeply($kv->bf->insert($k2, ['x', 'y'], { capacity => 100, error => 0.001 }), [1, 1], 'BF.INSERT with CAPACITY and ERROR (a float)');
    is($kv->bf->info($k2, 'capacity'), 100, 'BF.INSERT created the filter with the capacity');
    my $err = eval { $kv->bf->insert(key('bfnone'), ['x'], { nocreate => 1 }); 1 } ? undef : $@;
    ok($err && $err->isa('HotKV::Error::Server'), 'BF.INSERT NOCREATE on a missing key is an error');

    my $k3 = key('bfns');
    is($kv->bf->reserve($k3, 1e-05, 100, { expansion => 3 }), 'OK', 'BF.RESERVE with a tiny float error rate and EXPANSION');
    is($kv->bf->info($k3, 'expansion'), 3, 'BF.INFO EXPANSION');
    my $k4 = key('bfns2');
    is($kv->bf->reserve($k4, 0.01, 10, { nonscaling => 1 }), 'OK', 'BF.RESERVE NONSCALING');

    # SCANDUMP / LOADCHUNK round trip
    my ($it, @chunks) = (0);
    while (1) {
        my $r = $kv->bf->scandump($k, $it);
        last if !$r || $r->[0] == 0;
        push @chunks, [$r->[0], $r->[1]];
        $it = $r->[0];
    }
    ok(scalar(@chunks) >= 1, 'BF.SCANDUMP returned chunks');
    my $copy = key('bfcopy');
    is($kv->bf->loadchunk($copy, @$_), 'OK', 'BF.LOADCHUNK') for @chunks;
    is($kv->bf->exists($copy, 'alice'), 1, 'the restored filter knows alice');
    is($kv->bf->exists($copy, 'zed'), 0, 'the restored filter does not know zed');
}

# --- Count-Min sketch ---------------------------------------------------------

{
    my $k = key('cms');
    is($kv->cms->initbydim($k, 100, 5), 'OK', 'CMS.INITBYDIM');
    is_deeply($kv->cms->incrby($k, 'a', 3, 'b', 1), [3, 1], 'CMS.INCRBY');
    is_deeply($kv->cms->incrby($k, 'a', 2), [5], 'CMS.INCRBY again');
    is_deeply($kv->cms->query($k, 'a', 'b', 'never'), [5, 1, 0], 'CMS.QUERY');
    my $info = $kv->cms->info($k);
    is_deeply([@$info{qw(width depth count)}], [100, 5, 6], 'CMS.INFO');

    my $p = key('cmsprob');
    is($kv->cms->initbyprob($p, 0.001, 0.01), 'OK', 'CMS.INITBYPROB with float arguments');
    my $pinfo = $kv->cms->info($p);
    ok($pinfo->{width} >= 2000 && $pinfo->{depth} >= 4, 'CMS.INITBYPROB sized the sketch from the error and probability');
    my $tiny = key('cmstiny');
    is($kv->cms->initbyprob($tiny, 1e-05, 1e-03), 'OK', 'CMS.INITBYPROB with exponent-range floats');
    ok($kv->cms->info($tiny)->{width} >= 200_000, 'the tiny error rate gave a wide sketch');

    my ($s1, $s2, $dst) = (key('cms1'), key('cms2'), key('cmsdst'));
    $kv->cms->initbydim($_, 100, 5) for ($s1, $s2, $dst);
    $kv->cms->incrby($s1, 'x', 2);
    $kv->cms->incrby($s2, 'x', 3, 'y', 1);
    is($kv->cms->merge($dst, [$s1, $s2]), 'OK', 'CMS.MERGE');
    is_deeply($kv->cms->query($dst, 'x', 'y'), [5, 1], 'CMS.MERGE summed the counts');
    is($kv->cms->merge($dst, [$s1, $s2], [2, 1]), 'OK', 'CMS.MERGE with WEIGHTS');
    is_deeply($kv->cms->query($dst, 'x', 'y'), [7, 1], 'CMS.MERGE weighted the counts');
}

# --- Top-K ------------------------------------------------------------------------

{
    my $k = key('topk');
    is($kv->topk->reserve($k, 3), 'OK', 'TOPK.RESERVE');
    my $info = $kv->topk->info($k);
    is_deeply([@$info{qw(k width depth)}], [3, 8, 7], 'TOPK.INFO');
    cmp_ok($info->{decay}, '==', 0.9, 'TOPK.INFO decay');
    my $added = $kv->topk->add($k, 'a', 'b', 'a', 'c', 'a');
    is(scalar(@$added), 5, 'TOPK.ADD returns one entry per item');
    is_deeply($kv->topk->query($k, 'a', 'zz'), [1, 0], 'TOPK.QUERY');
    is_deeply($kv->topk->count($k, 'a', 'b'), [3, 1], 'TOPK.COUNT');
    is_deeply($kv->topk->incrby($k, 'b', 5), [undef], 'TOPK.INCRBY');
    is_deeply($kv->topk->list($k), ['b', 'a', 'c'], 'TOPK.LIST highest first');
    is_deeply($kv->topk->list($k, { withcount => 1 }), ['b', 6, 'a', 3, 'c', 1], 'TOPK.LIST WITHCOUNT');

    my $k2 = key('topk2');
    is($kv->topk->reserve($k2, 5, { width => 20, depth => 4, decay => 0.5 }), 'OK', 'TOPK.RESERVE with width depth decay');
    my $i2 = $kv->topk->info($k2);
    is_deeply([@$i2{qw(k width depth)}], [5, 20, 4], 'TOPK.INFO of the custom list');
    cmp_ok($i2->{decay}, '==', 0.5, 'decay 0.5');
}

$kv->del(@cleanup);
$kv->close;
done_testing();
