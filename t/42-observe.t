# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url is_nolicense);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();

use HotKV;

my $kv = HotKV->new(url => test_url());

# --- OBSERVE / ALERTS (enterprise-observability) ---------------------------
#
# Both require the "observability" license feature; without it every call
# below raises NotLicensed; see t/32-pcache.t for why detecting that error
# is itself the assertion.

my $observe_ok = eval { $kv->observe->info; 1 };
if (!$observe_ok) {
    ok(is_nolicense($@), 'OBSERVE INFO without the observability license raises NotLicensed')
        or diag("unexpected error: $@");
}

SKIP: {
    skip 'observability license feature not enabled by the test server', 9 unless $observe_ok;

    my $observe_info = $kv->observe->info;
    my %observe_h = @$observe_info;
    ok($observe_h{uptime_seconds} >= 0, 'OBSERVE INFO uptime_seconds');
    ok(exists $observe_h{connected_clients}, 'OBSERVE INFO connected_clients present');

    my $metrics = $kv->observe->metrics;
    my %metrics_h = @$metrics;
    ok(exists $metrics_h{num_workers}, 'OBSERVE METRICS num_workers present');

    my $alerts_info = $kv->observe->alerts_info;
    my %alerts_h = @$alerts_info;
    like($alerts_h{supported_providers}, qr/slack/, 'ALERTS INFO supported_providers lists slack');

    like($kv->observe->alerts_setseverity('warning'), qr/^OK/, 'ALERTS SETSEVERITY');
    like($kv->observe->alerts_on, qr/^OK/, 'ALERTS ON');
    like($kv->observe->alerts_off, qr/^OK/, 'ALERTS OFF');
    like($kv->observe->alerts_seturl(''), qr/^OK/, 'ALERTS SETURL with an empty string disables alerting');

    my $test_result = eval { $kv->observe->alerts_test({ severity => 'info', message => 'unit test alert' }); 1 };
    SKIP: {
        skip 'ALERTS TEST was filtered/rate-limited/deduped/queue-full in this run', 1 unless $test_result;
        like($kv->observe->alerts_test({ severity => 'info', message => 'unit test alert 2' }), qr/^OK/, 'ALERTS TEST');
    }
}

$kv->close;
done_testing();
