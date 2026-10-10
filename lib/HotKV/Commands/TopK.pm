# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::TopK;

use strict;
use warnings;

use HotKV::Protocol;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::TopK - TOPK.* Top-K commands (core, no license needed)

=head1 SYNOPSIS

  $kv->topk->reserve('trending', 3);
  $kv->topk->add('trending', 'a', 'b', 'a');
  my $list = $kv->topk->list('trending', { withcount => 1 });   # ['a', 2, 'b', 1]

=head1 METHODS

Reachable as C<< $client->topk >>.

=head2 reserve($key, $k, \%opts)

C<TOPK.RESERVE key k [width depth decay]>. opts: C<width>, C<depth>,
C<decay> (all three must be given together).

=head2 add($key, @items)

C<TOPK.ADD>: arrayref, one entry per item (the item pushed out, or C<undef>).

=head2 incrby($key, $item, $increment, ...)

C<TOPK.INCRBY>.

=head2 query($key, @items) / count($key, @items)

C<TOPK.QUERY> (0/1 per item) and C<TOPK.COUNT>.

=head2 list($key, \%opts)

C<TOPK.LIST key [WITHCOUNT]>. opts: C<withcount>.

=head2 info($key)

C<TOPK.INFO>: hashref with C<k>, C<width>, C<depth>, C<decay>.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }
sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }

sub reserve {
    my ($self, $key, $k, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('TOPK.RESERVE', $key, $k);
    if (defined $opts->{width} || defined $opts->{depth} || defined $opts->{decay}) {
        push @args, $opts->{width}, $opts->{depth}, HotKV::Protocol::format_number($opts->{decay});
    }
    return $self->{ex}->_call(@args);
}

sub add    { my $self = shift; my $key = shift; return $self->{ex}->_call('TOPK.ADD', $key, @_); }
sub incrby { my $self = shift; my $key = shift; return $self->{ex}->_call('TOPK.INCRBY', $key, @_); }
sub query  { my $self = shift; my $key = shift; return $self->{ex}->_call('TOPK.QUERY', $key, @_); }
sub count  { my $self = shift; my $key = shift; return $self->{ex}->_call('TOPK.COUNT', $key, @_); }

sub list {
    my ($self, $key, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('TOPK.LIST', $key);
    push @args, 'WITHCOUNT' if $opts->{withcount};
    return $self->{ex}->_call(@args);
}

sub info {
    my ($self, $key) = @_;
    my $r = $self->{ex}->_call('TOPK.INFO', $key);
    return $r if $self->{ex}->_is_deferred($r);
    return HotKV::Commands::_to_hash($r);
}

1;

=head1 SUPPORT

support@hotkv.com

=head1 LICENSE

Apache License, Version 2.0; see the LICENSE file.

=cut
