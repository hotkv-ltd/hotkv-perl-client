# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# RAG.* requires the "rag-pipeline" license feature. Without it every call
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
my $pipeline = unique_name('rag');

my $ok = eval { $kv->rag->create($pipeline, 3, { strategy => 'fixed', chunk_size => 100 }); 1 };
if (!$ok) {
    ok(is_nolicense($@), 'RAG.CREATE without the rag-pipeline license raises NotLicensed')
        or diag("unexpected error: $@");
}

SKIP: {
    skip 'rag-pipeline license feature not enabled by the test server', 9 unless $ok;

    my $chunks = $kv->rag->ingest($pipeline, 'doc1', 'HotKV is a fast in-memory data store.', {
        meta    => ['source', 'unit-test'],
        vectors => [[1, 0, 0]],
    });
    is($chunks, 1, 'RAG.INGEST reports one chunk ingested');

    my $results = $kv->rag->search($pipeline, 'fast data store', { k => 5, vector => [1, 0, 0] });
    ok(scalar(@$results) >= 1, 'RAG.SEARCH finds the ingested chunk');
    is($results->[0][1], 'doc1', 'RAG.SEARCH result carries the doc_id in the expected position');

    my $stats = $kv->rag->stats($pipeline);
    my %stats_h = @$stats;
    is($stats_h{name}, $pipeline, 'RAG.STATS name');
    is($stats_h{dimensions}, 3, 'RAG.STATS dimensions');
    ok($stats_h{totalIngested} >= 1, 'RAG.STATS totalIngested');

    ok((grep { $_ eq $pipeline } @{ $kv->rag->list }) == 1, 'RAG.LIST includes this pipeline');
    is($kv->rag->drop($pipeline), 'OK', 'RAG.DROP');
    my $err = eval { $kv->rag->drop($pipeline); 1 } ? undef : $@;
    ok($err, 'RAG.DROP on an already-dropped pipeline raises');
}

$kv->close;
done_testing();
