# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::Audit;

use strict;
use warnings;

use HotKV::Commands::Support;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::Audit - AUDIT.* tamper evident audit log (enterprise, needs the audit license feature)

=head1 SYNOPSIS

  my $info = $kv->audit->info;       # hashref: total_entries, file_size_bytes, chain_valid, last_sequence
  $kv->audit->verify;                # dies unless the hash chain is intact
  $kv->audit->export('/var/log/hotkv/audit.csv', { format => 'csv' });

=head1 METHODS

Reachable as C<< $client->audit >>.

=head2 info

C<AUDIT.INFO>: a hashref of the reply's fields.

=head2 verify

C<AUDIT.VERIFY>: the server's confirmation text; a broken chain raises a
L<HotKV::Error::Server>.

=head2 export($file, \%opts)

C<AUDIT.EXPORT file [FORMAT jsonl|csv|cef]>: C<OK>. The file is written on
the server. opts: C<format>.

=head2 rotate

C<AUDIT.ROTATE>: C<OK>.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }
sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }

sub info {
    my ($self) = @_;
    my $r = $self->{ex}->_call('AUDIT.INFO');
    return $r if $self->{ex}->_is_deferred($r);
    return HotKV::Commands::Support::pairs_to_h($r);
}

sub verify { my ($self) = @_; return $self->{ex}->_call('AUDIT.VERIFY'); }
sub rotate { my ($self) = @_; return $self->{ex}->_call('AUDIT.ROTATE'); }

sub export {
    my ($self, $file, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('AUDIT.EXPORT', $file);
    push @args, 'FORMAT', $opts->{format} if defined $opts->{format};
    return $self->{ex}->_call(@args);
}

1;

=head1 SUPPORT

support@hotkv.com

=head1 LICENSE

Apache License, Version 2.0; see the LICENSE file.

=cut
