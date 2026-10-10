# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# PROMPT.* (versioned prompt/template registry) requires the
# "prompt-registry" license feature. See t/32-pcache.t for why NOLICENSE detection is itself the assertion.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url unique_name is_nolicense);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();

use HotKV;

my $kv = HotKV->new(url => test_url());
my $name = unique_name('prompt');

my $ok = eval { $kv->prompt->put($name, 'You are a helpful assistant.'); 1 };
if (!$ok) {
    ok(is_nolicense($@), 'PROMPT.PUT without the prompt-registry license raises NotLicensed')
        or diag("unexpected error: $@");
}

SKIP: {
    skip 'prompt-registry license feature not enabled by the test server', 9 unless $ok;

    my $v2 = $kv->prompt->put($name, 'You are an even more helpful assistant.', { meta => '{"author":"test"}' });
    is($v2, 2, 'PROMPT.PUT a second version bumps the version number');

    my $latest = $kv->prompt->get($name);
    is($latest->[0], 2, 'PROMPT.GET with no version returns the latest');
    is($latest->[1], 'You are an even more helpful assistant.', 'PROMPT.GET latest content');

    my $v1 = $kv->prompt->get($name, 1);
    is($v1->[1], 'You are a helpful assistant.', 'PROMPT.GET an explicit older version');

    is_deeply($kv->prompt->latest($name), $latest, 'PROMPT.LATEST matches PROMPT.GET with no version');
    is_deeply($kv->prompt->versions($name), [1, 2], 'PROMPT.VERSIONS lists both versions');
    is($kv->prompt->setactive($name, 1), 'OK', 'PROMPT.SETACTIVE');
    ok((grep { $_ eq $name } @{ $kv->prompt->list }) == 1, 'PROMPT.LIST');
    is($kv->prompt->drop($name), 1, 'PROMPT.DROP');
}

$kv->close;
done_testing();
