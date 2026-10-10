# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# PCACHE.* needs a server license that includes the "prompt-cache" feature.
# The wire syntax is still exercised so a NOLICENSE (not any other error,
# which would indicate a real encoding bug) proves the request reached the
# license check correctly; the functional assertions run for real whenever
# the license includes the feature.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url unique_name is_nolicense);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();

use HotKV;
use HotKV::TokenUsage;

my $kv = HotKV->new(url => test_url());
my $ns = unique_name('pcache');

my $create_ok = eval { $kv->pcache->create($ns, { max_entries => 100, ttl => 60, cost_per_hit => '0.002' }); 1 };
if (!$create_ok) {
    ok(is_nolicense($@), 'PCACHE.CREATE without the prompt-cache license raises NotLicensed')
        or diag("unexpected error: $@");
}

SKIP: {
    skip 'prompt-cache license feature not enabled by the test server', 16 unless $create_ok;

    my $usage = HotKV::TokenUsage->new(model => 'claude-sonnet-5', input_tokens => 50, output_tokens => 10);
    is($kv->pcache->set($ns, 'prompt1', 'response1', { ttl => 60, meta => '{"k":1}', usage => $usage }), 'OK', 'PCACHE.SET');
    is($kv->pcache->get($ns, 'prompt1'), 'response1', 'PCACHE.GET');
    is($kv->pcache->get($ns, 'missing'), undef, 'PCACHE.GET miss');
    my $getex = $kv->pcache->getex($ns, 'prompt1');
    is($getex->[0], 'response1', 'PCACHE.GETEX response');
    ok($getex->[2] >= 1, 'PCACHE.GETEX hit_count');
    my $stats = $kv->pcache->stats($ns);
    is(ref($stats), 'HASH', 'PCACHE.STATS is parsed into a hashref');
    is($stats->{entries}, 1, 'PCACHE.STATS entries');
    ok($stats->{hits} >= 1, 'PCACHE.STATS hits');
    ok($stats->{usage_saved_requests} >= 1, 'PCACHE.STATS usage_saved_requests reflects the usage stored with the entry');
    is($stats->{usage_saved_input_tokens}, 50 * $stats->{usage_saved_requests}, 'PCACHE.STATS usage_saved_input_tokens');
    is($kv->pcache->config_set($ns, 'ttl', 120), 'OK', 'PCACHE.CONFIG SET');
    is($kv->pcache->del($ns, 'prompt1'), 1, 'PCACHE.DEL');
    ok((grep { $_ eq $ns } @{ $kv->pcache->list }) == 1, 'PCACHE.LIST');
    $kv->pcache->set($ns, 'p2', 'r2');
    ok($kv->pcache->flush($ns) >= 1, 'PCACHE.FLUSH');
    is($kv->pcache->drop($ns), 1, 'PCACHE.DROP');
    is($kv->pcache->drop($ns), 0, 'PCACHE.DROP again finds nothing');
}

$kv->close;
done_testing();
