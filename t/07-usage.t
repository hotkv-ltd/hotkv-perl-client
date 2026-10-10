# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# HotKV::TokenUsage: the shared usage group's wire encoding. No server.

use strict;
use warnings;
use Test::More;

use HotKV::TokenUsage;

# --- model is required ------------------------------------------------------

{
    my $err = eval { HotKV::TokenUsage->new(); 1 } ? undef : $@;
    ok($err, 'new without model raises');
}

# --- model alone: just MODEL, every zero count left off the wire ----------

{
    my $u = HotKV::TokenUsage->new(model => 'claude-sonnet-5');
    is($u->model, 'claude-sonnet-5', 'model accessor');
    is($u->input_tokens, 0, 'input_tokens defaults to 0');
    is_deeply([$u->wire_args], ['MODEL', 'claude-sonnet-5'], 'wire_args with no counts is just MODEL');
}

# --- every count present, in the documented order --------------------------

{
    my $u = HotKV::TokenUsage->new(
        model                 => 'gpt-6-sol',
        input_tokens          => 120,
        output_tokens         => 40,
        cache_read_tokens     => 10,
        cache_write_5m_tokens => 5,
        cache_write_1h_tokens => 2,
    );
    is_deeply(
        [$u->wire_args],
        [
            'MODEL', 'gpt-6-sol', 'INPUT', 120, 'OUTPUT', 40,
            'CACHEREAD', 10, 'CACHEWRITE5M', 5, 'CACHEWRITE1H', 2,
        ],
        'wire_args includes every non-zero count, in order'
    );
}

# --- a single non-zero count includes only that one pair -------------------

{
    my $u = HotKV::TokenUsage->new(model => 'm', cache_write_1h_tokens => 7);
    is_deeply([$u->wire_args], ['MODEL', 'm', 'CACHEWRITE1H', 7], 'only the non-zero count is sent');
}

{
    my $u = HotKV::TokenUsage->new(model => 'm', output_tokens => 0, input_tokens => 5);
    is_deeply([$u->wire_args], ['MODEL', 'm', 'INPUT', 5], 'an explicit zero count is still omitted');
}

done_testing();
