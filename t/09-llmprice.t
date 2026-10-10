# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# HotKV::LLMPrice: LLMSTATS.PRICE field parsing (both RESP2 flat array and
# RESP3 map reply shapes) and format_price. No server.

use strict;
use warnings;
use Test::More;

use HotKV::Commands::Support;
use HotKV::LLMPrice;

my @FLAT = (
    model                       => 'claude-sonnet-5',
    source                      => 'custom',
    priced                      => 1,
    retired                     => 0,
    input_usd_per_mtok          => '3.000000',
    output_usd_per_mtok         => '15.000000',
    cache_read_usd_per_mtok     => '0.300000',
    cache_write_5m_usd_per_mtok => '3.750000',
    cache_write_1h_usd_per_mtok => '6.000000',
);

sub check_custom {
    my ($price, $label) = @_;
    isa_ok($price, 'HotKV::LLMPrice', $label);
    is($price->model, 'claude-sonnet-5', "$label model");
    is($price->source, 'custom', "$label source");
    is($price->priced, 1, "$label priced");
    is($price->retired, 0, "$label retired");
    is($price->input_usd_per_mtok, 3, "$label input_usd_per_mtok is numeric");
    is($price->output_usd_per_mtok, 15, "$label output_usd_per_mtok is numeric");
    is($price->cache_write_1h_usd_per_mtok, 6, "$label cache_write_1h_usd_per_mtok is numeric");
}

# --- RESP2 flat array -------------------------------------------------------

{
    my @flat_array = @FLAT;
    my $fields = HotKV::Commands::Support::pairs_to_h(\@flat_array, float_keys => [@HotKV::LLMPrice::FLOAT_FIELDS]);
    check_custom(HotKV::LLMPrice->from_fields($fields), 'flat array');
}

# --- RESP3 native map (a hashref) ------------------------------------------

{
    my %map = @FLAT;
    my $fields = HotKV::Commands::Support::pairs_to_h(\%map, float_keys => [@HotKV::LLMPrice::FLOAT_FIELDS]);
    check_custom(HotKV::LLMPrice->from_fields($fields), 'native map');
}

# --- an unknown model: source unpriced, every price 0, not an error --------

{
    my @unpriced = (
        model => 'no-such-model', source => 'unpriced', priced => 0, retired => 0,
        input_usd_per_mtok => '0.000000', output_usd_per_mtok => '0.000000',
        cache_read_usd_per_mtok => '0.000000', cache_write_5m_usd_per_mtok => '0.000000',
        cache_write_1h_usd_per_mtok => '0.000000',
    );
    my $price = HotKV::LLMPrice->from_fields(
        HotKV::Commands::Support::pairs_to_h(\@unpriced, float_keys => [@HotKV::LLMPrice::FLOAT_FIELDS])
    );
    is($price->source, 'unpriced', 'unknown model source is unpriced');
    is($price->priced, 0, 'unknown model priced is 0');
    is($price->input_usd_per_mtok, 0, 'unknown model input_usd_per_mtok is 0');
}

# --- LIST: an array of entries, each parsed the same way -------------------

{
    my @second = @FLAT;
    my %second_h = @second;
    $second_h{model} = 'gpt-6-sol';
    my @second_flat = %second_h;
    my @entries = ([@FLAT], \@second_flat); # one RESP2 flat array, one likewise
    my @prices = map {
        HotKV::LLMPrice->from_fields(
            HotKV::Commands::Support::pairs_to_h($_, float_keys => [@HotKV::LLMPrice::FLOAT_FIELDS])
        )
    } @entries;
    is(scalar(@prices), 2, 'two entries parsed');
    isa_ok($_, 'HotKV::LLMPrice') for @prices;
    is_deeply([sort { $a cmp $b } map { $_->model } @prices], ['claude-sonnet-5', 'gpt-6-sol'], 'each entry keeps its own model');
}

# --- from_fields defaults and ignores unknown keys -------------------------

{
    my $price = HotKV::LLMPrice->from_fields({ model => 'x', extra => 'ignored' });
    is($price->model, 'x', 'known field kept');
    is($price->source, '', 'missing source defaults to empty string');
    is($price->priced, 0, 'missing priced defaults to 0');
    is($price->input_usd_per_mtok, 0, 'missing price defaults to 0');
}

# --- format_price ------------------------------------------------------

is(HotKV::LLMPrice->format_price('3'), '3', 'an already-valid integer string passes through');
is(HotKV::LLMPrice->format_price('0.30'), '0.30', 'an already-valid decimal string passes through');
is(HotKV::LLMPrice->format_price('15.000001'), '15.000001', 'six fractional digits pass through');
is(HotKV::LLMPrice->format_price(3), '3', 'a plain integer formats with no trailing zeros or dot');
is(HotKV::LLMPrice->format_price(0.3), '0.3', 'a plain float formats without a trailing zero run');
is(HotKV::LLMPrice->format_price(0), '0', 'zero formats as a bare 0, not 0.000000');
is(HotKV::LLMPrice->format_price(0.1 + 0.2), '0.3', 'a float artifact is rounded to 6 decimals and trimmed');

done_testing();
