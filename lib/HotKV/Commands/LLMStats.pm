# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::LLMStats;

use strict;
use warnings;

use HotKV::Protocol;

use HotKV::Commands::Support;
use HotKV::LLMPrice;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::LLMStats - LLMSTATS.* usage/cost accounting

Needs a server license that includes the C<llm-stats> feature. Reachable
as C<< $client->llmstats >>.

=head2 bucket($name)

C<LLMSTATS.BUCKET name> -> C<OK>. Idempotent create.

=head2 record($bucket, $input_tokens, $output_tokens, $cached_tokens, $cost_usd, $latency_ms, \%opts)

C<LLMSTATS.RECORD bucket input_tokens output_tokens cached_tokens cost_usd
latency_ms [ERROR 0|1] [MODEL model] [CACHEWRITE5M n] [CACHEWRITE1H n]>
-> C<OK>. C<$cached_tokens> is cache-READ tokens. opts: C<error> (0/1),
C<model> (with C<model>, C<$cost_usd> is ignored by the server, i.e. pass
C<0>: the cost is computed from the C<LLMSTATS.PRICE> table instead; an
unpriced model still records tokens, costs 0 and counts toward
C<unpriced_requests>; for OpenAI, pass C<prompt_tokens - cached_tokens>
as C<$input_tokens>, since OpenAI reports cache hits as part of
C<prompt_tokens>, unlike Anthropic), C<cache_write_5m_tokens>,
C<cache_write_1h_tokens>.

=head2 get($bucket)

C<LLMSTATS.GET bucket> -> hashref, parsed by field name from either
RESP2's flat array of 13 pairs or RESP3's native map: C<requests>,
C<errors>, C<input_tokens>, C<output_tokens>, C<cached_tokens>,
C<cost_usd>, C<avg_latency_ms>, C<requests_1m>, C<tokens_1m>,
C<cost_usd_1m>, C<cache_write_5m_tokens>, C<cache_write_1h_tokens>,
C<unpriced_requests>.

=head2 reset($bucket) / drop($bucket)

C<LLMSTATS.RESET bucket> / C<LLMSTATS.DROP bucket> -> 1/0.

=head2 list

C<LLMSTATS.LIST> -> arrayref of bucket names.

=head2 price_set($model, $input_usd_per_mtok, $output_usd_per_mtok, \%opts)

C<LLMSTATS.PRICE SET model INPUT usd_per_mtok OUTPUT usd_per_mtok
[CACHEREAD usd_per_mtok] [CACHEWRITE5M usd_per_mtok] [CACHEWRITE1H
usd_per_mtok]> -> C<OK>. Sets a custom USD-per-1,000,000-token price for
C<$model>. Prices may be a plain number or a decimal string; formatted
with L<HotKV::LLMPrice/format_price>. opts: C<cache_read_usd_per_mtok>,
C<cache_write_5m_usd_per_mtok>, C<cache_write_1h_usd_per_mtok> (each
defaults, server side, to 0.1x/1.25x/2x C<$input_usd_per_mtok> when
omitted).

=head2 price_get($model)

C<LLMSTATS.PRICE GET model> -> C<$model>'s L<HotKV::LLMPrice> table
entry. An unknown model comes back with C<source> C<"unpriced"> and
every price C<0>, not an error.

=head2 price_list

C<LLMSTATS.PRICE LIST> -> arrayref of every known model's
L<HotKV::LLMPrice> table entry (built in and custom).

=head2 price_del($model)

C<LLMSTATS.PRICE DEL model> -> 1 if a custom override was removed, else 0
(the model then falls back to its built-in price, if any).

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }
sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }

sub bucket { my ($self, $name) = @_; return $self->{ex}->_call('LLMSTATS.BUCKET', $name); }

sub record {
    my $self = shift;
    my ($bucket, $in_tok, $out_tok, $cached_tok, $cost_usd, $latency_ms) =
        (shift, shift, shift, shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ('LLMSTATS.RECORD', $bucket, $in_tok, $out_tok, $cached_tok,
        HotKV::Protocol::format_number($cost_usd), HotKV::Protocol::format_number($latency_ms));
    push @args, 'ERROR', ($opts->{error} ? 1 : 0) if defined $opts->{error};
    push @args, 'MODEL', $opts->{model} if defined $opts->{model};
    push @args, 'CACHEWRITE5M', $opts->{cache_write_5m_tokens} if defined $opts->{cache_write_5m_tokens};
    push @args, 'CACHEWRITE1H', $opts->{cache_write_1h_tokens} if defined $opts->{cache_write_1h_tokens};
    return $self->{ex}->_call(@args);
}

sub get {
    my ($self, $bucket) = @_;
    my $r = $self->{ex}->_call('LLMSTATS.GET', $bucket);
    return $r if $self->{ex}->_is_deferred($r);
    return HotKV::Commands::Support::pairs_to_h($r, float_keys => ['cost_usd', 'avg_latency_ms', 'cost_usd_1m']);
}

sub reset { my ($self, $bucket) = @_; return $self->{ex}->_call('LLMSTATS.RESET', $bucket); }
sub drop  { my ($self, $bucket) = @_; return $self->{ex}->_call('LLMSTATS.DROP', $bucket); }
sub list  { my ($self) = @_; return $self->{ex}->_call('LLMSTATS.LIST'); }

sub price_set {
    my $self = shift;
    my ($model, $input, $output) = (shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = (
        'LLMSTATS.PRICE', 'SET', $model,
        'INPUT',  HotKV::LLMPrice->format_price($input),
        'OUTPUT', HotKV::LLMPrice->format_price($output),
    );
    push @args, 'CACHEREAD', HotKV::LLMPrice->format_price($opts->{cache_read_usd_per_mtok})
        if defined $opts->{cache_read_usd_per_mtok};
    push @args, 'CACHEWRITE5M', HotKV::LLMPrice->format_price($opts->{cache_write_5m_usd_per_mtok})
        if defined $opts->{cache_write_5m_usd_per_mtok};
    push @args, 'CACHEWRITE1H', HotKV::LLMPrice->format_price($opts->{cache_write_1h_usd_per_mtok})
        if defined $opts->{cache_write_1h_usd_per_mtok};
    return $self->{ex}->_call(@args);
}

sub price_get {
    my ($self, $model) = @_;
    my $r = $self->{ex}->_call('LLMSTATS.PRICE', 'GET', $model);
    return $r if $self->{ex}->_is_deferred($r);
    return HotKV::LLMPrice->from_fields(
        HotKV::Commands::Support::pairs_to_h($r, float_keys => [@HotKV::LLMPrice::FLOAT_FIELDS])
    );
}

sub price_list {
    my ($self) = @_;
    my $r = $self->{ex}->_call('LLMSTATS.PRICE', 'LIST');
    return $r if $self->{ex}->_is_deferred($r);
    return [
        map {
            HotKV::LLMPrice->from_fields(
                HotKV::Commands::Support::pairs_to_h($_, float_keys => [@HotKV::LLMPrice::FLOAT_FIELDS])
            )
        } @$r
    ];
}

sub price_del { my ($self, $model) = @_; return $self->{ex}->_call('LLMSTATS.PRICE', 'DEL', $model); }

1;
