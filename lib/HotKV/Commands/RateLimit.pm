# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::RateLimit;

use strict;
use warnings;

use HotKV::Protocol;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::RateLimit - RATELIMIT.* named rate limiters

Needs a server license that includes the C<rate-limiting> feature.
Distinct from L<HotKV::Commands::Gcra> (C<GCRA.*>). Reachable as
C<< $client->ratelimit >>.

=head2 create($name, $limit, $window_ms, \%opts)

C<RATELIMIT.CREATE name limit window_ms [ALGO
sliding_window|token_bucket|leaky_bucket] [REFILL rate] [DRAIN rate]> ->
C<OK>. opts: C<algo>, C<refill>, C<drain>.

=head2 check($name, $key, \%opts)

C<RATELIMIT.CHECK name key [COST n]> -> arrayref of 5 integers
C<[allowed, remaining, retry_after_ms, limit, current]>. Mutating: advances
limiter state. opts: C<cost> (default 1 server side).

=head2 peek($name, $key)

C<RATELIMIT.PEEK name key> -> same shape as C<check> above, non-mutating.

=head2 reset($name, $key)

C<RATELIMIT.RESET name key> -> C<OK>.

=head2 stats($name)

C<RATELIMIT.STATS name> -> flat array of 7 pairs: name, algo, limit,
window_ms, unique_keys, total_allowed, total_denied.

=head2 drop($name)

C<RATELIMIT.DROP name> -> C<OK>.

=head2 list

C<RATELIMIT.LIST> -> arrayref of limiter names.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }
sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }

sub create {
    my ($self, $name, $limit, $window_ms, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('RATELIMIT.CREATE', $name, $limit, $window_ms);
    push @args, 'ALGO', $opts->{algo} if defined $opts->{algo};
    push @args, 'REFILL', HotKV::Protocol::format_number($opts->{refill}) if defined $opts->{refill};
    push @args, 'DRAIN', HotKV::Protocol::format_number($opts->{drain}) if defined $opts->{drain};
    return $self->{ex}->_call(@args);
}

sub check {
    my ($self, $name, $key, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('RATELIMIT.CHECK', $name, $key);
    push @args, 'COST', HotKV::Protocol::format_number($opts->{cost}) if defined $opts->{cost};
    return $self->{ex}->_call(@args);
}

sub peek  { my ($self, $name, $key) = @_; return $self->{ex}->_call('RATELIMIT.PEEK', $name, $key); }
sub reset { my ($self, $name, $key) = @_; return $self->{ex}->_call('RATELIMIT.RESET', $name, $key); }
sub stats { my ($self, $name) = @_; return $self->{ex}->_call('RATELIMIT.STATS', $name); }
sub drop  { my ($self, $name) = @_; return $self->{ex}->_call('RATELIMIT.DROP', $name); }
sub list  { my ($self) = @_; return $self->{ex}->_call('RATELIMIT.LIST'); }

1;
