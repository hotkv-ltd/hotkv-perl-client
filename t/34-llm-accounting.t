# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# LLMSTATS.* and LLMBUDGET.* need the llm-stats and llm-budget license features.
# See t/32-pcache.t for why NOLICENSE detection is itself the assertion.

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

# --- LLMSTATS.* -----------------------------------------------------------

{
    my $bucket = unique_name('llmstats');
    my $ok = eval { $kv->llmstats->bucket($bucket); 1 };
    if (!$ok) {
        ok(is_nolicense($@), 'LLMSTATS.BUCKET without the llm-stats license raises NotLicensed')
            or diag("unexpected error: $@");
    }
    SKIP: {
        skip 'llm-stats license feature not enabled by the test server', 18 unless $ok;

        is($kv->llmstats->record($bucket, 100, 200, 10, '0.01', 250, { error => 0 }), 'OK', 'LLMSTATS.RECORD (legacy cost_usd)');
        is(
            $kv->llmstats->record(
                $bucket, 100, 200, 10, 0, 250,
                { model => 'claude-sonnet-5', cache_write_5m_tokens => 4, cache_write_1h_tokens => 2 }
            ),
            'OK',
            'LLMSTATS.RECORD with MODEL and CACHEWRITE5M/CACHEWRITE1H'
        );
        my $stats = $kv->llmstats->get($bucket);
        is(ref($stats), 'HASH', 'LLMSTATS.GET is parsed into a hashref');
        is($stats->{requests}, 2, 'LLMSTATS.GET requests');
        is($stats->{cache_write_5m_tokens}, 4, 'LLMSTATS.GET cache_write_5m_tokens');
        is($stats->{cache_write_1h_tokens}, 2, 'LLMSTATS.GET cache_write_1h_tokens');
        ok(exists $stats->{unpriced_requests}, 'LLMSTATS.GET unpriced_requests present (the model above has no price set)');
        ok((grep { $_ eq $bucket } @{ $kv->llmstats->list }) == 1, 'LLMSTATS.LIST');
        is($kv->llmstats->reset($bucket), 1, 'LLMSTATS.RESET');
        is($kv->llmstats->drop($bucket), 1, 'LLMSTATS.DROP');

        # --- LLMSTATS.PRICE SET/GET/LIST/DEL ---
        my $model = unique_name('model');
        is($kv->llmstats->price_set($model, 3, 15), 'OK', 'LLMSTATS.PRICE SET with only the required prices');
        my $price = $kv->llmstats->price_get($model);
        isa_ok($price, 'HotKV::LLMPrice', 'LLMSTATS.PRICE GET');
        is($price->source, 'custom', 'LLMSTATS.PRICE GET source is custom after SET');
        is($price->input_usd_per_mtok, 3, 'LLMSTATS.PRICE GET input_usd_per_mtok');
        is($price->cache_read_usd_per_mtok, 0.3, 'LLMSTATS.PRICE GET defaults cache_read to 0.1x input');
        ok((grep { $_->model eq $model } @{ $kv->llmstats->price_list }) == 1, 'LLMSTATS.PRICE LIST includes the custom model');
        is($kv->llmstats->price_del($model), 1, 'LLMSTATS.PRICE DEL removes the custom override');
        is($kv->llmstats->price_get($model)->source, 'unpriced', 'LLMSTATS.PRICE GET after DEL falls back to unpriced');
    }
}

# --- LLMBUDGET.* ------------------------------------------------------

{
    my $budget = unique_name('llmbudget');
    my $ok = eval { $kv->llmbudget->set($budget, 100000, '10.00', 3600); 1 };
    if (!$ok) {
        ok(is_nolicense($@), 'LLMBUDGET.SET without the llm-budget license raises NotLicensed')
            or diag("unexpected error: $@");
    }
    SKIP: {
        skip 'llm-budget license feature not enabled by the test server', 7 unless $ok;

        is($kv->llmbudget->consume($budget, 1000, '0.05'), 1, 'LLMBUDGET.CONSUME within budget (legacy tokens/cost_usd)');
        my $usage = HotKV::TokenUsage->new(model => 'claude-sonnet-5', input_tokens => 100, output_tokens => 20);
        is($kv->llmbudget->consume($budget, { usage => $usage }), 1, 'LLMBUDGET.CONSUME with a usage group');
        my $status = $kv->llmbudget->status($budget);
        is(ref($status), 'HASH', 'LLMBUDGET.STATUS is parsed into a hashref');
        ok(exists $status->{unpriced_requests}, 'LLMBUDGET.STATUS unpriced_requests present');
        ok((grep { $_ eq $budget } @{ $kv->llmbudget->list }) == 1, 'LLMBUDGET.LIST');
        is($kv->llmbudget->reset($budget), 1, 'LLMBUDGET.RESET');
        is($kv->llmbudget->drop($budget), 1, 'LLMBUDGET.DROP');
    }
}

$kv->close;
done_testing();
