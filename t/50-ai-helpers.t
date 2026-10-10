# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# HotKV::AI::SemanticCache needs the "semantic-cache" license feature;
# HotKV::AI::PromptCache needs "prompt-cache". Without them both raise
# NotLicensed; see t/32-pcache.t for why detecting that error is itself the
# assertion.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url unique_name is_nolicense);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();

use HotKV;
use HotKV::AI::PromptCache;
use HotKV::AI::SemanticCache;

my $kv = HotKV->new(url => test_url());

# --- HotKV::AI::SemanticCache -----------------------------------------------

{
    my $ns    = unique_name('ai-scache');
    my $cache = HotKV::AI::SemanticCache->new(client => $kv, ns => $ns);
    my $ok = eval { $cache->create(3, { threshold => 0.8 }); 1 };
    if (!$ok) {
        ok(is_nolicense($@), 'SemanticCache->create without the semantic-cache license raises NotLicensed')
            or diag("unexpected error: $@");
    }

    SKIP: {
        skip 'semantic-cache license feature not enabled by the test server', 6 unless $ok;

        my $calls = 0;
        my $r1 = $cache->get_or_call(
            query  => 'what does hotkv do',
            vector => [1, 0, 0],
            call   => sub {
                $calls++;
                return { response => 'HotKV is a fast in-memory data store.', model => 'claude-sonnet-5', output_tokens => 12 };
            },
        );
        is($r1->{cached}, 0, 'first lookup is a miss');
        is($calls, 1, 'the LLM call ran exactly once on a miss');
        is($r1->{response}, 'HotKV is a fast in-memory data store.', 'the miss response is returned');

        my $r2 = $cache->get_or_call(
            query  => 'what does hotkv do exactly',
            vector => [1, 0, 0],
            call   => sub { $calls++; return 'THIS SHOULD NOT RUN'; },
        );
        is($r2->{cached}, 1, 'second, near-identical lookup is a hit');
        is($calls, 1, 'the LLM call did not run again on a cache hit');
        is($r2->{response}, 'HotKV is a fast in-memory data store.', 'the cached response is returned');

        $kv->scache->drop($ns);
    }
}

# --- HotKV::AI::PromptCache: cache_key is usable with no client at all -----

{
    my $key = HotKV::AI::PromptCache->cache_key(
        provider => 'openai',
        model    => 'gpt-6-sol',
        messages => [{ role => 'user', content => 'hello' }],
        params   => { temperature => '0.7' },
    );
    like($key, qr/^[0-9a-f]{64}\z/, 'cache_key works standalone, without a client, for offline key computation');
}

# --- HotKV::AI::PromptCache::get_or_call (needs the prompt-cache license feature) --

{
    my $ns    = unique_name('ai-pcache');
    my $cache = HotKV::AI::PromptCache->new(client => $kv, ns => $ns, stats_bucket => $ns);
    my $calls = 0;
    my $created = eval { $kv->pcache->create($ns); 1 };
    my $ok = $created && eval {
        $cache->get_or_call(
            provider => 'openai',
            model    => 'gpt-6-sol',
            messages => [{ role => 'user', content => 'What is HotKV?' }],
            params   => { temperature => '0.0' },
            call     => sub {
                $calls++;
                return {
                    response => 'HotKV is a data store.', model => 'gpt-6-sol',
                    input_tokens => 10, output_tokens => 20, cost_usd => '0.001',
                };
            },
        );
        1;
    };
    if (!$ok) {
        ok(is_nolicense($@), 'PromptCache->get_or_call without the prompt-cache license raises NotLicensed')
            or diag("unexpected error: $@");
    }
    SKIP: {
        skip 'prompt-cache license feature not enabled by the test server', 4 unless $ok;
        is($calls, 1, 'the LLM call ran once on a miss');
        my $r2 = $cache->get_or_call(
            provider => 'openai', model => 'gpt-6-sol',
            messages => [{ role => 'user', content => 'What is HotKV?' }],
            params   => { temperature => '0.0' },
            call     => sub { $calls++; return { response => 'SHOULD NOT RUN' }; },
        );
        is($r2->{cached}, 1, 'an identical request is a cache hit');
        is($calls, 1, 'the LLM call did not run again on a cache hit');
        my $stats = $kv->pcache->stats($ns);
        ok($stats->{usage_saved_requests} >= 1, 'a later hit attributes the stored usage through PCACHE.STATS');
        $kv->pcache->drop($ns);
    }
}

$kv->close;
done_testing();
