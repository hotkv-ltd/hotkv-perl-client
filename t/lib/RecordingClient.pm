# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# A minimal stand-in for HotKV used by command unit tests: every
# HotKV::Commands::* family class only ever calls _call(@args) (and,
# where it parses the reply, _is_deferred($result)) on the object it is
# given, so this records the exact argument list of each call (to assert
# new options build the right wire arguments) and, when built with a
# canned +reply+, hands it back (to assert parsing of canned RESP2/RESP3
# replies), all without a live server. Inherits every family accessor
# (pcache, scache, llmstats, llmbudget, toolcache, ncache, guard,
# rerank, ...) and _is_deferred from HotKV::Commands, so
# HotKV::AI::PromptCache/SemanticCache (which call $client->pcache/
# ->scache/->llmstats, not _call directly) work against it too.

package RecordingClient;

use strict;
use warnings;

use HotKV::Commands;

our @ISA = ('HotKV::Commands');

sub new {
    my ($class, %opts) = @_;
    return bless { calls => [], reply => $opts{reply} }, $class;
}

sub _call {
    my ($self, @args) = @_;
    push @{ $self->{calls} }, [@args];
    return $self->{reply};
}

sub calls     { return $_[0]->{calls}; }
sub last_call { return $_[0]->{calls}[-1]; }

1;
