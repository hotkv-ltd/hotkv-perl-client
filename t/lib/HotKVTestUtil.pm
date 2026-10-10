# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# Shared helpers for the integration tests in t/.

package HotKVTestUtil;

use strict;
use warnings;

use Exporter 'import';
use Scalar::Util qw(blessed);

our @EXPORT_OK = qw(test_url unique_name safe_name is_nolicense skip_all_if_no_server);

my $counter = 0;

sub test_url { return $ENV{HOTKV_TEST_URL}; }

# A key/namespace/bucket/... name that will not collide with a previous or
# concurrent test run. Tests that touch TAG.* or other global namespaces
# use it so that they never depend on a reset between runs.
sub unique_name {
    my ($label) = @_;
    $label = 'k' unless defined $label;
    $counter++;
    return sprintf('sdktest:%s:%d:%d:%d', $label, $$, time(), $counter);
}

# Like unique_name, but only letters, digits, underscore and dash: for names
# the server restricts (VSIM.SAVE snapshot names refuse '.', ':' and '/').
sub safe_name {
    my ($label) = @_;
    (my $n = unique_name($label)) =~ s/[^A-Za-z0-9_-]/_/g;
    return $n;
}

sub is_nolicense {
    my ($err) = @_;
    return blessed($err) && $err->isa('HotKV::Error::Server::NotLicensed');
}

1;
