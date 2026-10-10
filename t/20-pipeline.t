# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url unique_name);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();

use HotKV;

my $kv = HotKV->new(url => test_url());
my $k1 = unique_name('p1');
my $k2 = unique_name('p2');

# --- basic pipelining: one round trip, results in call order ---------------

my $results = $kv->pipeline(sub {
    my $p = shift;
    $p->set($k1, 'a');
    $p->incr($k2);
    $p->incr($k2);
    $p->get($k1);
    $p->get($k2);
});
is_deeply($results, ['OK', 1, 2, 'a', '2'], 'pipeline results come back in call order');

# --- per-command errors surface without failing the whole batch ------------

$kv->set($k1, 'not-a-list');
my $mixed = $kv->pipeline(sub {
    my $p = shift;
    $p->set($k1, 'stays-a-string');
    $p->lpush($k1, 'x'); # WRONGTYPE: $k1 is a string
    $p->get($k1);
});
is($mixed->[0], 'OK', 'first command in a mixed pipeline still succeeds');
isa_ok($mixed->[1], 'HotKV::Error::Server', 'the failing command comes back as an error object, not an exception');
is($mixed->[1]->code, 'WRONGTYPE', 'the error object has the right code');
is($mixed->[2], 'stays-a-string', 'the command after the failure still ran and returned its own result');

# --- empty pipeline -----------------------------------------------------

is_deeply($kv->pipeline(sub { }), [], 'an empty pipeline returns an empty arrayref');

# --- HotKV-family commands are pipeline-able too ----------------------------

my $tag_key = unique_name('ptag');
$kv->set($tag_key, 'v');
my $tag_results = $kv->pipeline(sub {
    my $p = shift;
    $p->tag->set($tag_key, 'red');
    $p->tag->get($tag_key);
});
is($tag_results->[0], 1, 'TAG.SET pipelines correctly');
is_deeply($tag_results->[1], ['red'], 'TAG.GET pipelines correctly');

$kv->del($k1, $k2, $tag_key);
$kv->close;
done_testing();
