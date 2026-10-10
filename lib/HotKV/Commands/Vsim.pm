# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::Vsim;

use strict;
use warnings;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::Vsim - VSIM.* vector similarity index

C<createindex>/C<dropindex>/C<set>/C<get>/C<del>/C<search>/C<info> are core
(no license needed). C<save>/C<load>/C<list_snapshots>/C<drop_snapshot>
(persistence) need a server license that includes the C<vsim-persist> feature. Reachable
as C<< $client->vsim >>. Vectors are always plain arrayrefs of numbers.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }
sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }

=head2 createindex($name, $dims, \%opts)

C<VSIM.CREATEINDEX name dims [METRIC cosine|l2|ip] [M n] [EF_CONSTRUCTION n]
[EF_SEARCH n]> -> C<OK>. opts: C<metric>, C<m>, C<ef_construction>,
C<ef_search>.

=cut

sub createindex {
    my ($self, $name, $dims, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('VSIM.CREATEINDEX', $name, $dims);
    push @args, 'METRIC', $opts->{metric} if defined $opts->{metric};
    push @args, 'M', $opts->{m} if defined $opts->{m};
    push @args, 'EF_CONSTRUCTION', $opts->{ef_construction} if defined $opts->{ef_construction};
    push @args, 'EF_SEARCH', $opts->{ef_search} if defined $opts->{ef_search};
    return $self->{ex}->_call(@args);
}

=head2 dropindex($name)

C<VSIM.DROPINDEX name> -> C<OK>.

=head2 set($index, $key, \@vector)

C<VSIM.SET index key val1 ... valN> -> 1 (new) / 0 (replaced existing).

=head2 get($index, $key)

C<VSIM.GET index key> -> arrayref of floats (as strings), or C<undef>.

=head2 del($index, $key)

C<VSIM.DEL index key> -> 1/0.

=head2 search($index, $k, \@vector, \%opts)

C<VSIM.SEARCH index k val1 ... valN [FILTER tag ...] [EF ef]> -> arrayref
alternating C<key, distance>. opts: C<filter> (arrayref of tags), C<ef>.

=head2 info([$index])

With no C<$index>: C<VSIM.INFO> -> arrayref of all index names. With
C<$index>: arrayref of 7 flat pairs C<name, dimensions, metric, vectors, M,
ef_construction, ef_search>.

=cut

sub dropindex { my ($self, $name) = @_; return $self->{ex}->_call('VSIM.DROPINDEX', $name); }
sub set        { my ($self, $index, $key, $vec) = @_; return $self->{ex}->_call('VSIM.SET', $index, $key, @$vec); }
sub get        { my ($self, $index, $key) = @_; return $self->{ex}->_call('VSIM.GET', $index, $key); }
sub del        { my ($self, $index, $key) = @_; return $self->{ex}->_call('VSIM.DEL', $index, $key); }

sub search {
    my ($self, $index, $k, $vec, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('VSIM.SEARCH', $index, $k, @$vec);
    push @args, 'FILTER', @{ $opts->{filter} } if $opts->{filter} && @{ $opts->{filter} };
    push @args, 'EF', $opts->{ef} if defined $opts->{ef};
    return $self->{ex}->_call(@args);
}

sub info {
    my ($self, $index) = @_;
    my @args = ('VSIM.INFO');
    push @args, $index if defined $index;
    return $self->{ex}->_call(@args);
}

=head2 save($snapshot_name, $blob)

C<VSIM.SAVE snapshot_name blob> -> integer bytes written. Requires
C<vsim-persist>.

=head2 load($snapshot_name)

C<VSIM.LOAD snapshot_name> -> blob or C<undef>. Requires C<vsim-persist>.

=head2 list_snapshots

C<VSIM.LIST> -> arrayref of snapshot names. Requires C<vsim-persist>.

=head2 drop_snapshot($snapshot_name)

C<VSIM.DROP snapshot_name> -> 1/0. Requires C<vsim-persist>.

=cut

sub save            { my ($self, $name, $blob) = @_; return $self->{ex}->_call('VSIM.SAVE', $name, $blob); }
sub load             { my ($self, $name) = @_; return $self->{ex}->_call('VSIM.LOAD', $name); }
sub list_snapshots   { my ($self) = @_; return $self->{ex}->_call('VSIM.LIST'); }
sub drop_snapshot    { my ($self, $name) = @_; return $self->{ex}->_call('VSIM.DROP', $name); }

1;
