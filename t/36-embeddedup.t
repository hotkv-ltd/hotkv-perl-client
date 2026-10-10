# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# EMBED.DEDUP.* requires the "embed-dedup" license feature. See
# t/32-pcache.t for why NOLICENSE detection is itself the assertion.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url unique_name is_nolicense);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();

use HotKV;

my $kv = HotKV->new(url => test_url());
my $ns = unique_name('embeddedup');

my $ok = eval { $kv->embeddedup->put($ns, 'hash1', 'text-embedding-3', '0.1,0.2,0.3'); 1 };
if (!$ok) {
    ok(is_nolicense($@), 'EMBED.DEDUP.PUT without the embed-dedup license raises NotLicensed')
        or diag("unexpected error: $@");
}

SKIP: {
    skip 'embed-dedup license feature not enabled by the test server', 8 unless $ok;

    is($kv->embeddedup->put($ns, 'hash1', 'text-embedding-3', '0.1,0.2,0.3'), 0, 'EMBED.DEDUP.PUT of an existing hash increments refcount instead');
    is($kv->embeddedup->get($ns, 'hash1'), '0.1,0.2,0.3', 'EMBED.DEDUP.GET');
    is($kv->embeddedup->get($ns, 'missing'), undef, 'EMBED.DEDUP.GET miss');
    my $stats = $kv->embeddedup->stats($ns);
    is(scalar(@$stats), 6, 'EMBED.DEDUP.STATS returns 3 pairs');
    ok((grep { $_ eq $ns } @{ $kv->embeddedup->list }) == 1, 'EMBED.DEDUP.LIST');
    is($kv->embeddedup->release($ns, 'hash1'), 1, 'EMBED.DEDUP.RELEASE');
    ok(defined $kv->embeddedup->purge($ns), 'EMBED.DEDUP.PURGE answers a count');
    is($kv->embeddedup->drop($ns), 1, 'EMBED.DEDUP.DROP');
}

$kv->close;
done_testing();
