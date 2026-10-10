# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# Floating point values, wide characters and blocking commands against a
# real server: Perl would stringify 1e-05 in exponent form, which the
# server's fixed-point money parsers (LLMBUDGET.SET, LLMSTATS.PRICE SET)
# reject, so the SDK writes every number as plain decimal text.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url unique_name safe_name is_nolicense);
use Time::HiRes qw(time);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();

use HotKV;

my $kv = HotKV->new(url => test_url());

# --- core: scores and increments, tiny / huge / negative / integral --------

my $z = unique_name('floatz');
my @scores = (1e-05, 1.5e-300, -2.5e-07, 1e22, -1e300, 0.1 + 0.2, 5.0, 4503599627370496, 0);
my $i = 0;
for my $score (@scores) {
    my $member = 'm' . $i++;
    is($kv->zadd($z, $score, $member), 1, "ZADD score $score");
    my $back = $kv->zscore($z, $member);
    cmp_ok($back, '==', $score, "ZSCORE reads back $score");
}

is($kv->zincrby($z, 1e-05, 'm0'), $kv->zscore($z, 'm0'), 'ZINCRBY with a tiny float');
cmp_ok($kv->zscore($z, 'm0'), '==', 2e-05, 'ZINCRBY result');
my $by_score = $kv->zrangebyscore($z, -1e-300, 1e-04);
is_deeply([sort @$by_score], ['m0', 'm1', 'm8'], 'ZRANGEBYSCORE with tiny float bounds');

my $f = unique_name('floatk');
for (1 .. 3) { $kv->incrbyfloat($f, 1e-05); }
cmp_ok($kv->get($f), '==', 3e-05, 'INCRBYFLOAT by 1e-05 three times');
is($kv->set($f, 0), 'OK', 'reset');
cmp_ok($kv->incrbyfloat($f, -2.5e-07), '==', -2.5e-07, 'INCRBYFLOAT negative tiny');
cmp_ok($kv->incrbyfloat($f, 1e20), '==', 1e20, 'INCRBYFLOAT huge');
my $h = unique_name('floath');
cmp_ok($kv->hincrbyfloat($h, 'f', 1.5e-06), '==', 1.5e-06, 'HINCRBYFLOAT tiny');

my $g = unique_name('floatg');
is($kv->geoadd($g, 1.5e-05, -2.6e-06, 'origin', 13.361389, 38.115556, 'palermo'), 2, 'GEOADD with a tiny coordinate');
my $pos = $kv->geopos($g, 'origin')->[0];
ok(abs($pos->[0] - 1.5e-05) < 1e-4 && abs($pos->[1] + 2.6e-06) < 1e-4, 'GEOPOS of the tiny coordinate');
my $near = $kv->geosearch($g, { fromlonlat => [0, 0], byradius => [1e3, 'm'], asc => 1 });
is_deeply($near, ['origin'], 'GEOSEARCH with a tiny coordinate and a float radius');

# --- strings that look like numbers are stored verbatim --------------------

my $s = unique_name('floatstr');
for my $text ('1e-05', '0.50', '007', '+5', 'nan', 'Infinity', '1E5') {
    $kv->set($s, $text);
    is($kv->get($s), $text, "SET/GET keeps the string '$text' byte for byte");
}
{
    my $numified = '1e-05';
    my $unused = $numified + 0;
    $kv->set($s, $numified);
    is($kv->get($s), '1e-05', 'a string that was used in arithmetic is still stored as written');
}

# --- wide characters: UTF-8, with a byte length ----------------------------

my $w = unique_name('wide');
my $smiley = "caf\x{e9} \x{263a}";
is($kv->set($w, $smiley), 'OK', 'SET with wide characters');
is($kv->strlen($w), 9, 'STRLEN counts the UTF-8 bytes');
is($kv->get($w), "caf\xc3\xa9 \xe2\x98\xba", 'GET returns the UTF-8 bytes');
{
    my $bytes = $kv->get($w);
    utf8::decode($bytes);
    is($bytes, $smiley, 'the reply decodes back to the original text');
}
my $bin = join('', map { chr } 0 .. 255);
$kv->set($w, $bin);
is($kv->get($w), $bin, 'all 256 byte values round trip');

# --- blocking commands wait longer than command_timeout --------------------

{
    my $quick = HotKV->new(url => test_url(), command_timeout => 1);
    my $list = unique_name('blist');
    my $t0 = time;
    my $r = eval { $quick->blpop($list, 2) };
    my $took = time - $t0;
    is($@, '', 'BLPOP 2 with command_timeout 1 does not raise a client side timeout');
    is($r, undef, 'BLPOP on an empty list returns nil after the wait');
    cmp_ok($took, '>=', 1.8, 'it did wait for the server (about 2 s)');
    cmp_ok($took, '<', 4, 'and not much longer');

    # A producer on another connection wakes the blocked client.
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        select(undef, undef, undef, 0.4);
        my $producer = HotKV->new(url => test_url());
        $producer->rpush($list, 'wake');
        exit 0;
    }
    my $got = eval { $quick->brpop($list, 5) };
    waitpid($pid, 0);
    is_deeply($got, [$list, 'wake'], 'BRPOP receives the value pushed while it waits');

    my $stream = unique_name('bstream');
    my $r2 = eval { $quick->xread([$stream], ['$'], { block => 1500 }) };
    is($@, '', 'XREAD BLOCK 1500 with command_timeout 1 does not raise a client side timeout');
    $quick->close;
}

# --- LLMBUDGET / LLMSTATS money fields (need a license) --------------------

{
    my $budget = safe_name('floatbudget');
    my $ok = eval { $kv->llmbudget->set($budget, 1000, 1e-05, 60); 1 };
    if (!$ok) {
        ok(is_nolicense($@), 'LLMBUDGET.SET without the llm-budget license raises NotLicensed')
            or diag("unexpected error: $@");
    }
    SKIP: {
        skip 'llm-budget license feature not enabled on the test server', 11 unless $ok;
        my $st = $kv->llmbudget->status($budget);
        cmp_ok($st->{cost_limit_usd}, '==', 0.00001, 'LLMBUDGET.SET accepted the Perl float 1e-05');

        is($kv->llmbudget->set($budget, 1000, '1e-05', 60), 'OK', 'LLMBUDGET.SET accepts the string 1e-05');
        cmp_ok($kv->llmbudget->status($budget)->{cost_limit_usd}, '==', 0.00001, '  stored as 0.00001');
        is($kv->llmbudget->set($budget, 1000, 2.6e-06, 60), 'OK', 'LLMBUDGET.SET rounds a sub micro-dollar float');
        cmp_ok($kv->llmbudget->status($budget)->{cost_limit_usd}, '==', 0.000003, '  to the nearest micro-dollar');
        is($kv->llmbudget->set($budget, 1000, 12.5, 60), 'OK', 'LLMBUDGET.SET with a float');
        is($kv->llmbudget->set($budget, 1000, 100, 60), 'OK', 'LLMBUDGET.SET with an integer');
        is($kv->llmbudget->set($budget, 1000, 1e6, 60), 'OK', 'LLMBUDGET.SET with 1e6');
        eval { $kv->llmbudget->set($budget, 1000, -1, 60) };
        like($@, qr/not a valid USD amount/, 'a negative limit is refused before it is sent');
        is($kv->llmbudget->consume($budget, 10, 1e-05), 1, 'LLMBUDGET.CONSUME with a tiny float cost');
        is($kv->llmbudget->drop($budget), 1, 'LLMBUDGET.DROP');
    }
}

{
    my $model = safe_name('floatmodel');
    my $ok = eval { $kv->llmstats->price_set($model, 1e-05, 2.6e-06); 1 };
    if (!$ok) {
        ok(is_nolicense($@), 'LLMSTATS.PRICE SET without the llm-stats license raises NotLicensed')
            or diag("unexpected error: $@");
    }
    SKIP: {
        skip 'llm-stats license feature not enabled on the test server', 3 unless $ok;
        my $p = $kv->llmstats->price_get($model);
        cmp_ok($p->input_usd_per_mtok, '==', 0.00001, 'LLMSTATS.PRICE SET input 1e-05 stored');
        cmp_ok($p->output_usd_per_mtok, '==', 0.000003, 'LLMSTATS.PRICE SET output 2.6e-06 rounded to a micro-dollar');
        my $bucket = safe_name('floatbucket');
        $kv->llmstats->bucket($bucket);
        is($kv->llmstats->record($bucket, 1, 1, 0, 1e-05, 12), 'OK', 'LLMSTATS.RECORD with a tiny float cost');
        $kv->llmstats->price_del($model);
        $kv->llmstats->drop($bucket);
    }
}

# --- cleanup ---------------------------------------------------------------

$kv->del($z, $f, $h, $g, $s, $w);
$kv->close;
done_testing();
