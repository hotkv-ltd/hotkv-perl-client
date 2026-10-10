# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::Replication;

use strict;
use warnings;

use HotKV::Commands::Support;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::Replication - REPLICATION.* (enterprise, needs the replication license feature)

=head1 SYNOPSIS

  my $info = $kv->replication->info;   # hashref: role, state, repl_offset, connected_replicas
  $kv->replication->pause;
  $kv->replication->resume;

=head1 METHODS

Reachable as C<< $client->replication >>. To point a server at a primary use
C<< $kv->replicaof($host, $port) >> and C<< $kv->replicaof_no_one >>.

=head2 info

C<REPLICATION.INFO>: a hashref of the reply's fields.

=head2 pause, resume

C<REPLICATION.PAUSE> (stop sending writes on a primary, applying them on a
replica) and C<REPLICATION.RESUME>.

=head2 failover

C<REPLICATION.FAILOVER>: promote this replica to primary. A server that is
already a primary answers with an error.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }

sub info {
    my ($self) = @_;
    my $r = $self->{ex}->_call('REPLICATION.INFO');
    return $r if $self->{ex}->_is_deferred($r);
    return HotKV::Commands::Support::pairs_to_h($r);
}

sub pause    { my ($self) = @_; return $self->{ex}->_call('REPLICATION.PAUSE'); }
sub resume   { my ($self) = @_; return $self->{ex}->_call('REPLICATION.RESUME'); }
sub failover { my ($self) = @_; return $self->{ex}->_call('REPLICATION.FAILOVER'); }

1;

=head1 SUPPORT

support@hotkv.com

=head1 LICENSE

Apache License, Version 2.0; see the LICENSE file.

=cut
