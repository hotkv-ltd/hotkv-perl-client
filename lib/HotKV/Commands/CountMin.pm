# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::CountMin;

use strict;
use warnings;

use HotKV::Protocol;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::CountMin - CMS.* Count-Min Sketch commands (core, no license needed)

=head1 SYNOPSIS

  $kv->cms->initbydim('hits', 2000, 5);
  $kv->cms->incrby('hits', 'page:1', 3, 'page:2', 1);
  my $counts = $kv->cms->query('hits', 'page:1', 'page:2');   # [3, 1]

=head1 METHODS

Reachable as C<< $client->cms >>.

=head2 initbydim($key, $width, $depth)

C<CMS.INITBYDIM>.

=head2 initbyprob($key, $error, $probability)

C<CMS.INITBYPROB>.

=head2 incrby($key, $item, $increment, ...)

C<CMS.INCRBY key item increment [item increment ...]>: arrayref of the new
counts.

=head2 query($key, @items)

C<CMS.QUERY>: arrayref of estimated counts.

=head2 info($key)

C<CMS.INFO>: hashref with C<width>, C<depth>, C<count>.

=head2 merge($dest, \@sources, \@weights)

C<CMS.MERGE dest numkeys key ... [WEIGHTS w ...]>.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }

sub initbydim  { my ($self, $key, $w, $d) = @_; return $self->{ex}->_call('CMS.INITBYDIM', $key, $w, $d); }
sub initbyprob {
    my ($self, $key, $error, $prob) = @_;
    return $self->{ex}->_call('CMS.INITBYPROB', $key,
        HotKV::Protocol::format_number($error), HotKV::Protocol::format_number($prob));
}
sub incrby { my $self = shift; my $key = shift; return $self->{ex}->_call('CMS.INCRBY', $key, @_); }
sub query  { my $self = shift; my $key = shift; return $self->{ex}->_call('CMS.QUERY', $key, @_); }

sub info {
    my ($self, $key) = @_;
    my $r = $self->{ex}->_call('CMS.INFO', $key);
    return $r if $self->{ex}->_is_deferred($r);
    return HotKV::Commands::_to_hash($r);
}

sub merge {
    my ($self, $dest, $sources, $weights) = @_;
    my @args = ('CMS.MERGE', $dest, scalar(@$sources), @$sources);
    push @args, 'WEIGHTS', @$weights if $weights && @$weights;
    return $self->{ex}->_call(@args);
}

1;

=head1 SUPPORT

support@hotkv.com

=head1 LICENSE

Apache License, Version 2.0; see the LICENSE file.

=cut
