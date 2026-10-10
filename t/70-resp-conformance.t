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

# Checks that HGETALL, HRANDFIELD WITHVALUES, SMEMBERS, ZSCORE, ZRANGE
# WITHSCORES, ZPOPMIN with a count, ZRANDMEMBER WITHSCORES, XREAD, XINFO
# STREAM, CONFIG GET and INFO decode to the same shape whether the
# connection negotiated RESP3 (the default) or RESP2.
for my $resp3 (1, 0) {
    my $label = $resp3 ? 'resp3' : 'resp2';
    my $kv    = HotKV->new(url => test_url(), resp3 => $resp3);

    my $hkey = unique_name("conform-$label-hash");
    my $skey = unique_name("conform-$label-set");
    my $zkey = unique_name("conform-$label-zset");
    my $xkey = unique_name("conform-$label-stream");

    $kv->hset($hkey, 'f1', 'v1', 'f2', 'v2');
    is_deeply($kv->hgetall($hkey), { f1 => 'v1', f2 => 'v2' }, "[$label] HGETALL");

    my $fvs = $kv->hrandfield($hkey, { count => 2, withvalues => 1 });
    is(scalar(@$fvs), 2, "[$label] HRANDFIELD WITHVALUES count");
    for my $pair (@$fvs) {
        is($pair->[1], $pair->[0] eq 'f1' ? 'v1' : 'v2', "[$label] HRANDFIELD WITHVALUES pair");
    }

    $kv->sadd($skey, 'a', 'b', 'c');
    is_deeply([sort @{ $kv->smembers($skey) }], ['a', 'b', 'c'], "[$label] SMEMBERS");

    $kv->zadd($zkey, 1, 'a', 2, 'b', 3, 'c');
    is($kv->zscore($zkey, 'b'), 2, "[$label] ZSCORE");

    is_deeply(
        $kv->zrange($zkey, 0, -1, { withscores => 1 }),
        [['a', 1], ['b', 2], ['c', 3]],
        "[$label] ZRANGE WITHSCORES"
    );

    is_deeply($kv->zpopmin($zkey, 2), [['a', 1], ['b', 2]], "[$label] ZPOPMIN with a count");

    $kv->zadd($zkey, 1, 'a', 2, 'b');
    my $rand_scored = $kv->zrandmember($zkey, { count => 3, withscores => 1 });
    is(scalar(@$rand_scored), 3, "[$label] ZRANDMEMBER WITHSCORES");

    my $id1 = $kv->xadd($xkey, '*', 'field1', 'v1');
    my $id2 = $kv->xadd($xkey, '*', 'field2', 'v2');
    my $streams = $kv->xread([$xkey], ['0']);
    is(ref($streams), 'HASH', "[$label] XREAD returns a hashref");
    my $entries = $streams->{$xkey};
    is(scalar(@$entries), 2, "[$label] XREAD entry count");
    is($entries->[0][0], $id1, "[$label] XREAD first entry id");
    is_deeply($entries->[0][1], ['field1', 'v1'], "[$label] XREAD first entry fields");
    is($entries->[1][0], $id2, "[$label] XREAD second entry id");

    my $info = $kv->xinfo_stream($xkey);
    is($info->{length}, 2, "[$label] XINFO STREAM length");
    is($info->{'last-generated-id'}, $id2, "[$label] XINFO STREAM last-generated-id");

    my $cfg = $kv->config_get('maxmemory');
    ok(exists $cfg->{maxmemory}, "[$label] CONFIG GET");

    my $info_str = $kv->info;
    unlike($info_str, qr/^txt:/, "[$label] INFO does not leak a verbatim string prefix");
    unlike($info_str, qr/^mkd:/, "[$label] INFO does not leak a verbatim string prefix");
    like($info_str, qr/hotkv_version/, "[$label] INFO contains hotkv_version");

    $kv->del($hkey, $skey, $zkey, $xkey);
}

done_testing();
