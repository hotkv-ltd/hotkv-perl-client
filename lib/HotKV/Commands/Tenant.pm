# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::Tenant;

use strict;
use warnings;

use HotKV::Commands::Support;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::Tenant - TENANT.* multi-tenancy administration (enterprise, needs the tenancy license feature)

=head1 SYNOPSIS

  $kv->tenant->create('t1', 'acme', { max_memory => 2**30, max_keys => 1_000_000 });
  my $info = $kv->tenant->info('t1');      # hashref: id, name, state, memory_bytes, ...
  $kv->tenant->suspend('t1');
  $kv->tenant->resume('t1');
  $kv->tenant->drop('t1');

=head1 METHODS

Reachable as C<< $client->tenant >>.

=head2 create($id, $name, \%opts)

C<TENANT.CREATE id name [MAX_MEMORY bytes] [MAX_KEYS n] [MAX_CONNECTIONS n]
[MAX_COMMANDS_SEC n] [MAX_DATABASES n] [MAX_EGRESS bytes]>. opts:
C<max_memory>, C<max_keys>, C<max_connections>, C<max_commands_sec>,
C<max_databases>, C<max_egress>.

=head2 drop($id), suspend($id), resume($id)

C<TENANT.DROP>, C<TENANT.SUSPEND>, C<TENANT.RESUME>.

=head2 list

C<TENANT.LIST>: arrayref of tenant names.

=head2 info($id), stats($id)

C<TENANT.INFO> and C<TENANT.STATS>: hashrefs of the reply's fields.

=head2 bind($id, $username), unbind($id, $username)

C<TENANT.BIND> and C<TENANT.UNBIND>.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }
sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }

sub create {
    my ($self, $id, $name, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('TENANT.CREATE', $id, $name);
    for my $o (qw(max_memory max_keys max_connections max_commands_sec max_databases max_egress)) {
        push @args, uc($o), $opts->{$o} if defined $opts->{$o};
    }
    return $self->{ex}->_call(@args);
}

sub drop    { my ($self, $id) = @_; return $self->{ex}->_call('TENANT.DROP', $id); }
sub suspend { my ($self, $id) = @_; return $self->{ex}->_call('TENANT.SUSPEND', $id); }
sub resume  { my ($self, $id) = @_; return $self->{ex}->_call('TENANT.RESUME', $id); }
sub list    { my ($self) = @_; return $self->{ex}->_call('TENANT.LIST'); }
sub bind    { my ($self, $id, $user) = @_; return $self->{ex}->_call('TENANT.BIND', $id, $user); }
sub unbind  { my ($self, $id, $user) = @_; return $self->{ex}->_call('TENANT.UNBIND', $id, $user); }

sub info {
    my ($self, $id) = @_;
    my $r = $self->{ex}->_call('TENANT.INFO', $id);
    return $r if $self->{ex}->_is_deferred($r);
    return HotKV::Commands::Support::pairs_to_h($r);
}

sub stats {
    my ($self, $id) = @_;
    my $r = $self->{ex}->_call('TENANT.STATS', $id);
    return $r if $self->{ex}->_is_deferred($r);
    return HotKV::Commands::Support::pairs_to_h($r);
}

1;

=head1 SUPPORT

support@hotkv.com

=head1 LICENSE

Apache License, Version 2.0; see the LICENSE file.

=cut
