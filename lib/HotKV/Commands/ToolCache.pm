# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::ToolCache;

use strict;
use warnings;

use HotKV::Commands::Keyed;

our @ISA     = ('HotKV::Commands::Keyed');
our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::ToolCache - TOOL.CACHE.* tool-call result cache

Needs a server license that includes the C<tool-cache> feature. Reachable as
C<< $client->toolcache >>; see L<HotKV::Commands::Keyed> for the methods
(create/set/get/del/stats/flush/drop/list).

=cut

sub _prefix { return 'TOOL.CACHE'; }

1;
