# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::Keyed;

use strict;
use warnings;

use HotKV::Commands::Support;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::Keyed - Shared implementation for the four keyed caches

=head1 DESCRIPTION

Internal base class, not part of the public API. C<TOOL.CACHE.*>,
C<NCACHE.*>, C<GUARD.*> and C<RERANK.*> are the same engine
under four prefixes; L<HotKV::Commands::ToolCache>,
L<HotKV::Commands::NegativeCache>, L<HotKV::Commands::GuardCache> and
L<HotKV::Commands::RerankCache> are thin subclasses that only set
C<_prefix>.

=head2 create($ns, \%opts)

C<E<lt>PREFIXE<gt>.CREATE ns [MAX_ENTRIES n] [TTL seconds]> -> C<OK>.

=head2 set($ns, $key, $value, \%opts)

C<E<lt>PREFIXE<gt>.SET ns key value [TTL seconds] [META json] [usage
group]> -> C<OK>. opts: C<ttl>, C<meta>, C<usage> (a
L<HotKV::TokenUsage>: records the original, uncached call's token usage
so a later hit attributes it, and its cost once the model is priced, to
C<stats>'s C<usage_saved_*> counters).

=head2 get($ns, $key)

C<E<lt>PREFIXE<gt>.GET ns key> -> the value, or C<undef> on miss.

=head2 del($ns, $key)

C<E<lt>PREFIXE<gt>.DEL ns key> -> 1/0.

=head2 stats($ns)

C<E<lt>PREFIXE<gt>.STATS ns> -> hashref, parsed by field name from either
RESP2's flat array of 11 pairs or RESP3's native map: C<entries>,
C<hits>, C<misses>, C<evictions>, C<memory_bytes>,
C<usage_saved_requests>, C<usage_saved_input_tokens>,
C<usage_saved_output_tokens>, C<usage_saved_cache_read_tokens>,
C<usage_saved_cache_write_tokens>, C<usage_saved_cost_usd>.

=head2 flush($ns)

C<E<lt>PREFIXE<gt>.FLUSH ns> -> integer, entries flushed.

=head2 drop($ns)

C<E<lt>PREFIXE<gt>.DROP ns> -> 1/0.

=head2 list

C<E<lt>PREFIXE<gt>.LIST> -> arrayref of namespace names.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }

sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }

sub create {
    my $self = shift;
    my $ns   = shift;
    my $opts = _opts(\@_);
    my @args = ($self->_prefix . '.CREATE', $ns);
    push @args, 'MAX_ENTRIES', $opts->{max_entries} if defined $opts->{max_entries};
    push @args, 'TTL', $opts->{ttl} if defined $opts->{ttl};
    return $self->{ex}->_call(@args);
}

sub set {
    my $self = shift;
    my ($ns, $key, $val) = (shift, shift, shift);
    my $opts = _opts(\@_);
    my @args = ($self->_prefix . '.SET', $ns, $key, $val);
    push @args, 'TTL', $opts->{ttl} if defined $opts->{ttl};
    push @args, 'META', $opts->{meta} if defined $opts->{meta};
    push @args, $opts->{usage}->wire_args if $opts->{usage};
    return $self->{ex}->_call(@args);
}

sub get   { my ($self, $ns, $key) = @_; return $self->{ex}->_call($self->_prefix . '.GET', $ns, $key); }
sub del   { my ($self, $ns, $key) = @_; return $self->{ex}->_call($self->_prefix . '.DEL', $ns, $key); }

sub stats {
    my ($self, $ns) = @_;
    my $r = $self->{ex}->_call($self->_prefix . '.STATS', $ns);
    return $r if $self->{ex}->_is_deferred($r);
    return HotKV::Commands::Support::pairs_to_h($r, float_keys => ['usage_saved_cost_usd']);
}
sub flush { my ($self, $ns) = @_; return $self->{ex}->_call($self->_prefix . '.FLUSH', $ns); }
sub drop  { my ($self, $ns) = @_; return $self->{ex}->_call($self->_prefix . '.DROP', $ns); }
sub list  { my ($self) = @_; return $self->{ex}->_call($self->_prefix . '.LIST'); }

1;
