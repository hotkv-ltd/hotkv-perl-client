# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::Tag;

use strict;
use warnings;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::Tag - TAG.* key tagging commands (core, no license needed)

=head1 SYNOPSIS

  $kv->tag->set($key, 'red', 'in-stock');
  my @tags = @{ $kv->tag->get($key) };
  my @keys = @{ $kv->tag->members('red') };

=head1 METHODS

Reachable as C<< $client->tag >>. All methods return whatever HotKV::Commands'
underlying C<_call> returns (a decoded reply, or C<$self> of the pipeline/
transaction that queued it).

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }

=head2 set($key, @tags)

C<TAG.SET key tag [tag ...]>: integer, number of tags newly added.

=head2 rem($key, @tags)

C<TAG.REM key tag [tag ...]>: integer, number of tags removed.

=head2 get($key)

C<TAG.GET key>: arrayref of all tags on C<$key>.

=head2 members($tag)

C<TAG.MEMBERS tag>: arrayref of all keys carrying C<$tag>.

=head2 inter(@tags)

C<TAG.INTER tag [tag ...]>: arrayref of keys carrying every given tag.

=head2 count($key)

C<TAG.COUNT key>: integer, number of tags on C<$key>.

=head2 exists($key, $tag)

C<TAG.EXISTS key tag>: 1 or 0.

=cut

sub set     { my $self = shift; my $key = shift; return $self->{ex}->_call('TAG.SET', $key, @_); }
sub rem     { my $self = shift; my $key = shift; return $self->{ex}->_call('TAG.REM', $key, @_); }
sub get     { my ($self, $key) = @_; return $self->{ex}->_call('TAG.GET', $key); }
sub members { my ($self, $tag) = @_; return $self->{ex}->_call('TAG.MEMBERS', $tag); }
sub inter   { my $self = shift; return $self->{ex}->_call('TAG.INTER', @_); }
sub count   { my ($self, $key) = @_; return $self->{ex}->_call('TAG.COUNT', $key); }
sub exists  { my ($self, $key, $tag) = @_; return $self->{ex}->_call('TAG.EXISTS', $key, $tag); }

1;
