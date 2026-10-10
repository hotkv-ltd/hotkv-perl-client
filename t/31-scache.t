# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# SCACHE.* needs a server license that includes the "semantic-cache" feature.
# Against a server without it every call below raises NotLicensed; see
# t/32-pcache.t for why detecting that error is itself the assertion.

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
my $ns = unique_name('scache');

my $create_ok = eval { $kv->scache->create($ns, 3, { metric => 'cosine', threshold => 0.8 }); 1 };
if (!$create_ok) {
    ok(is_nolicense($@), 'SCACHE.CREATE without the semantic-cache license raises NotLicensed')
        or diag("unexpected error: $@");
}

SKIP: {
    skip 'semantic-cache license feature not enabled by the test server', 16 unless $create_ok;

    my $usage = HotKV::TokenUsage->new(model => 'claude-sonnet-5', input_tokens => 120, output_tokens => 40);
    is($kv->scache->set($ns, 'what is hotkv', 'a fast kv store', [1, 0, 0], { usage => $usage }), 'OK', 'SCACHE.SET');

    my $hit = $kv->scache->get($ns, [1, 0, 0]);
    is($hit->[0], 'a fast kv store', 'SCACHE.GET exact match returns the stored response');
    ok($hit->[1] >= 0.99, 'SCACHE.GET similarity for an identical vector is ~1.0');

    my $near = $kv->scache->get($ns, [0.95, 0.05, 0]);
    ok(defined $near, 'SCACHE.GET finds a near neighbor above the default threshold');

    my $far = $kv->scache->get($ns, [0, 0, 1], { threshold => 0.99 });
    is($far, undef, 'SCACHE.GET returns nil below the similarity threshold');

    my $stats = $kv->scache->stats($ns);
    is($stats->{entries}, 1, 'SCACHE.STATS entries');
    ok($stats->{hits} >= 1, 'SCACHE.STATS counted at least one hit');
    ok($stats->{usage_saved_requests} >= 1, 'SCACHE.STATS usage_saved_requests reflects the usage stored with the entry');
    is($stats->{usage_saved_input_tokens}, 120 * $stats->{usage_saved_requests}, 'SCACHE.STATS usage_saved_input_tokens');

    is($kv->scache->threshold($ns, 0), 'OK', 'SCACHE.THRESHOLD');
    ok(defined $kv->scache->get($ns, [0, 0, 1]), 'a threshold of 0 now matches the orthogonal (similarity 0) vector');

    ok((grep { $_ eq $ns } @{ $kv->scache->list }) == 1, 'SCACHE.LIST includes this namespace exactly once');
    is($kv->scache->flush($ns), 1, 'SCACHE.FLUSH reports the namespace existed');
    is($kv->scache->get($ns, [1, 0, 0]), undef, 'SCACHE.GET after FLUSH is nil');
    is($kv->scache->drop($ns), 1, 'SCACHE.DROP reports the namespace existed');
    is($kv->scache->drop($ns), 0, 'SCACHE.DROP again reports nothing to drop');
}

$kv->close;
done_testing();
