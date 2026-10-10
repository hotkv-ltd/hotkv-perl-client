# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# TS.* requires the "time-series" license feature. Without it every call
# below raises NotLicensed; see t/32-pcache.t for why detecting that error
# is itself the assertion.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url unique_name is_nolicense);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();

use HotKV;

my $kv = HotKV->new(url => test_url());
my $key = unique_name('ts');

my $ok = eval { $kv->ts->create($key, { retention => 0, labels => ['region', 'eu', 'host', 'a'] }); 1 };
if (!$ok) {
    ok(is_nolicense($@), 'TS.CREATE without the time-series license raises NotLicensed')
        or diag("unexpected error: $@");
}

SKIP: {
    skip 'time-series license feature not enabled by the test server', 14 unless $ok;

    my $t1 = $kv->ts->add($key, 1000, 1.5);
    is($t1, 1000, 'TS.ADD with an explicit timestamp returns it');
    $kv->ts->add($key, 2000, 2.5);
    $kv->ts->add($key, 3000, 3.5);

    my $missing_key = unique_name('ts-missing');
    my $err = eval { $kv->ts->add($missing_key, 1000, 1); 1 } ? undef : $@;
    ok($err, 'TS.ADD on a series that was never created raises');

    my $range = $kv->ts->range($key, '-', '+');
    is(scalar(@$range), 3, 'TS.RANGE with -/+ returns every sample');
    is($range->[0][0], 1000, 'TS.RANGE first sample timestamp');
    is($range->[0][1] + 0, 1.5, 'TS.RANGE first sample value');

    is(scalar(@{ $kv->ts->range($key, 1000, 2000) }), 2, 'TS.RANGE with a bounded window');
    is(scalar(@{ $kv->ts->range($key, '-', '+', { count => 1 }) }), 1, 'TS.RANGE COUNT limits results');

    my $agg = $kv->ts->agg($key, '-', '+', 10000, 'sum');
    is(scalar(@$agg), 1, 'TS.AGG with a bucket wider than the data returns one bucket');
    is($agg->[0][1] + 0, 1.5 + 2.5 + 3.5, 'TS.AGG sum aggregates all three samples');

    my $info = $kv->ts->info($key);
    my %info_h = @$info;
    is($info_h{totalSamples}, 3, 'TS.INFO totalSamples');
    is($info_h{key}, $key, 'TS.INFO key');
    is(ref($info_h{labels}), 'ARRAY', 'TS.INFO labels is a nested array, not flattened');
    is($info_h{rules}, 0, 'TS.INFO rules is 0 before any downsample rule is attached');

    is($kv->ts->retention($key, 60000), 'OK', 'TS.RETENTION');

    my $dest = unique_name('ts-dest');
    $kv->ts->create($dest);
    is($kv->ts->downsample($key, $dest, 'avg', 5000), 'OK', 'TS.DOWNSAMPLE adds a live rule');
    my %info_h2 = @{ $kv->ts->info($key) };
    is($info_h2{rules}, 1, 'TS.INFO rules count reflects the attached downsample rule');

    ok((grep { $_ eq $key } @{ $kv->ts->list }) >= 1, 'TS.LIST includes this series');
    ok((grep { $_ eq $key } @{ $kv->ts->list({ label => ['region', 'eu'] }) }) >= 1, 'TS.LIST LABEL filter matches this series');
    is_deeply($kv->ts->list({ label => ['region', 'does-not-exist'] }), [], 'TS.LIST LABEL filter excludes a non-matching value');

    is($kv->ts->delete($key), 'OK', 'TS.DELETE');
    $kv->ts->delete($dest);
}

$kv->close;
done_testing();
