# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::SemanticCache;

use strict;
use warnings;

use HotKV::Commands::Support;
use HotKV::Protocol;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::SemanticCache - SCACHE.* raw command wrapper

Needs a server license that includes the C<semantic-cache> feature.
Reachable as C<< $client->scache >>. For the higher level,
provider-neutral caching helper see L<HotKV::AI::SemanticCache>.

=head2 create($ns, $dims, \%opts)

C<SCACHE.CREATE ns dims [METRIC cosine|l2|ip] [THRESHOLD 0.0-1.0] [TTL
seconds]> -> C<OK>. opts: C<metric>, C<threshold>, C<ttl>.

=head2 set($ns, $query_text, $response, \@vector, \%opts)

C<SCACHE.SET ns query_text response val1 ... valN [TTL seconds] [usage
group]> -> C<OK>. opts: C<ttl>, C<usage> (a L<HotKV::TokenUsage>: records
the original, uncached call's token usage so a later hit attributes it,
and its cost once the model is priced, to C<stats>'s C<usage_saved_*>
counters).

=head2 get($ns, \@vector, \%opts)

C<SCACHE.GET ns val1 ... valN [THRESHOLD override]> -> arrayref
C<[response, similarity]> on a hit, else C<undef>. opts: C<threshold>.

=head2 stats($ns)

C<SCACHE.STATS ns> -> hashref, parsed by field name from either RESP2's
flat array of 11 pairs or RESP3's native map: C<entries>, C<hits>,
C<misses>, C<hit_rate>, C<p50_us>, C<usage_saved_requests>,
C<usage_saved_input_tokens>, C<usage_saved_output_tokens>,
C<usage_saved_cache_read_tokens>, C<usage_saved_cache_write_tokens>,
C<usage_saved_cost_usd>.

=head2 flush($ns) / drop($ns)

C<SCACHE.FLUSH ns> / C<SCACHE.DROP ns> -> 1/0 (namespace existed).

=head2 list

C<SCACHE.LIST> -> arrayref of namespace names.

=head2 threshold($ns, $value)

C<SCACHE.THRESHOLD ns value> -> C<OK>.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }
sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }

sub create {
    my ($self, $ns, $dims, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('SCACHE.CREATE', $ns, $dims);
    push @args, 'METRIC', $opts->{metric} if defined $opts->{metric};
    push @args, 'THRESHOLD', HotKV::Protocol::format_number($opts->{threshold}) if defined $opts->{threshold};
    push @args, 'TTL', $opts->{ttl} if defined $opts->{ttl};
    return $self->{ex}->_call(@args);
}

sub set {
    my ($self, $ns, $query_text, $response, $vec, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('SCACHE.SET', $ns, $query_text, $response, map { HotKV::Protocol::format_number($_) } @$vec);
    push @args, 'TTL', $opts->{ttl} if defined $opts->{ttl};
    push @args, $opts->{usage}->wire_args if $opts->{usage};
    return $self->{ex}->_call(@args);
}

sub get {
    my ($self, $ns, $vec, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('SCACHE.GET', $ns, map { HotKV::Protocol::format_number($_) } @$vec);
    push @args, 'THRESHOLD', HotKV::Protocol::format_number($opts->{threshold}) if defined $opts->{threshold};
    return $self->{ex}->_call(@args);
}

sub stats {
    my ($self, $ns) = @_;
    my $r = $self->{ex}->_call('SCACHE.STATS', $ns);
    return $r if $self->{ex}->_is_deferred($r);
    return HotKV::Commands::Support::pairs_to_h($r, float_keys => ['hit_rate', 'usage_saved_cost_usd']);
}
sub flush     { my ($self, $ns) = @_; return $self->{ex}->_call('SCACHE.FLUSH', $ns); }
sub drop      { my ($self, $ns) = @_; return $self->{ex}->_call('SCACHE.DROP', $ns); }
sub list      { my ($self) = @_; return $self->{ex}->_call('SCACHE.LIST'); }
sub threshold { my ($self, $ns, $value) = @_; return $self->{ex}->_call('SCACHE.THRESHOLD', $ns, HotKV::Protocol::format_number($value)); }

1;
