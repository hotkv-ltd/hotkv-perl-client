# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# HotKV::AI::PromptCache / HotKV::AI::SemanticCache: usage passthrough on
# a miss. No server: uses RecordingClient, a
# fake _call() target, so every PCACHE.GET/SCACHE.GET in these tests is a
# miss (RecordingClient's canned reply is undef unless a test sets one).

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";

use RecordingClient;
use HotKV::AI::PromptCache;
use HotKV::AI::SemanticCache;

sub calls_named {
    my ($rec, $name) = @_;
    return grep { $_->[0] eq $name } @{ $rec->calls };
}

# ---------------------------------------------------------------------------
# PromptCache: a miss whose call returns a plain scalar sends no usage.
# ---------------------------------------------------------------------------

{
    my $rec   = RecordingClient->new;
    my $cache = HotKV::AI::PromptCache->new(client => $rec, ns => 'ns1');
    my $r = $cache->get_or_call(
        provider => 'openai', model => 'gpt-6-sol', messages => [{ role => 'user', content => 'hi' }],
        call => sub { return 'plain response'; },
    );
    is($r->{cached}, 0, 'miss reported');
    is($r->{response}, 'plain response', 'plain scalar response is used as-is');
    my ($set_call) = calls_named($rec, 'PCACHE.SET');
    ok($set_call, 'PCACHE.SET was called');
    ok(!(grep { $_ eq 'MODEL' } @$set_call), 'PCACHE.SET carries no usage group when the call returns a plain scalar');
}

# --- a hashref without model still sends no usage, but does report stats --

{
    my $rec   = RecordingClient->new;
    my $cache = HotKV::AI::PromptCache->new(client => $rec, ns => 'ns1', stats_bucket => 'bucket1');
    $cache->get_or_call(
        provider => 'openai', model => 'gpt-6-sol', messages => [{ role => 'user', content => 'hi' }],
        call => sub { return { response => 'r', input_tokens => 10, output_tokens => 5, cost_usd => '0.001' }; },
    );
    my ($set_call) = calls_named($rec, 'PCACHE.SET');
    ok(!(grep { $_ eq 'MODEL' } @$set_call), 'no model means no usage group on PCACHE.SET');
    my ($record_call) = calls_named($rec, 'LLMSTATS.RECORD');
    ok($record_call, 'LLMSTATS.RECORD was called because stats_bucket is set');
    is($record_call->[1], 'bucket1', 'LLMSTATS.RECORD bucket');
    is($record_call->[2], 10, 'LLMSTATS.RECORD input_tokens');
    is($record_call->[5], '0.001', 'LLMSTATS.RECORD cost_usd is passed through when no model is given');
}

# --- a hashref with model sends a usage group on both SET and RECORD ------

{
    my $rec   = RecordingClient->new;
    my $cache = HotKV::AI::PromptCache->new(client => $rec, ns => 'ns1', stats_bucket => 'bucket1');
    $cache->get_or_call(
        provider => 'openai', model => 'gpt-6-sol', messages => [{ role => 'user', content => 'hi' }],
        call => sub {
            return {
                response => 'r', model => 'gpt-6-sol', input_tokens => 10, output_tokens => 5,
                cached_tokens => 2, cache_write_5m_tokens => 1, cost_usd => '0.001', error => 0,
            };
        },
    );
    my ($set_call) = calls_named($rec, 'PCACHE.SET');
    my %set_h = @{$set_call}[4 .. $#$set_call]; # options after (PCACHE.SET, ns, key, response)
    is($set_h{MODEL}, 'gpt-6-sol', 'PCACHE.SET carries MODEL when the call reports one');
    is($set_h{INPUT}, 10, 'PCACHE.SET carries INPUT');
    is($set_h{CACHEREAD}, 2, 'PCACHE.SET carries CACHEREAD from cached_tokens');
    is($set_h{CACHEWRITE5M}, 1, 'PCACHE.SET carries CACHEWRITE5M');

    my ($record_call) = calls_named($rec, 'LLMSTATS.RECORD');
    is($record_call->[5], 0, 'LLMSTATS.RECORD cost_usd is forced to 0 when a model is given');
    my %record_h = @{$record_call}[7 .. $#$record_call];
    is($record_h{MODEL}, 'gpt-6-sol', 'LLMSTATS.RECORD carries MODEL too');
    is($record_h{ERROR}, 0, 'LLMSTATS.RECORD carries ERROR 0');
}

# --- a cache hit never calls the block or touches PCACHE.SET/LLMSTATS -----

{
    my $rec   = RecordingClient->new(reply => 'cached response');
    my $cache = HotKV::AI::PromptCache->new(client => $rec, ns => 'ns1', stats_bucket => 'bucket1');
    my $calls = 0;
    my $r = $cache->get_or_call(
        provider => 'openai', model => 'gpt-6-sol', messages => [{ role => 'user', content => 'hi' }],
        call => sub { $calls++; return 'SHOULD NOT RUN'; },
    );
    is($r->{cached}, 1, 'a hit is reported');
    is($r->{response}, 'cached response', 'the cached response is returned');
    is($calls, 0, 'the call block never runs on a hit');
    ok(!calls_named($rec, 'PCACHE.SET'), 'no PCACHE.SET on a hit');
    ok(!calls_named($rec, 'LLMSTATS.RECORD'), 'no LLMSTATS.RECORD on a hit');
}

# ---------------------------------------------------------------------------
# SemanticCache: a miss whose call returns a plain scalar sends no usage.
# ---------------------------------------------------------------------------

{
    my $rec   = RecordingClient->new;
    my $cache = HotKV::AI::SemanticCache->new(client => $rec, ns => 'ns1');
    my $r = $cache->get_or_call(query => 'q', vector => [1, 0, 0], call => sub { return 'plain'; });
    is($r->{cached}, 0, 'miss reported');
    my ($set_call) = calls_named($rec, 'SCACHE.SET');
    ok($set_call, 'SCACHE.SET was called');
    ok(!(grep { $_ eq 'MODEL' } @$set_call), 'SCACHE.SET carries no usage group when the call returns a plain scalar');
}

# --- a hashref with model sends a usage group on SCACHE.SET ----------------

{
    my $rec   = RecordingClient->new;
    my $cache = HotKV::AI::SemanticCache->new(client => $rec, ns => 'ns1');
    $cache->get_or_call(
        query => 'q', vector => [1, 0, 0],
        call  => sub { return { response => 'r', model => 'claude-sonnet-5', output_tokens => 40 }; },
    );
    my ($set_call) = calls_named($rec, 'SCACHE.SET');
    # SCACHE.SET ns query_text response val1 val2 val3 [TTL ...] [usage ...]
    my @after_vector = @{$set_call}[7 .. $#$set_call];
    my %opts_h = @after_vector;
    is($opts_h{MODEL}, 'claude-sonnet-5', 'SCACHE.SET carries MODEL when the call reports one');
    is($opts_h{OUTPUT}, 40, 'SCACHE.SET carries OUTPUT');
}

# --- a cache hit never calls the block or touches SCACHE.SET ---------------

{
    my $rec   = RecordingClient->new(reply => ['cached', '0.95']);
    my $cache = HotKV::AI::SemanticCache->new(client => $rec, ns => 'ns1');
    my $calls = 0;
    my $r = $cache->get_or_call(
        query => 'q', vector => [1, 0, 0], call => sub { $calls++; return 'SHOULD NOT RUN'; },
    );
    is($r->{cached}, 1, 'a hit is reported');
    is($r->{response}, 'cached', 'the cached response is returned');
    is($r->{similarity}, '0.95', 'the similarity is returned');
    is($calls, 0, 'the call block never runs on a hit');
    ok(!calls_named($rec, 'SCACHE.SET'), 'no SCACHE.SET on a hit');
}

done_testing();
