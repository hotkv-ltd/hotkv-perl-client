# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::FeatureStore;

use strict;
use warnings;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::FeatureStore - FEATURE.* ML feature store

Needs a server license that includes the C<feature-store> feature.
Reachable as C<< $client->feature >>.

=head2 create($group, $description, \@schema)

C<FEATURE.CREATE group description SCHEMA name1 type1 [name2 type2 ...]>
-> C<OK>. C<@schema> is a flat arrayref of name/type pairs; C<typeN> is one
of C<int64>, C<double> (alias C<float>), C<string>, C<int_array>,
C<double_array> (alias C<float_array>), case-insensitive.

=head2 set($group, $entity, @feature_value_pairs)

C<FEATURE.SET group entity feature1 value1 [feature2 value2 ...]> ->
C<OK>. Each value is parsed according to that feature's schema type.

=head2 setat($group, $entity, $unix_ms, @feature_value_pairs)

C<FEATURE.SETAT group entity unix-ms feature1 value1 ...> -> C<OK>: like
C<set> but stamps the entity with the given time in Unix milliseconds.

=head2 get($group, $entity, @features)

C<FEATURE.GET group entity [feature1 feature2 ...]> -> C<undef> if the
entity has no stored features, else arrayref C<[flat_name_value_pairs,
updated_at_ms, freshness_ms]>. Omit C<@features> for all features.

=head2 batch($group, \@entities, \%opts)

C<FEATURE.BATCH group entity1 entity2 ... [FEATURES f1 f2 ...]> ->
arrayref with one entry per entity, each either C<undef> or the same shape
as C<get> above. opts: C<features> (arrayref).

=head2 schema($group)

C<FEATURE.SCHEMA group> -> arrayref of C<[name, type]> pairs.

=head2 list

C<FEATURE.LIST> -> arrayref of group names.

=head2 drop($group)

C<FEATURE.DROP group> -> C<OK>.

=head2 stats($group)

C<FEATURE.STATS group> -> flat array of 4 pairs: entities, totalReads,
totalWrites, memoryBytes.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }
sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }

sub create {
    my ($self, $group, $description, $schema) = @_;
    return $self->{ex}->_call('FEATURE.CREATE', $group, $description, 'SCHEMA', @$schema);
}

sub set { my $self = shift; my ($group, $entity) = (shift, shift); return $self->{ex}->_call('FEATURE.SET', $group, $entity, @_); }
sub get { my $self = shift; my ($group, $entity) = (shift, shift); return $self->{ex}->_call('FEATURE.GET', $group, $entity, @_); }
sub setat { my $self = shift; my ($group, $entity, $unix_ms) = (shift, shift, shift); return $self->{ex}->_call('FEATURE.SETAT', $group, $entity, $unix_ms, @_); }

sub batch {
    my ($self, $group, $entities, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('FEATURE.BATCH', $group, @$entities);
    push @args, 'FEATURES', @{ $opts->{features} } if $opts->{features} && @{ $opts->{features} };
    return $self->{ex}->_call(@args);
}

sub schema { my ($self, $group) = @_; return $self->{ex}->_call('FEATURE.SCHEMA', $group); }
sub list   { my ($self) = @_; return $self->{ex}->_call('FEATURE.LIST'); }
sub drop   { my ($self, $group) = @_; return $self->{ex}->_call('FEATURE.DROP', $group); }
sub stats  { my ($self, $group) = @_; return $self->{ex}->_call('FEATURE.STATS', $group); }

1;
