# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

use strict;
use warnings;
use Test::More;

my @modules = qw(
    HotKV
    HotKV::AI::PromptCache
    HotKV::AI::SemanticCache
    HotKV::CRC16
    HotKV::Cluster
    HotKV::Commands
    HotKV::Commands::AgentMemory
    HotKV::Commands::EmbedDedup
    HotKV::Commands::FeatureStore
    HotKV::Commands::Gcra
    HotKV::Commands::GuardCache
    HotKV::Commands::Keyed
    HotKV::Commands::LLMBudget
    HotKV::Commands::LLMStats
    HotKV::Commands::LLMBudget
    HotKV::Commands::LLMStats
    HotKV::Commands::NegativeCache
    HotKV::Commands::Observe
    HotKV::Commands::Prompt
    HotKV::Commands::PromptCache
    HotKV::Commands::Rag
    HotKV::Commands::RateLimit
    HotKV::Commands::RerankCache
    HotKV::Commands::SemanticCache
    HotKV::Commands::Support
    HotKV::Commands::Tag
    HotKV::Commands::TimeSeries
    HotKV::Commands::ToolCache
    HotKV::Commands::Vsim
    HotKV::Connection
    HotKV::Error
    HotKV::LLMPrice
    HotKV::Pipeline
    HotKV::Pool
    HotKV::Protocol
    HotKV::PubSub
    HotKV::TokenUsage
    HotKV::Transaction
);

plan tests => scalar(@modules) + 1;

require_ok($_) for @modules;

ok(HotKV->can('new'), 'HotKV->new is defined');
