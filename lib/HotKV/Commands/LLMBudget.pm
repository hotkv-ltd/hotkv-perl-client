# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::LLMBudget;

use strict;
use warnings;

use HotKV::Protocol;

use HotKV::Commands::Support;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::LLMBudget - LLMBUDGET.* token/cost budget enforcement

Needs a server license that includes the C<llm-budget> feature. Reachable
as C<< $client->llmbudget >>.

=head2 set($name, $token_limit, $cost_limit_usd, $window_seconds)

C<LLMBUDGET.SET name token_limit cost_limit_usd window_seconds> -> C<OK>.
The server reads the cost limit as exact fixed-point dollars (no sign, no
exponent, at most six decimals), so C<$cost_limit_usd> is rewritten with
L<HotKV::Protocol/format_usd>: C<0.00001> or C<1e-05> go out as
C<0.00001>, and a negative or NaN amount raises an exception.

=head2 consume($name, $tokens, $cost_usd, \%opts)

C<LLMBUDGET.CONSUME name tokens cost_usd [usage group]> -> 1 (allowed) /
0 (rejected). C<$tokens>/C<$cost_usd> default to 0 (so a usage-only call
can omit them entirely). opts: C<usage> (a L<HotKV::TokenUsage>: with it,
C<$tokens>/C<$cost_usd> are ignored by the server (sent as C<0>/C<0>);
the server sums the usage group's counts for the token total and prices
it from the C<LLMSTATS.PRICE> table instead).

=head2 status($name)

C<LLMBUDGET.STATUS name> -> hashref, parsed by field name from either
RESP2's flat array of 9 pairs or RESP3's native map: C<tokens_used>,
C<token_limit>, C<cost_used_usd>, C<cost_limit_usd>, C<window_seconds>,
C<window_remaining>, C<requests_allowed>, C<requests_rejected>,
C<unpriced_requests>.

=head2 reset($name) / drop($name)

C<LLMBUDGET.RESET name> / C<LLMBUDGET.DROP name> -> 1/0.

=head2 list

C<LLMBUDGET.LIST> -> arrayref of budget names.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }
sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }

sub set {
    my ($self, $name, $token_limit, $cost_limit_usd, $window_seconds) = @_;
    return $self->{ex}->_call('LLMBUDGET.SET', $name, $token_limit,
        HotKV::Protocol::format_usd($cost_limit_usd), $window_seconds);
}

sub consume {
    my $self = shift;
    my $name = shift;
    my $opts = _opts(\@_);
    my $tokens   = shift(@_);
    my $cost_usd = shift(@_);
    $tokens   = 0 unless defined $tokens;
    $cost_usd = 0 unless defined $cost_usd;
    my @args = ('LLMBUDGET.CONSUME', $name, $tokens, HotKV::Protocol::format_number($cost_usd));
    push @args, $opts->{usage}->wire_args if $opts->{usage};
    return $self->{ex}->_call(@args);
}

sub status {
    my ($self, $name) = @_;
    my $r = $self->{ex}->_call('LLMBUDGET.STATUS', $name);
    return $r if $self->{ex}->_is_deferred($r);
    return HotKV::Commands::Support::pairs_to_h($r, float_keys => ['cost_used_usd', 'cost_limit_usd']);
}

sub reset   { my ($self, $name) = @_; return $self->{ex}->_call('LLMBUDGET.RESET', $name); }
sub drop    { my ($self, $name) = @_; return $self->{ex}->_call('LLMBUDGET.DROP', $name); }
sub list    { my ($self) = @_; return $self->{ex}->_call('LLMBUDGET.LIST'); }

1;
