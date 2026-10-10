# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::Iam;

use strict;
use warnings;

use HotKV::Commands::Support;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::Iam - IAM.* roles, sessions and authentication (enterprise, needs the iam license feature)

=head1 SYNOPSIS

  $kv->iam->role_create('analyst', 'read,write', { key_prefixes => ['analytics:'], rate_limit => 1000 });
  $kv->iam->user_assign('alice', 'analyst');
  my $role = $kv->iam->role_info('analyst');
  $kv->iam->role_delete('analyst');

=head1 METHODS

Reachable as C<< $client->iam >>.

=head2 role_create($name, $permissions, \%opts)

C<IAM.ROLE.CREATE name permissions [KEY_PREFIXES p1,p2] [RATE_LIMIT n]
[MEMORY_QUOTA bytes]>. C<$permissions> is the comma separated list as a
string, or an arrayref that is joined with commas. opts: C<key_prefixes>
(arrayref or comma separated string), C<rate_limit>, C<memory_quota>.

=head2 role_delete($name), role_list, role_info($name)

C<IAM.ROLE.DELETE>, C<IAM.ROLE.LIST> (arrayref of names), C<IAM.ROLE.INFO>
(hashref: name, permissions, rate_limit, memory_quota).

=head2 user_assign($username, $rolename)

C<IAM.USER.ASSIGN>.

=head2 session_list, session_kill($id)

C<IAM.SESSION.LIST> (arrayref of hashrefs: id, username, commands) and
C<IAM.SESSION.KILL>.

=head2 auth($source, $username, $credential)

C<IAM.AUTH>: the integer session id. C<$source> is C<local>, C<ldap>, C<oidc>
or C<saml>.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }
sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }

sub _csv { my ($v) = @_; return ref($v) eq 'ARRAY' ? join(',', @$v) : $v; }

sub role_create {
    my ($self, $name, $permissions, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('IAM.ROLE.CREATE', $name, _csv($permissions));
    push @args, 'KEY_PREFIXES', _csv($opts->{key_prefixes}) if defined $opts->{key_prefixes};
    push @args, 'RATE_LIMIT',   $opts->{rate_limit}         if defined $opts->{rate_limit};
    push @args, 'MEMORY_QUOTA', $opts->{memory_quota}       if defined $opts->{memory_quota};
    return $self->{ex}->_call(@args);
}

sub role_delete { my ($self, $name) = @_; return $self->{ex}->_call('IAM.ROLE.DELETE', $name); }
sub role_list   { my ($self) = @_; return $self->{ex}->_call('IAM.ROLE.LIST'); }
sub user_assign { my ($self, $user, $role) = @_; return $self->{ex}->_call('IAM.USER.ASSIGN', $user, $role); }
sub session_kill { my ($self, $id) = @_; return $self->{ex}->_call('IAM.SESSION.KILL', $id); }
sub auth { my ($self, $source, $user, $credential) = @_; return $self->{ex}->_call('IAM.AUTH', $source, $user, $credential); }

sub role_info {
    my ($self, $name) = @_;
    my $r = $self->{ex}->_call('IAM.ROLE.INFO', $name);
    return $r if $self->{ex}->_is_deferred($r);
    return HotKV::Commands::Support::pairs_to_h($r);
}

sub session_list {
    my ($self) = @_;
    my $r = $self->{ex}->_call('IAM.SESSION.LIST');
    return $r if $self->{ex}->_is_deferred($r);
    return [ map { HotKV::Commands::Support::pairs_to_h($_) } @{ $r || [] } ];
}

1;

=head1 SUPPORT

support@hotkv.com

=head1 LICENSE

Apache License, Version 2.0; see the LICENSE file.

=cut
