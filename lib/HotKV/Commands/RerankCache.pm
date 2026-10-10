# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::RerankCache;

use strict;
use warnings;

use HotKV::Commands::Keyed;

our @ISA     = ('HotKV::Commands::Keyed');
our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::RerankCache - RERANK.* reranker result cache

Needs a server license that includes the C<rerank-cache> feature. Reachable as
C<< $client->rerank >>; see L<HotKV::Commands::Keyed> for the methods
(create/set/get/del/stats/flush/drop/list).

=cut

sub _prefix { return 'RERANK'; }

1;
