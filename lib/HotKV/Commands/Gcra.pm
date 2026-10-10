# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::Gcra;

use strict;
use warnings;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::Gcra - GCRA.* generic cell rate limiter primitive (core)

Distinct from L<HotKV::Commands::RateLimit> (C<RATELIMIT.*>). Reachable as
C<< $client->gcra >>.

=head2 limit($key, $period_ms, $burst, $count = 1)

C<GCRA.LIMIT key period_ms burst [count]> -> arrayref of 5 integers:
C<[denied, limit, remaining, retry_after_ms, reset_after_ms]> (C<denied> is
0 = allowed, 1 = denied; C<retry_after_ms> is -1 when allowed).

=head2 reset(@keys)

C<GCRA.RESET key [key ...]> -> integer, number of keys that had state and
were reset.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }

sub limit {
    my ($self, $key, $period_ms, $burst, $count) = @_;
    my @args = ('GCRA.LIMIT', $key, $period_ms, $burst);
    push @args, $count if defined $count;
    return $self->{ex}->_call(@args);
}

sub reset { my $self = shift; return $self->{ex}->_call('GCRA.RESET', @_); }

1;
