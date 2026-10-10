# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# RATELIMIT.* requires the "rate-limiting" license feature. Without it every
# call below raises NotLicensed; see t/32-pcache.t for why detecting that
# error is itself the assertion.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url unique_name is_nolicense);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();

use HotKV;

my $kv = HotKV->new(url => test_url());
my $name = unique_name('ratelimit');

my $ok = eval { $kv->ratelimit->create($name, 3, 60_000, { algo => 'sliding_window' }); 1 };
if (!$ok) {
    ok(is_nolicense($@), 'RATELIMIT.CREATE without the rate-limiting license raises NotLicensed')
        or diag("unexpected error: $@");
}

SKIP: {
    skip 'rate-limiting license feature not enabled by the test server', 14 unless $ok;

    my $r1 = $kv->ratelimit->check($name, 'userA');
    is($r1->[0], 1, 'RATELIMIT.CHECK first call is allowed');
    is($r1->[3], 3, 'RATELIMIT.CHECK reports the configured limit');

    $kv->ratelimit->check($name, 'userA') for (1 .. 2);
    my $r4 = $kv->ratelimit->check($name, 'userA');
    is($r4->[0], 0, 'RATELIMIT.CHECK denies once the limit is exhausted');

    my $peek = $kv->ratelimit->peek($name, 'userA');
    is($peek->[0], 0, 'RATELIMIT.PEEK reflects the exhausted state');
    my $peek_again = $kv->ratelimit->peek($name, 'userA');
    is_deeply($peek, $peek_again, 'RATELIMIT.PEEK does not mutate state (two peeks agree)');

    is($kv->ratelimit->reset($name, 'userA'), 'OK', 'RATELIMIT.RESET');
    is($kv->ratelimit->check($name, 'userA')->[0], 1, 'RATELIMIT.CHECK is allowed again after RESET');

    my $stats = $kv->ratelimit->stats($name);
    my %stats_h = @$stats;
    is($stats_h{name}, $name, 'RATELIMIT.STATS name');
    is($stats_h{algo}, 'sliding_window', 'RATELIMIT.STATS algo');

    my $r_cost = $kv->ratelimit->check($name, 'userB', { cost => 2 });
    is($r_cost->[0], 1, 'RATELIMIT.CHECK COST is accepted');
    is($r_cost->[1], $r_cost->[3] - 2, 'RATELIMIT.CHECK COST 2 reduces remaining by 2, not 1');

    ok((grep { $_ eq $name } @{ $kv->ratelimit->list }) == 1, 'RATELIMIT.LIST includes this limiter');
    is($kv->ratelimit->drop($name), 'OK', 'RATELIMIT.DROP');
    my $err = eval { $kv->ratelimit->drop($name); 1 } ? undef : $@;
    ok($err, 'RATELIMIT.DROP on an already-dropped limiter raises');
}

$kv->close;
done_testing();
