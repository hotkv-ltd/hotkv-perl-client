# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# Exact argument lists for every new option and
# combination (the usage group; LLMSTATS.RECORD; LLMSTATS.PRICE), and
# parsing of canned RESP2 flat arrays and RESP3 maps for
# LLMSTATS.PRICE GET/LIST and the other changed STATS/GET/STATUS replies.
# No server: uses RecordingClient, a fake _call()/_is_deferred() target.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";

use RecordingClient;
use HotKV::TokenUsage;
use HotKV::LLMPrice;

# ---------------------------------------------------------------------------
# Usage group on SET / CONSUME
# ---------------------------------------------------------------------------

{
    my $rec = RecordingClient->new;
    my $usage = HotKV::TokenUsage->new(model => 'claude-sonnet-5', input_tokens => 10, output_tokens => 20);
    $rec->pcache->set('ns', 'prompt', 'response', { ttl => 60, meta => '{"k":1}', usage => $usage });
    is_deeply(
        $rec->last_call,
        ['PCACHE.SET', 'ns', 'prompt', 'response', 'TTL', 60, 'META', '{"k":1}',
         'MODEL', 'claude-sonnet-5', 'INPUT', 10, 'OUTPUT', 20],
        'PCACHE.SET appends the usage group after TTL/META'
    );
}

{
    my $rec = RecordingClient->new;
    $rec->pcache->set('ns', 'prompt', 'response');
    is_deeply($rec->last_call, ['PCACHE.SET', 'ns', 'prompt', 'response'], 'PCACHE.SET with no options/usage is unchanged');
}

{
    my $rec = RecordingClient->new;
    my $usage = HotKV::TokenUsage->new(model => 'gpt-6-sol', cache_read_tokens => 5);
    $rec->scache->set('ns', 'query text', 'response', [1, 0, 0], { ttl => 30, usage => $usage });
    is_deeply(
        $rec->last_call,
        ['SCACHE.SET', 'ns', 'query text', 'response', 1, 0, 0, 'TTL', 30, 'MODEL', 'gpt-6-sol', 'CACHEREAD', 5],
        'SCACHE.SET appends the usage group after the vector and TTL'
    );
}

for my $family (['toolcache', 'TOOL.CACHE'], ['ncache', 'NCACHE'], ['guard', 'GUARD'], ['rerank', 'RERANK']) {
    my ($accessor, $prefix) = @$family;
    my $rec = RecordingClient->new;
    my $usage = HotKV::TokenUsage->new(model => 'm', output_tokens => 7);
    $rec->$accessor->set('ns', 'key1', 'value1', { usage => $usage });
    is_deeply(
        $rec->last_call,
        ["$prefix.SET", 'ns', 'key1', 'value1', 'MODEL', 'm', 'OUTPUT', 7],
        "$prefix.SET appends the usage group"
    );
}

{
    my $rec = RecordingClient->new;
    my $usage = HotKV::TokenUsage->new(model => 'm', input_tokens => 100, cache_write_5m_tokens => 3);
    $rec->llmbudget->consume('budget1', { usage => $usage });
    is_deeply(
        $rec->last_call,
        ['LLMBUDGET.CONSUME', 'budget1', 0, 0, 'MODEL', 'm', 'INPUT', 100, 'CACHEWRITE5M', 3],
        'LLMBUDGET.CONSUME with usage sends tokens/cost_usd as 0/0'
    );
}

{
    my $rec = RecordingClient->new;
    $rec->llmbudget->consume('budget1', 1000, '0.05');
    is_deeply(
        $rec->last_call,
        ['LLMBUDGET.CONSUME', 'budget1', 1000, '0.05'],
        'LLMBUDGET.CONSUME with no usage is unchanged (positional tokens/cost_usd)'
    );
}

# ---------------------------------------------------------------------------
# LLMSTATS.RECORD options
# ---------------------------------------------------------------------------

{
    my $rec = RecordingClient->new;
    $rec->llmstats->record('bucket1', 100, 200, 10, '0.01', 250);
    is_deeply(
        $rec->last_call,
        ['LLMSTATS.RECORD', 'bucket1', 100, 200, 10, '0.01', 250],
        'LLMSTATS.RECORD with no options is unchanged'
    );
}

{
    my $rec = RecordingClient->new;
    $rec->llmstats->record('bucket1', 100, 200, 10, 0, 250, { error => 0, model => 'claude-sonnet-5' });
    is_deeply(
        $rec->last_call,
        ['LLMSTATS.RECORD', 'bucket1', 100, 200, 10, 0, 250, 'ERROR', 0, 'MODEL', 'claude-sonnet-5'],
        'LLMSTATS.RECORD ERROR 0 and MODEL'
    );
}

{
    my $rec = RecordingClient->new;
    $rec->llmstats->record(
        'bucket1', 100, 200, 10, 0, 250,
        { error => 1, model => 'claude-sonnet-5', cache_write_5m_tokens => 4, cache_write_1h_tokens => 9 }
    );
    is_deeply(
        $rec->last_call,
        [
            'LLMSTATS.RECORD', 'bucket1', 100, 200, 10, 0, 250,
            'ERROR', 1, 'MODEL', 'claude-sonnet-5', 'CACHEWRITE5M', 4, 'CACHEWRITE1H', 9,
        ],
        'LLMSTATS.RECORD every option together, in order'
    );
}

# ---------------------------------------------------------------------------
# LLMSTATS.PRICE SET / GET / LIST / DEL
# ---------------------------------------------------------------------------

{
    my $rec = RecordingClient->new;
    $rec->llmstats->price_set('claude-sonnet-5', 3, 15);
    is_deeply(
        $rec->last_call,
        ['LLMSTATS.PRICE', 'SET', 'claude-sonnet-5', 'INPUT', '3', 'OUTPUT', '15'],
        'LLMSTATS.PRICE SET with only the required prices'
    );
}

{
    my $rec = RecordingClient->new;
    $rec->llmstats->price_set(
        'claude-sonnet-5', '3.00', '15.00',
        { cache_read_usd_per_mtok => '0.30', cache_write_5m_usd_per_mtok => 3.75, cache_write_1h_usd_per_mtok => 6 }
    );
    is_deeply(
        $rec->last_call,
        [
            'LLMSTATS.PRICE', 'SET', 'claude-sonnet-5', 'INPUT', '3.00', 'OUTPUT', '15.00',
            'CACHEREAD', '0.30', 'CACHEWRITE5M', '3.75', 'CACHEWRITE1H', '6',
        ],
        'LLMSTATS.PRICE SET with every optional cache price, formatted'
    );
}

{
    my $rec = RecordingClient->new;
    $rec->llmstats->price_get('claude-sonnet-5');
    is_deeply($rec->last_call, ['LLMSTATS.PRICE', 'GET', 'claude-sonnet-5'], 'LLMSTATS.PRICE GET');
}

{
    my $rec = RecordingClient->new;
    $rec->llmstats->price_list;
    is_deeply($rec->last_call, ['LLMSTATS.PRICE', 'LIST'], 'LLMSTATS.PRICE LIST');
}

{
    my $rec = RecordingClient->new;
    $rec->llmstats->price_del('claude-sonnet-5');
    is_deeply($rec->last_call, ['LLMSTATS.PRICE', 'DEL', 'claude-sonnet-5'], 'LLMSTATS.PRICE DEL');
}

# ---------------------------------------------------------------------------
# STATS/GET/STATUS parsing, both RESP2 flat array and RESP3 map shapes
# ---------------------------------------------------------------------------

my @PCACHE_STATS = (
    entries => 3, hits => 2, misses => 1, evictions => 0, memory_bytes => 4096,
    hit_rate => '0.666667', p50_ns => 1200, p95_ns => 3400, p99_ns => 5600, cost_saved_usd => '0.004500',
    usage_saved_requests => 2, usage_saved_input_tokens => 240, usage_saved_output_tokens => 80,
    usage_saved_cache_read_tokens => 20, usage_saved_cache_write_tokens => 0, usage_saved_cost_usd => '0.000160',
);

for my $shape ('flat array', 'native map') {
    my $reply = $shape eq 'flat array' ? [@PCACHE_STATS] : { @PCACHE_STATS };
    my $rec = RecordingClient->new(reply => $reply);
    my $stats = $rec->pcache->stats('ns');
    is($stats->{entries}, 3, "PCACHE.STATS ($shape) entries");
    is($stats->{hit_rate}, 0.666667, "PCACHE.STATS ($shape) hit_rate is numified");
    is($stats->{cost_saved_usd}, 0.0045, "PCACHE.STATS ($shape) cost_saved_usd is numified");
    is($stats->{usage_saved_cost_usd}, 0.00016, "PCACHE.STATS ($shape) usage_saved_cost_usd is numified");
    is($stats->{usage_saved_input_tokens}, 240, "PCACHE.STATS ($shape) usage_saved_input_tokens");
}

my @SCACHE_STATS = (
    entries => 1, hits => 4, misses => 1, hit_rate => '0.800000', p50_us => 42,
    usage_saved_requests => 4, usage_saved_input_tokens => 400, usage_saved_output_tokens => 120,
    usage_saved_cache_read_tokens => 0, usage_saved_cache_write_tokens => 0, usage_saved_cost_usd => '0.001200',
);

for my $shape ('flat array', 'native map') {
    my $reply = $shape eq 'flat array' ? [@SCACHE_STATS] : { @SCACHE_STATS };
    my $rec = RecordingClient->new(reply => $reply);
    my $stats = $rec->scache->stats('ns');
    is($stats->{entries}, 1, "SCACHE.STATS ($shape) entries");
    is($stats->{hit_rate}, 0.8, "SCACHE.STATS ($shape) hit_rate is numified");
    is($stats->{usage_saved_cost_usd}, 0.0012, "SCACHE.STATS ($shape) usage_saved_cost_usd is numified");
}

my @KEYED_STATS = (
    entries => 5, hits => 2, misses => 3, evictions => 1, memory_bytes => 512,
    usage_saved_requests => 2, usage_saved_input_tokens => 20, usage_saved_output_tokens => 10,
    usage_saved_cache_read_tokens => 0, usage_saved_cache_write_tokens => 0, usage_saved_cost_usd => '0.000050',
);

for my $shape ('flat array', 'native map') {
    my $reply = $shape eq 'flat array' ? [@KEYED_STATS] : { @KEYED_STATS };
    my $rec = RecordingClient->new(reply => $reply);
    my $stats = $rec->toolcache->stats('ns');
    is($stats->{entries}, 5, "TOOL.CACHE.STATS ($shape) entries");
    is($stats->{usage_saved_cost_usd}, 0.00005, "TOOL.CACHE.STATS ($shape) usage_saved_cost_usd is numified");
}

my @LLMSTATS_GET = (
    requests => 10, errors => 1, input_tokens => 1000, output_tokens => 500, cached_tokens => 100,
    cost_usd => '0.012500', avg_latency_ms => '210.500000', requests_1m => 2, tokens_1m => 300,
    cost_usd_1m => '0.003000', cache_write_5m_tokens => 4, cache_write_1h_tokens => 9, unpriced_requests => 1,
);

for my $shape ('flat array', 'native map') {
    my $reply = $shape eq 'flat array' ? [@LLMSTATS_GET] : { @LLMSTATS_GET };
    my $rec = RecordingClient->new(reply => $reply);
    my $stats = $rec->llmstats->get('bucket1');
    is($stats->{requests}, 10, "LLMSTATS.GET ($shape) requests");
    is($stats->{cost_usd}, 0.0125, "LLMSTATS.GET ($shape) cost_usd is numified");
    is($stats->{avg_latency_ms}, 210.5, "LLMSTATS.GET ($shape) avg_latency_ms is numified");
    is($stats->{cache_write_5m_tokens}, 4, "LLMSTATS.GET ($shape) cache_write_5m_tokens");
    is($stats->{unpriced_requests}, 1, "LLMSTATS.GET ($shape) unpriced_requests");
}

my @LLMBUDGET_STATUS = (
    tokens_used => 1000, token_limit => 100000, cost_used_usd => '0.050000', cost_limit_usd => '10.000000',
    window_seconds => 3600, window_remaining => 1800, requests_allowed => 5, requests_rejected => 0,
    unpriced_requests => 0,
);

for my $shape ('flat array', 'native map') {
    my $reply = $shape eq 'flat array' ? [@LLMBUDGET_STATUS] : { @LLMBUDGET_STATUS };
    my $rec = RecordingClient->new(reply => $reply);
    my $status = $rec->llmbudget->status('budget1');
    is($status->{tokens_used}, 1000, "LLMBUDGET.STATUS ($shape) tokens_used");
    is($status->{cost_used_usd}, 0.05, "LLMBUDGET.STATUS ($shape) cost_used_usd is numified");
    is($status->{cost_limit_usd}, 10, "LLMBUDGET.STATUS ($shape) cost_limit_usd is numified");
    is($status->{unpriced_requests}, 0, "LLMBUDGET.STATUS ($shape) unpriced_requests");
}

# --- LLMSTATS.PRICE GET/LIST parsing, both shapes, through the real wrapper -

my @PRICE_ENTRY = (
    model => 'claude-sonnet-5', source => 'default', priced => 1, retired => 0,
    input_usd_per_mtok => '3.000000', output_usd_per_mtok => '15.000000',
    cache_read_usd_per_mtok => '0.300000', cache_write_5m_usd_per_mtok => '3.750000',
    cache_write_1h_usd_per_mtok => '6.000000',
);

for my $shape ('flat array', 'native map') {
    my $reply = $shape eq 'flat array' ? [@PRICE_ENTRY] : { @PRICE_ENTRY };
    my $rec = RecordingClient->new(reply => $reply);
    my $price = $rec->llmstats->price_get('claude-sonnet-5');
    isa_ok($price, 'HotKV::LLMPrice', "LLMSTATS.PRICE GET ($shape)");
    is($price->source, 'default', "LLMSTATS.PRICE GET ($shape) source");
    is($price->input_usd_per_mtok, 3, "LLMSTATS.PRICE GET ($shape) input_usd_per_mtok is numeric");
    is($price->cache_write_1h_usd_per_mtok, 6, "LLMSTATS.PRICE GET ($shape) cache_write_1h_usd_per_mtok is numeric");
}

for my $shape ('flat array', 'native map') {
    my $entry = $shape eq 'flat array' ? [@PRICE_ENTRY] : { @PRICE_ENTRY };
    my $rec = RecordingClient->new(reply => [$entry, $entry]);
    my $prices = $rec->llmstats->price_list;
    is(ref($prices), 'ARRAY', "LLMSTATS.PRICE LIST ($shape) returns an arrayref");
    is(scalar(@$prices), 2, "LLMSTATS.PRICE LIST ($shape) one entry per model");
    isa_ok($prices->[0], 'HotKV::LLMPrice', "LLMSTATS.PRICE LIST ($shape) entry");
    is($prices->[0]->model, 'claude-sonnet-5', "LLMSTATS.PRICE LIST ($shape) entry model");
}

# ---------------------------------------------------------------------------
# Pipelining/transaction compatibility: a deferred _call() result (the
# queuing object handed back to itself) must pass through unparsed.
# ---------------------------------------------------------------------------

{
    my $rec = RecordingClient->new;
    $rec->{reply} = $rec; # simulate HotKV::Pipeline/::Transaction's _call() returning $self while queuing
    is($rec->pcache->stats('ns'), $rec, 'PCache->stats passes a deferred result through unparsed');
    is($rec->scache->stats('ns'), $rec, 'SCache->stats passes a deferred result through unparsed');
    is($rec->toolcache->stats('ns'), $rec, 'Keyed->stats passes a deferred result through unparsed');
    is($rec->llmstats->get('b'), $rec, 'LLMStats->get passes a deferred result through unparsed');
    is($rec->llmstats->price_get('m'), $rec, 'LLMStats->price_get passes a deferred result through unparsed');
    is($rec->llmstats->price_list, $rec, 'LLMStats->price_list passes a deferred result through unparsed');
    is($rec->llmbudget->status('b'), $rec, 'LLMBudget->status passes a deferred result through unparsed');
}

done_testing();
