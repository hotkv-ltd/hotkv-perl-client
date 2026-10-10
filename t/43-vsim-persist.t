# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# VSIM.SAVE/LOAD/LIST/DROP (persistence) require the "vsim-persist" license
# feature; VSIM.CREATEINDEX/SET/SEARCH/etc are core and already covered by
# t/30-hotkv-core.t.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url unique_name safe_name is_nolicense);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();

use HotKV;

my $kv = HotKV->new(url => test_url());
my $snapshot = safe_name('vsimsnap');

my $ok = eval { $kv->vsim->save($snapshot, 'blob-bytes-here'); 1 };
if (!$ok) {
    ok(is_nolicense($@), 'VSIM.SAVE without the vsim-persist license raises NotLicensed')
        or diag("unexpected error: $@");
}

SKIP: {
    skip 'vsim-persist license feature not enabled by the test server', 4 unless $ok;

    is($kv->vsim->load($snapshot), 'blob-bytes-here', 'VSIM.LOAD returns the saved blob');
    is($kv->vsim->load(safe_name('no-such-snapshot')), undef, 'VSIM.LOAD miss is nil');
    ok((grep { $_ eq $snapshot } @{ $kv->vsim->list_snapshots }) == 1, 'VSIM.LIST');
    is($kv->vsim->drop_snapshot($snapshot), 1, 'VSIM.DROP');
}

$kv->close;
done_testing();
