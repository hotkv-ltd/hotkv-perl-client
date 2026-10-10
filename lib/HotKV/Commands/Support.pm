# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::Support;

use strict;
use warnings;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::Support - Shared reply-shaping helpers

=head1 DESCRIPTION

Plain package functions (not a mixin), called fully qualified, shared by
more than one command module.

=head2 pairs_to_h($reply, %opts)

Builds a hashref out of a HotKV fixed-schema STATS/INFO reply, parsed BY
FIELD NAME rather than positionally: a flat
arrayref of N pairs (name, value, name, value, ...) under RESP2, or a
native hashref (already decoded from a RESP3 map) under RESP3, which
HotKV sends for some of these replies either way.
C<float_keys> (an arrayref of field names) numifies just those fields
instead of leaving them as the server sent them (already a plain number
for a RESP C<:> integer reply).

A missing field is simply absent from the returned hashref (callers
building a typed object fall back to its own defaults); a field named in
C<float_keys> whose value does not look numeric (a server addition this
SDK does not know how to coerce) keeps its raw value instead of raising.
This is what keeps every STATS/INFO reply forward compatible with a
server that adds fields.

=cut

sub pairs_to_h {
    my ($reply, %opts) = @_;
    my $float_keys = $opts{float_keys} || [];

    my %h;
    if (ref($reply) eq 'HASH') {
        %h = %$reply;
    }
    else {
        my @a = defined $reply ? @$reply : ();
        for (my $i = 0; $i + 1 < @a; $i += 2) {
            $h{$a[$i]} = $a[$i + 1];
        }
    }

    for my $k (@$float_keys) {
        next unless exists $h{$k};
        my $v = $h{$k};
        # Leave the raw value alone if it does not look like a plain
        # number: an unrecognized/malformed field must never break decoding.
        $h{$k} = $v + 0 if defined $v && $v =~ /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?\z/;
    }

    return \%h;
}

1;
