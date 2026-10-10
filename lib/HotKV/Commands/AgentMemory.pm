# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::AgentMemory;

use strict;
use warnings;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::AgentMemory - AMEM.* AI agent memory

Needs a server license that includes the C<agent-memory> feature for the
C<conv>/C<sem>/C<work>/C<epis>/C<search> methods below. The C<summary_*>
methods are C<AMEM.SUMMARY.*> and need the C<amem-summary> feature.
Reachable as C<< $client->amem >>.

=head1 CONVERSATION MEMORY

=head2 conv_create($session_id, \%opts)

C<AMEM.CONV.CREATE session_id [WINDOW size] [TTL seconds]> -> C<OK>. opts:
C<window>, C<ttl>.

=head2 conv_append($session_id, $role, $content)

C<AMEM.CONV.APPEND session_id role content> -> C<OK>.

=head2 conv_get($session_id)

C<AMEM.CONV.GET session_id> -> arrayref of turns, each a flat 4-element
arrayref C<["role", $role, "content", $content]>.

=head2 conv_window($session_id, $n)

C<AMEM.CONV.WINDOW session_id n> -> same shape as C<conv_get> above, last C<$n>
turns.

=head2 conv_clear($session_id) / conv_drop($session_id)

C<AMEM.CONV.CLEAR> / C<AMEM.CONV.DROP session_id> -> 1/0.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }
sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }

sub conv_create {
    my ($self, $sid, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('AMEM.CONV.CREATE', $sid);
    push @args, 'WINDOW', $opts->{window} if defined $opts->{window};
    push @args, 'TTL', $opts->{ttl} if defined $opts->{ttl};
    return $self->{ex}->_call(@args);
}
sub conv_append { my ($self, $sid, $role, $content) = @_; return $self->{ex}->_call('AMEM.CONV.APPEND', $sid, $role, $content); }
sub conv_get    { my ($self, $sid) = @_; return $self->{ex}->_call('AMEM.CONV.GET', $sid); }
sub conv_window { my ($self, $sid, $n) = @_; return $self->{ex}->_call('AMEM.CONV.WINDOW', $sid, $n); }
sub conv_clear  { my ($self, $sid) = @_; return $self->{ex}->_call('AMEM.CONV.CLEAR', $sid); }
sub conv_drop   { my ($self, $sid) = @_; return $self->{ex}->_call('AMEM.CONV.DROP', $sid); }

=head1 SEMANTIC MEMORY (per-agent vector store)

=head2 sem_create($agent_id, $dimensions)

C<AMEM.SEM.CREATE agent_id dimensions> -> C<OK>.

=head2 sem_store($agent_id, $key, $content, \@vector, \%opts)

C<AMEM.SEM.STORE agent_id key content val1 ... valN [TTL seconds]> ->
C<OK>. opts: C<ttl>.

=head2 sem_recall($agent_id, $k, \@vector)

C<AMEM.SEM.RECALL agent_id k val1 ... valN> -> arrayref of results, each a
flat 6-element arrayref C<["key", $key, "content", $content, "similarity",
$similarity]>, most similar first.

=head2 sem_forget($agent_id, $key)

C<AMEM.SEM.FORGET agent_id key> -> 1/0.

=head2 sem_list($agent_id)

C<AMEM.SEM.LIST agent_id> -> arrayref of keys.

=cut

sub sem_create { my ($self, $agent_id, $dims) = @_; return $self->{ex}->_call('AMEM.SEM.CREATE', $agent_id, $dims); }

sub sem_store {
    my ($self, $agent_id, $key, $content, $vec, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('AMEM.SEM.STORE', $agent_id, $key, $content, @$vec);
    push @args, 'TTL', $opts->{ttl} if defined $opts->{ttl};
    return $self->{ex}->_call(@args);
}
sub sem_recall { my ($self, $agent_id, $k, $vec) = @_; return $self->{ex}->_call('AMEM.SEM.RECALL', $agent_id, $k, @$vec); }
sub sem_forget { my ($self, $agent_id, $key) = @_; return $self->{ex}->_call('AMEM.SEM.FORGET', $agent_id, $key); }
sub sem_list   { my ($self, $agent_id) = @_; return $self->{ex}->_call('AMEM.SEM.LIST', $agent_id); }

=head1 WORKING MEMORY (per-session scratch key/value)

=head2 work_set($session_id, $key, $value, \%opts)

C<AMEM.WORK.SET session_id key value [TTL seconds]> -> C<OK>. opts: C<ttl>.

=head2 work_get($session_id, $key)

C<AMEM.WORK.GET session_id key> -> the value; an empty stored value is
indistinguishable from a miss, both reply C<undef>.

=head2 work_del($session_id, $key) / work_clear($session_id)

C<AMEM.WORK.DEL session_id key> / C<AMEM.WORK.CLEAR session_id> -> 1/0.

=head2 work_list($session_id)

C<AMEM.WORK.LIST session_id> -> arrayref of keys.

=cut

sub work_set {
    my ($self, $sid, $key, $value, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('AMEM.WORK.SET', $sid, $key, $value);
    push @args, 'TTL', $opts->{ttl} if defined $opts->{ttl};
    return $self->{ex}->_call(@args);
}
sub work_get   { my ($self, $sid, $key) = @_; return $self->{ex}->_call('AMEM.WORK.GET', $sid, $key); }
sub work_del   { my ($self, $sid, $key) = @_; return $self->{ex}->_call('AMEM.WORK.DEL', $sid, $key); }
sub work_clear { my ($self, $sid) = @_; return $self->{ex}->_call('AMEM.WORK.CLEAR', $sid); }
sub work_list  { my ($self, $sid) = @_; return $self->{ex}->_call('AMEM.WORK.LIST', $sid); }

=head1 EPISODIC MEMORY (append-only event log)

=head2 epis_log($agent_id, $event_type, $content, \%opts)

C<AMEM.EPIS.LOG agent_id event_type content [METADATA json]> -> C<OK>.
opts: C<metadata>.

=head2 epis_query($agent_id, \%opts)

C<AMEM.EPIS.QUERY agent_id [TYPE event_type] [FROM ts] [TO ts] [LIMIT n]>
-> arrayref of events, each a flat 8-element arrayref C<["type", $type,
"content", $content, "metadata", $metadata, "timestamp", $ts_ns]>. opts:
C<type>, C<from>, C<to>, C<limit>.

=head2 epis_clear($agent_id)

C<AMEM.EPIS.CLEAR agent_id> -> 1/0.

=head2 epis_stats($agent_id)

C<AMEM.EPIS.STATS agent_id> -> flat array of 3 pairs: total_events,
oldest_ts, newest_ts.

=cut

sub epis_log {
    my ($self, $agent_id, $event_type, $content, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('AMEM.EPIS.LOG', $agent_id, $event_type, $content);
    push @args, 'METADATA', $opts->{metadata} if defined $opts->{metadata};
    return $self->{ex}->_call(@args);
}

sub epis_query {
    my ($self, $agent_id, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('AMEM.EPIS.QUERY', $agent_id);
    push @args, 'TYPE', $opts->{type} if defined $opts->{type};
    push @args, 'FROM', $opts->{from} if defined $opts->{from};
    push @args, 'TO', $opts->{to} if defined $opts->{to};
    push @args, 'LIMIT', $opts->{limit} if defined $opts->{limit};
    return $self->{ex}->_call(@args);
}
sub epis_clear { my ($self, $agent_id) = @_; return $self->{ex}->_call('AMEM.EPIS.CLEAR', $agent_id); }
sub epis_stats { my ($self, $agent_id) = @_; return $self->{ex}->_call('AMEM.EPIS.STATS', $agent_id); }

=head1 CROSS-MEMORY SEARCH

=head2 search($agent_id, $k, \@vector)

C<AMEM.SEARCH agent_id k val1 ... valN> -> arrayref of results (searches
semantic + episodic + working together), each a flat 8-element arrayref
C<["source", $source_type, "key", $key, "content", $content, "similarity",
$similarity]>.

=cut

sub search { my ($self, $agent_id, $k, $vec) = @_; return $self->{ex}->_call('AMEM.SEARCH', $agent_id, $k, @$vec); }

=head1 SUMMARY (requires C<amem-summary>)

=head2 summary_set($agent_id, $summary)

C<AMEM.SUMMARY.SET agent_id summary> -> integer, new version number.

=head2 summary_append($agent_id, $extra)

C<AMEM.SUMMARY.APPEND agent_id extra> -> integer, new version number
(appends to the stored summary text).

=head2 summary_get($agent_id)

C<AMEM.SUMMARY.GET agent_id> -> arrayref C<[summary, version,
updated_unix]>, or C<undef>.

=head2 summary_drop($agent_id)

C<AMEM.SUMMARY.DROP agent_id> -> 1/0.

=head2 summary_list

C<AMEM.SUMMARY.LIST> -> arrayref of agent ids.

=cut

sub summary_set    { my ($self, $agent_id, $summary) = @_; return $self->{ex}->_call('AMEM.SUMMARY.SET', $agent_id, $summary); }
sub summary_append { my ($self, $agent_id, $extra) = @_; return $self->{ex}->_call('AMEM.SUMMARY.APPEND', $agent_id, $extra); }
sub summary_get     { my ($self, $agent_id) = @_; return $self->{ex}->_call('AMEM.SUMMARY.GET', $agent_id); }
sub summary_drop    { my ($self, $agent_id) = @_; return $self->{ex}->_call('AMEM.SUMMARY.DROP', $agent_id); }
sub summary_list    { my ($self) = @_; return $self->{ex}->_call('AMEM.SUMMARY.LIST'); }

1;
