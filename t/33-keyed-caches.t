# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# TOOL.CACHE.* / NCACHE.* / GUARD.* / RERANK.* each need their own license
# feature (tool-cache, negative-cache, guard-cache, rerank-cache). Same
# approach as t/32-pcache.t: prove the wire syntax with a real NOLICENSE,
# then run the full family for real whenever the license includes the
# feature.

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

for my $family (
    ['toolcache', 'TOOL.CACHE'],
    ['ncache',    'NCACHE'],
    ['guard',     'GUARD'],
    ['rerank',    'RERANK'],
) {
    my ($accessor, $label) = @$family;
    my $ns = unique_name($accessor);
    my $handle = $kv->$accessor;

    my $ok = eval { $handle->create($ns, { max_entries => 50, ttl => 60 }); 1 };
    if (!$ok) {
        ok(is_nolicense($@), "$label.CREATE without its license feature raises NotLicensed")
            or diag("unexpected error: $@");
    }

    SKIP: {
        skip "$label license feature not enabled by the test server", 10 unless $ok;

        my $usage = HotKV::TokenUsage->new(model => 'claude-sonnet-5', output_tokens => 25);
        is($handle->set($ns, 'key1', 'value1', { ttl => 60, meta => '{}', usage => $usage }), 'OK', "$label.SET");
        is($handle->get($ns, 'key1'), 'value1', "$label.GET");
        is($handle->get($ns, 'missing'), undef, "$label.GET miss");
        my $stats = $handle->stats($ns);
        is(ref($stats), 'HASH', "$label.STATS is parsed into a hashref");
        is($stats->{entries}, 1, "$label.STATS entries");
        ok($stats->{usage_saved_requests} >= 1, "$label.STATS usage_saved_requests reflects the usage stored with the entry");
        ok((grep { $_ eq $ns } @{ $handle->list }) == 1, "$label.LIST");
        is($handle->del($ns, 'key1'), 1, "$label.DEL");
        ok($handle->flush($ns) >= 0, "$label.FLUSH");
        is($handle->drop($ns), 1, "$label.DROP");
    }
}

$kv->close;
done_testing();
