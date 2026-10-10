# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::TimeSeries;

use strict;
use warnings;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::TimeSeries - TS.* time series

Needs a server license that includes the C<time-series> feature.
Reachable as C<< $client->ts >>.

=head2 create($key, \%opts)

C<TS.CREATE key [RETENTION ms] [LABELS l1 v1 ...]> -> C<OK>. opts:
C<retention>, C<labels> (flat arrayref of label/value pairs). Always
written with C<RETENTION> before C<LABELS> on the wire (required order:
the server reads C<LABELS> values until the C<RETENTION> keyword or end of
args).

=head2 add($key, $timestamp, $value)

C<TS.ADD key timestamp|* value> -> integer, the timestamp (ms) used. Pass
the literal string C<'*'> for C<$timestamp> to let the server assign the
current time.

=head2 range($key, $from_ms, $to_ms, \%opts)

C<TS.RANGE key from_ms to_ms [COUNT n]> -> arrayref of C<[timestamp_ms,
value]> pairs. C<$from_ms>/C<$to_ms> accept the literal strings C<'-'>
(= 0) and C<'+'> (= max int64) as well as a numeric ms timestamp. opts:
C<count>.

=head2 agg($key, $from_ms, $to_ms, $bucket_ms, $agg_type)

C<TS.AGG key from_ms to_ms bucket_ms agg_type> -> arrayref of
C<[timestamp_ms, value]> pairs, bucketed. C<$agg_type> is one of C<avg>,
C<min>, C<max>, C<sum>, C<count> (case insensitive).

=head2 info($key)

C<TS.INFO key> -> flat array of 8 pairs: key, totalSamples,
firstTimestamp, lastTimestamp, lastValue, retentionMs, memoryBytes, labels
(itself an arrayref of C<[label, value]> pairs), rules (integer count).

=head2 delete($key)

C<TS.DELETE key> -> C<OK>.

=head2 retention($key, $retention_ms)

C<TS.RETENTION key retention_ms> -> C<OK>.

=head2 downsample($src_key, $dest_key, $agg_type, $bucket_ms)

C<TS.DOWNSAMPLE src_key dest_key agg_type bucket_ms> -> C<OK>: adds a live
downsample rule (both keys must already exist).

=head2 list(\%opts)

C<TS.LIST [LABEL key value]> -> arrayref of series keys. opts: C<label>
(arrayref C<[key, value]>).

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }
sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }

sub create {
    my ($self, $key, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('TS.CREATE', $key);
    push @args, 'RETENTION', $opts->{retention} if defined $opts->{retention};
    push @args, 'LABELS', @{ $opts->{labels} } if $opts->{labels} && @{ $opts->{labels} };
    return $self->{ex}->_call(@args);
}

sub add { my ($self, $key, $timestamp, $value) = @_; return $self->{ex}->_call('TS.ADD', $key, $timestamp, $value); }

sub range {
    my ($self, $key, $from_ms, $to_ms, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('TS.RANGE', $key, $from_ms, $to_ms);
    push @args, 'COUNT', $opts->{count} if defined $opts->{count};
    return $self->{ex}->_call(@args);
}

sub agg { my ($self, $key, $from_ms, $to_ms, $bucket_ms, $agg_type) = @_; return $self->{ex}->_call('TS.AGG', $key, $from_ms, $to_ms, $bucket_ms, $agg_type); }
sub info       { my ($self, $key) = @_; return $self->{ex}->_call('TS.INFO', $key); }
sub delete     { my ($self, $key) = @_; return $self->{ex}->_call('TS.DELETE', $key); }
sub retention  { my ($self, $key, $retention_ms) = @_; return $self->{ex}->_call('TS.RETENTION', $key, $retention_ms); }
sub downsample { my ($self, $src, $dest, $agg_type, $bucket_ms) = @_; return $self->{ex}->_call('TS.DOWNSAMPLE', $src, $dest, $agg_type, $bucket_ms); }

sub list {
    my ($self, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('TS.LIST');
    push @args, 'LABEL', @{ $opts->{label} } if $opts->{label};
    return $self->{ex}->_call(@args);
}

1;
