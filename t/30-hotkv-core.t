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

# --- TAG.* (core) ---------------------------------------------
#
# Every tag name used below is unique per test run (via unique_name) rather
# than relying on any reset between runs.

{
    my $k1 = unique_name('tagkey1');
    my $k2 = unique_name('tagkey2');
    my $tag_red  = unique_name('tag-red');
    my $tag_blue = unique_name('tag-blue');

    $kv->set($k1, 'v1');
    $kv->set($k2, 'v2');

    is($kv->tag->set($k1, $tag_red, $tag_blue), 2, 'TAG.SET adds two new tags');
    is($kv->tag->set($k1, $tag_red), 0, 'TAG.SET of an already-present tag adds nothing');
    is($kv->tag->set($k2, $tag_red), 1, 'TAG.SET on a second key');

    is_deeply([sort @{ $kv->tag->get($k1) }], [sort ($tag_red, $tag_blue)], 'TAG.GET lists all tags on a key');
    is_deeply($kv->tag->get(unique_name('untagged')), [], 'TAG.GET on an untagged key is an empty array');

    is_deeply([sort @{ $kv->tag->members($tag_red) }], [sort ($k1, $k2)], 'TAG.MEMBERS lists every key carrying the tag');
    is_deeply($kv->tag->inter($tag_red, $tag_blue), [$k1], 'TAG.INTER returns only keys carrying every given tag');

    is($kv->tag->count($k1), 2, 'TAG.COUNT');
    is($kv->tag->exists($k1, $tag_red), 1, 'TAG.EXISTS true');
    is($kv->tag->exists($k1, unique_name('never-set')), 0, 'TAG.EXISTS false');

    is($kv->tag->rem($k1, $tag_blue), 1, 'TAG.REM removes a tag');
    is_deeply($kv->tag->get($k1), [$tag_red], 'TAG.GET reflects the removal');

    my $err = eval { $kv->tag->set(unique_name('no-such-key'), $tag_red); 1 } ? undef : $@;
    ok($err, 'TAG.SET on a key that does not exist in the keyspace raises');
    isa_ok($err, 'HotKV::Error::Server');

    $kv->del($k1, $k2);
}

# --- GCRA.* (core rate limiter primitive) ---------------------

{
    my $gk = unique_name('gcra');
    my $r1 = $kv->gcra->limit($gk, 1000, 3);
    is($r1->[0], 0, 'GCRA.LIMIT first call is allowed');
    is($r1->[1], 3, 'GCRA.LIMIT reports the configured limit');
    is($r1->[2], 2, 'GCRA.LIMIT remaining drops to 2 after one consumption');
    is($r1->[3], -1, 'GCRA.LIMIT retry_after_ms is -1 when allowed');
    ok($r1->[4] > 0 && $r1->[4] <= 1000, 'GCRA.LIMIT reset_after_ms is a positive value within the period');
    $kv->gcra->limit($gk, 1000, 3) for (1 .. 2);
    my $r4 = $kv->gcra->limit($gk, 1000, 3);
    is($r4->[0], 1, 'GCRA.LIMIT denies once the burst is exhausted');
    ok($r4->[3] > 0, 'a denied response carries a positive retry_after_ms');
    is($kv->gcra->reset($gk), 1, 'GCRA.RESET reports one key reset');
    is($kv->gcra->reset($gk), 0, 'GCRA.RESET again finds nothing to reset');
}

# --- VSIM.* core (core): createindex/set/get/del/search/info/dropindex --

{
    my $idx = unique_name('vsimidx');
    is($kv->vsim->createindex($idx, 3, { metric => 'cosine' }), 'OK', 'VSIM.CREATEINDEX');
    is($kv->vsim->set($idx, 'v1', [1, 0, 0]), 1, 'VSIM.SET newly inserted');
    is($kv->vsim->set($idx, 'v1', [1, 0, 0.1]), 0, 'VSIM.SET replacing an existing vector');
    $kv->vsim->set($idx, 'v2', [0, 1, 0]);

    my $got = $kv->vsim->get($idx, 'v1');
    is(scalar(@$got), 3, 'VSIM.GET returns a vector with the right dimensionality');
    is($kv->vsim->get($idx, 'missing'), undef, 'VSIM.GET on a missing key is nil');

    my $found = $kv->vsim->search($idx, 2, [1, 0, 0]);
    is(scalar(@$found), 4, 'VSIM.SEARCH returns a flat key/distance array for up to k results');
    is($found->[0], 'v1', 'VSIM.SEARCH ranks the closest vector first');

    my $info = $kv->vsim->info($idx);
    my %info_h = @$info;
    is($info_h{dimensions}, 3, 'VSIM.INFO index reports the configured dimensions');
    is($info_h{metric}, 'cosine', 'VSIM.INFO index reports the configured metric');

    my $names = $kv->vsim->info;
    ok((grep { $_ eq $idx } @$names) >= 1, 'VSIM.INFO with no index lists this index by name');

    is($kv->vsim->del($idx, 'v2'), 1, 'VSIM.DEL');
    is($kv->vsim->dropindex($idx), 'OK', 'VSIM.DROPINDEX');
}

$kv->close;
done_testing();
