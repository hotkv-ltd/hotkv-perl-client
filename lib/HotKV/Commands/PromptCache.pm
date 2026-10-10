# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::PromptCache;

use strict;
use warnings;

use HotKV::Commands::Support;
use HotKV::Protocol;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::PromptCache - PCACHE.* raw command wrapper

Needs a server license that includes the C<prompt-cache> feature. Reachable
as C<< $client->pcache >>. For the higher level, deterministic-key caching
helper see L<HotKV::AI::PromptCache>.

=head2 create($ns, \%opts)

C<PCACHE.CREATE ns [MAX_ENTRIES n] [TTL seconds] [COST_PER_HIT usd]> ->
C<OK>.

=head2 set($ns, $prompt, $response, \%opts)

C<PCACHE.SET ns prompt response [TTL seconds] [META json] [usage group]>
-> C<OK>. opts: C<ttl>, C<meta>, C<usage> (a L<HotKV::TokenUsage>: records
the original, uncached call's token usage so a later hit attributes it,
and its cost once the model is priced, to C<stats>'s C<usage_saved_*>
counters).

=head2 get($ns, $prompt)

C<PCACHE.GET ns prompt> -> the response, or C<undef> on miss.

=head2 getex($ns, $prompt)

C<PCACHE.GETEX ns prompt> -> arrayref C<[response, metadata, hit_count]> on
hit, else C<undef>.

=head2 del($ns, $prompt)

C<PCACHE.DEL ns prompt> -> 1/0.

=head2 stats($ns)

C<PCACHE.STATS ns> -> hashref, parsed by field name from either RESP2's
flat array of 16 pairs or RESP3's native map: C<entries>, C<hits>,
C<misses>, C<evictions>, C<memory_bytes>, C<hit_rate>, C<p50_ns>,
C<p95_ns>, C<p99_ns>, C<cost_saved_usd>, C<usage_saved_requests>,
C<usage_saved_input_tokens>, C<usage_saved_output_tokens>,
C<usage_saved_cache_read_tokens>, C<usage_saved_cache_write_tokens>,
C<usage_saved_cost_usd>.

=head2 flush($ns)

C<PCACHE.FLUSH ns> -> integer, entries flushed.

=head2 drop($ns)

C<PCACHE.DROP ns> -> 1/0.

=head2 list

C<PCACHE.LIST> -> arrayref of namespace names.

=head2 config_set($ns, $key, $value)

C<PCACHE.CONFIG ns SET E<lt>MAX_ENTRIES|TTL|COST_PER_HITE<gt> value> ->
C<OK>. C<$key> is one of C<MAX_ENTRIES>, C<TTL>, C<COST_PER_HIT>
(case-insensitive).

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }
sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }

sub create {
    my ($self, $ns, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('PCACHE.CREATE', $ns);
    push @args, 'MAX_ENTRIES', $opts->{max_entries} if defined $opts->{max_entries};
    push @args, 'TTL', $opts->{ttl} if defined $opts->{ttl};
    push @args, 'COST_PER_HIT', HotKV::Protocol::format_number($opts->{cost_per_hit}) if defined $opts->{cost_per_hit};
    return $self->{ex}->_call(@args);
}

sub set {
    my ($self, $ns, $prompt, $response, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('PCACHE.SET', $ns, $prompt, $response);
    push @args, 'TTL', $opts->{ttl} if defined $opts->{ttl};
    push @args, 'META', $opts->{meta} if defined $opts->{meta};
    push @args, $opts->{usage}->wire_args if $opts->{usage};
    return $self->{ex}->_call(@args);
}

sub get   { my ($self, $ns, $prompt) = @_; return $self->{ex}->_call('PCACHE.GET', $ns, $prompt); }
sub getex { my ($self, $ns, $prompt) = @_; return $self->{ex}->_call('PCACHE.GETEX', $ns, $prompt); }
sub del   { my ($self, $ns, $prompt) = @_; return $self->{ex}->_call('PCACHE.DEL', $ns, $prompt); }

sub stats {
    my ($self, $ns) = @_;
    my $r = $self->{ex}->_call('PCACHE.STATS', $ns);
    return $r if $self->{ex}->_is_deferred($r);
    return HotKV::Commands::Support::pairs_to_h(
        $r, float_keys => ['hit_rate', 'cost_saved_usd', 'usage_saved_cost_usd']
    );
}
sub flush { my ($self, $ns) = @_; return $self->{ex}->_call('PCACHE.FLUSH', $ns); }
sub drop  { my ($self, $ns) = @_; return $self->{ex}->_call('PCACHE.DROP', $ns); }
sub list  { my ($self) = @_; return $self->{ex}->_call('PCACHE.LIST'); }

sub config_set {
    my ($self, $ns, $key, $value) = @_;
    return $self->{ex}->_call('PCACHE.CONFIG', $ns, 'SET', uc($key),
        uc($key) eq 'COST_PER_HIT' ? HotKV::Protocol::format_number($value) : $value);
}

1;
