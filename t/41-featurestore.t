# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# FEATURE.* requires the "feature-store" license feature. Without it every
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
my $group = unique_name('features');

my $ok = eval {
    $kv->feature->create($group, 'user features', ['age', 'int64', 'score', 'double', 'name', 'string']);
    1;
};
if (!$ok) {
    ok(is_nolicense($@), 'FEATURE.CREATE without the feature-store license raises NotLicensed')
        or diag("unexpected error: $@");
}

SKIP: {
    skip 'feature-store license feature not enabled by the test server', 12 unless $ok;

    is($kv->feature->set($group, 'user1', 'age', 30, 'score', '4.5', 'name', 'ada'), 'OK', 'FEATURE.SET');
    $kv->feature->set($group, 'user2', 'age', 25, 'score', '3.2', 'name', 'lin');

    my $got = $kv->feature->get($group, 'user1');
    is(ref($got), 'ARRAY', 'FEATURE.GET returns a 3-element arrayref');
    my %flat = @{ $got->[0] };
    is($flat{age}, 30, 'FEATURE.GET returns the age feature');
    is($flat{name}, 'ada', 'FEATURE.GET returns the name feature');
    ok($got->[1] > 0, 'FEATURE.GET updated_at_ms is positive');

    is($kv->feature->get($group, unique_name('no-such-entity')), undef, 'FEATURE.GET on an unknown entity is nil');

    my $only_name = $kv->feature->get($group, 'user1', 'name');
    my %only_name_flat = @{ $only_name->[0] };
    is_deeply(\%only_name_flat, { name => 'ada' }, 'FEATURE.GET with a feature name list restricts the result');

    my $batch = $kv->feature->batch($group, ['user1', 'user2', 'nope'], { features => ['age'] });
    is(scalar(@$batch), 3, 'FEATURE.BATCH returns one entry per requested entity');
    is_deeply($batch->[0][0], ['age', 30], 'FEATURE.BATCH first entity restricted to the requested feature');
    is($batch->[2], undef, 'FEATURE.BATCH entry for an unknown entity is nil');

    my $schema = $kv->feature->schema($group);
    is_deeply(
        { map { @$_ } @$schema },
        { age => 'int64', score => 'double', name => 'string' },
        'FEATURE.SCHEMA lists every declared feature and its type'
    );

    my $stats = $kv->feature->stats($group);
    my %stats_h = @$stats;
    is($stats_h{entities}, 2, 'FEATURE.STATS entities');

    ok((grep { $_ eq $group } @{ $kv->feature->list }) == 1, 'FEATURE.LIST includes this group');
    is($kv->feature->drop($group), 'OK', 'FEATURE.DROP');
    my $err = eval { $kv->feature->set($group, 'user1', 'age', 1); 1 } ? undef : $@;
    ok($err, 'FEATURE.SET on a dropped group raises');
}

$kv->close;
done_testing();
