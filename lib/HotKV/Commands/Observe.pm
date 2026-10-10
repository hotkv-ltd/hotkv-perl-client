# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::Observe;

use strict;
use warnings;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::Observe - OBSERVE and ALERTS admin/observability commands

Needs a server license that includes the C<enterprise-observability>
feature. Reachable as C<< $client->observe >>. C<OBSERVE> and C<ALERTS> are each a single
command name with a subcommand as their first argument (e.g.
C<OBSERVE INFO>, C<ALERTS TEST>).

=head2 info

C<OBSERVE INFO> -> flat array of 7 pairs: uptime_seconds,
connected_clients, total_commands, used_memory_bytes, peak_memory_bytes,
total_connections, enterprise_features.

=head2 metrics

C<OBSERVE METRICS> -> flat array of 10 pairs: uptime_seconds,
connected_clients, total_commands, total_connections, used_memory_bytes,
peak_memory_bytes, slowlog_length, alerts_sent, alerts_failed,
num_workers.

=head2 alerts_info

C<ALERTS INFO> -> flat array of 13 pairs: enabled, flag_enabled,
webhook_url, provider, supported_providers, min_severity, alerts_sent,
alerts_failed, alerts_dropped, alerts_rate_limited, alerts_deduped,
alerts_filtered, alerts_queued.

=head2 alerts_test(\%opts)

C<ALERTS TEST [info|warning|critical] [message]> -> a simple string
starting C<OK> on success (raises a L<HotKV::Error::Server> with an C<ERR>
code if the test alert was filtered, rate-limited, deduped or the queue is
full). opts: C<severity>, C<message>.

=head2 alerts_seturl($url)

C<ALERTS SETURL url> -> simple string C<OK ...>. An empty string disables
alerting.

=head2 alerts_setseverity($severity)

C<ALERTS SETSEVERITY info|warning|critical> -> simple string C<OK ...>.

=head2 alerts_on / alerts_off

C<ALERTS ON> / C<ALERTS OFF> -> simple string C<OK ...>. Toggles the
master flag without clearing the webhook URL.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }

sub info    { my ($self) = @_; return $self->{ex}->_call('OBSERVE', 'INFO'); }
sub metrics { my ($self) = @_; return $self->{ex}->_call('OBSERVE', 'METRICS'); }

sub alerts_info { my ($self) = @_; return $self->{ex}->_call('ALERTS', 'INFO'); }

sub alerts_test {
    my ($self, @rest) = @_;
    my $opts = (ref $rest[-1] eq 'HASH') ? pop(@rest) : {};
    my @args = ('ALERTS', 'TEST');
    push @args, $opts->{severity} if defined $opts->{severity};
    push @args, $opts->{message} if defined $opts->{message};
    return $self->{ex}->_call(@args);
}

sub alerts_seturl      { my ($self, $url) = @_; return $self->{ex}->_call('ALERTS', 'SETURL', $url); }
sub alerts_setseverity { my ($self, $sev) = @_; return $self->{ex}->_call('ALERTS', 'SETSEVERITY', $sev); }
sub alerts_on          { my ($self) = @_; return $self->{ex}->_call('ALERTS', 'ON'); }
sub alerts_off         { my ($self) = @_; return $self->{ex}->_call('ALERTS', 'OFF'); }

1;
