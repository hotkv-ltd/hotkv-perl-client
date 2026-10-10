# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::Bloom;

use strict;
use warnings;

use HotKV::Protocol;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::Bloom - BF.* Bloom filter commands (core, no license needed)

=head1 SYNOPSIS

  $kv->bf->reserve('seen', 0.01, 10_000);
  $kv->bf->add('seen', 'alice');
  $kv->bf->exists('seen', 'alice');     # 1
  my $info = $kv->bf->info('seen');     # hashref

=head1 METHODS

Reachable as C<< $client->bf >>.

=head2 reserve($key, $error_rate, $capacity, \%opts)

C<BF.RESERVE key error_rate capacity [EXPANSION n] [NONSCALING]>. opts:
C<expansion>, C<nonscaling>.

=head2 add($key, $item) / madd($key, @items)

C<BF.ADD> (1 if new, 0 if probably present) and C<BF.MADD> (arrayref).

=head2 insert($key, \@items, \%opts)

C<BF.INSERT key [CAPACITY n] [ERROR e] [EXPANSION n] [NOCREATE]
[NONSCALING] ITEMS item ...>. opts: C<capacity>, C<error>, C<expansion>,
C<nocreate>, C<nonscaling>.

=head2 exists($key, $item) / mexists($key, @items)

C<BF.EXISTS> and C<BF.MEXISTS>.

=head2 card($key)

C<BF.CARD>: items added.

=head2 info($key, [$field])

With no C<$field> a hashref keyed by the server's field names (C<Capacity>,
C<Size>, C<Number of filters>, C<Number of items inserted>, C<Expansion
rate>); with one of C<CAPACITY>, C<SIZE>, C<FILTERS>, C<ITEMS>, C<EXPANSION>
that single value.

=head2 scandump($key, $iterator) / loadchunk($key, $iterator, $data)

C<BF.SCANDUMP> returns C<[next_iterator, chunk]>; C<BF.LOADCHUNK> restores
one chunk.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }
sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }

sub reserve {
    my ($self, $key, $error_rate, $capacity, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('BF.RESERVE', $key, HotKV::Protocol::format_number($error_rate), $capacity);
    push @args, 'EXPANSION', $opts->{expansion} if defined $opts->{expansion};
    push @args, 'NONSCALING' if $opts->{nonscaling};
    return $self->{ex}->_call(@args);
}

sub add     { my ($self, $key, $item) = @_; return $self->{ex}->_call('BF.ADD', $key, $item); }
sub madd    { my $self = shift; my $key = shift; return $self->{ex}->_call('BF.MADD', $key, @_); }
sub exists  { my ($self, $key, $item) = @_; return $self->{ex}->_call('BF.EXISTS', $key, $item); }
sub mexists { my $self = shift; my $key = shift; return $self->{ex}->_call('BF.MEXISTS', $key, @_); }
sub card    { my ($self, $key) = @_; return $self->{ex}->_call('BF.CARD', $key); }

sub insert {
    my ($self, $key, $items, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('BF.INSERT', $key);
    push @args, 'CAPACITY',  $opts->{capacity}  if defined $opts->{capacity};
    push @args, 'ERROR',     HotKV::Protocol::format_number($opts->{error}) if defined $opts->{error};
    push @args, 'EXPANSION', $opts->{expansion} if defined $opts->{expansion};
    push @args, 'NOCREATE'   if $opts->{nocreate};
    push @args, 'NONSCALING' if $opts->{nonscaling};
    push @args, 'ITEMS', @$items;
    return $self->{ex}->_call(@args);
}

sub info {
    my ($self, $key, $field) = @_;
    my @args = ('BF.INFO', $key);
    push @args, uc($field) if defined $field;
    my $r = $self->{ex}->_call(@args);
    return $r if $self->{ex}->_is_deferred($r);
    if (defined $field) {
        # The server answers a single field as a one entry map over RESP3
        # and as a one element array over RESP2: return the bare value
        # either way.
        if (ref($r) eq 'HASH') {
            my @values = CORE::values %$r;
            return @values == 1 ? $values[0] : $r;
        }
        return (ref($r) eq 'ARRAY' && @$r == 1) ? $r->[0] : $r;
    }
    return HotKV::Commands::_to_hash($r);
}

sub scandump  { my ($self, $key, $it) = @_; return $self->{ex}->_call('BF.SCANDUMP', $key, $it); }
sub loadchunk { my ($self, $key, $it, $data) = @_; return $self->{ex}->_call('BF.LOADCHUNK', $key, $it, $data); }

1;

=head1 SUPPORT

support@hotkv.com

=head1 LICENSE

Apache License, Version 2.0; see the LICENSE file.

=cut
