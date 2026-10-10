# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::Encryption;

use strict;
use warnings;

use HotKV::Commands::Support;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::Encryption - ENCRYPTION.* encryption at rest (enterprise, needs the encryption license feature)

=head1 SYNOPSIS

  my $info = $kv->encryption->info;       # hashref: enabled, algorithm, provider
  $kv->encryption->verify('/var/lib/hotkv/dump.hkv');   # 1 or 0

=head1 METHODS

Reachable as C<< $client->encryption >>.

=head2 info

C<ENCRYPTION.INFO>: a hashref of the reply's fields.

=head2 rotate($new_key_file)

C<ENCRYPTION.ROTATE new_key_file>: C<OK>. The key file is a path on the
server and holds 32 bytes. Run C<bgsave> afterwards.

=head2 verify($file)

C<ENCRYPTION.VERIFY file>: 1 if the file is a valid encrypted file, else 0.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }

sub info {
    my ($self) = @_;
    my $r = $self->{ex}->_call('ENCRYPTION.INFO');
    return $r if $self->{ex}->_is_deferred($r);
    return HotKV::Commands::Support::pairs_to_h($r);
}

sub rotate { my ($self, $key_file) = @_; return $self->{ex}->_call('ENCRYPTION.ROTATE', $key_file); }
sub verify { my ($self, $file) = @_; return $self->{ex}->_call('ENCRYPTION.VERIFY', $file); }

1;

=head1 SUPPORT

support@hotkv.com

=head1 LICENSE

Apache License, Version 2.0; see the LICENSE file.

=cut
