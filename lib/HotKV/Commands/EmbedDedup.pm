# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::EmbedDedup;

use strict;
use warnings;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::EmbedDedup - EMBED.DEDUP.* embedding deduplication store

Needs a server license that includes the C<embed-dedup> feature. Reachable
as C<< $client->embeddedup >>.

=head2 put($ns, $hash, $model, $embedding)

C<EMBED.DEDUP.PUT ns hash model embedding> -> 1 (newly stored) / 0 (hash
already existed; refcount incremented instead).

=head2 get($ns, $hash)

C<EMBED.DEDUP.GET ns hash> -> the embedding, or C<undef>.

=head2 release($ns, $hash)

C<EMBED.DEDUP.RELEASE ns hash> -> 1/0 (decrements refcount; freed at 0).

=head2 stats($ns)

C<EMBED.DEDUP.STATS ns> -> flat array of 3 pairs: hits, misses, entries.

=head2 drop($ns)

C<EMBED.DEDUP.DROP ns> -> 1/0.

=head2 purge($ns)

C<EMBED.DEDUP.PURGE ns> -> 1/0 (purges expired/unreferenced entries).

=head2 list

C<EMBED.DEDUP.LIST> -> arrayref of namespace names.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }

sub put     { my ($self, $ns, $hash, $model, $embedding) = @_; return $self->{ex}->_call('EMBED.DEDUP.PUT', $ns, $hash, $model, $embedding); }
sub get     { my ($self, $ns, $hash) = @_; return $self->{ex}->_call('EMBED.DEDUP.GET', $ns, $hash); }
sub release { my ($self, $ns, $hash) = @_; return $self->{ex}->_call('EMBED.DEDUP.RELEASE', $ns, $hash); }
sub stats   { my ($self, $ns) = @_; return $self->{ex}->_call('EMBED.DEDUP.STATS', $ns); }
sub drop    { my ($self, $ns) = @_; return $self->{ex}->_call('EMBED.DEDUP.DROP', $ns); }
sub purge   { my ($self, $ns) = @_; return $self->{ex}->_call('EMBED.DEDUP.PURGE', $ns); }
sub list    { my ($self) = @_; return $self->{ex}->_call('EMBED.DEDUP.LIST'); }

1;
