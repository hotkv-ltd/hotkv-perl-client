# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# AMEM.* requires the "agent-memory" license feature; AMEM.SUMMARY.* needs
# the separate "amem-summary" feature on top of that. Without them every
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

# --- conversation memory ----------------------------------------------

{
    my $sid = unique_name('conv');
    my $ok = eval { $kv->amem->conv_create($sid, { window => 10 }); 1 };
    if (!$ok) {
        ok(is_nolicense($@), 'AMEM.CONV.CREATE without the agent-memory license raises NotLicensed')
            or diag("unexpected error: $@");
    }
    SKIP: {
        skip 'agent-memory license feature not enabled by the test server', 7 unless $ok;

        my $err = eval { $kv->amem->conv_create($sid); 1 } ? undef : $@;
        ok($err, 'AMEM.CONV.CREATE on an existing session raises');

        is($kv->amem->conv_append($sid, 'user', 'hello'), 'OK', 'AMEM.CONV.APPEND (user)');
        is($kv->amem->conv_append($sid, 'assistant', 'hi there'), 'OK', 'AMEM.CONV.APPEND (assistant)');
        my $turns = $kv->amem->conv_get($sid);
        is(scalar(@$turns), 2, 'AMEM.CONV.GET returns both turns');
        is_deeply($turns->[0], ['role', 'user', 'content', 'hello'], 'AMEM.CONV.GET turn shape is labeled, not a bare pair');

        my $window = $kv->amem->conv_window($sid, 1);
        is(scalar(@$window), 1, 'AMEM.CONV.WINDOW limits to the last n turns');
        is($window->[0][3], 'hi there', 'AMEM.CONV.WINDOW returns the most recent turn');

        is($kv->amem->conv_clear($sid), 1, 'AMEM.CONV.CLEAR');
        is(scalar(@{ $kv->amem->conv_get($sid) }), 0, 'AMEM.CONV.GET is empty after CLEAR');
        is($kv->amem->conv_drop($sid), 1, 'AMEM.CONV.DROP');
    }
}

# --- semantic memory -----------------------------------------------------

{
    my $agent = unique_name('semagent');
    my $ok = eval { $kv->amem->sem_create($agent, 3); 1 };
    if (!$ok) {
        ok(is_nolicense($@), 'AMEM.SEM.CREATE without the agent-memory license raises NotLicensed')
            or diag("unexpected error: $@");
    }
    SKIP: {
        skip 'agent-memory license feature not enabled by the test server', 6 unless $ok;

        is($kv->amem->sem_store($agent, 'fact1', 'the sky is blue', [1, 0, 0]), 'OK', 'AMEM.SEM.STORE');
        $kv->amem->sem_store($agent, 'fact2', 'grass is green', [0, 1, 0]);

        my $recalled = $kv->amem->sem_recall($agent, 1, [1, 0, 0]);
        is(scalar(@$recalled), 1, 'AMEM.SEM.RECALL respects k');
        is_deeply([$recalled->[0][0], $recalled->[0][1]], ['key', 'fact1'], 'AMEM.SEM.RECALL result shape starts with a labeled key');
        is($recalled->[0][3], 'the sky is blue', 'AMEM.SEM.RECALL returns the stored content');

        is_deeply([sort @{ $kv->amem->sem_list($agent) }], ['fact1', 'fact2'], 'AMEM.SEM.LIST');
        is($kv->amem->sem_forget($agent, 'fact2'), 1, 'AMEM.SEM.FORGET');
        is_deeply($kv->amem->sem_list($agent), ['fact1'], 'AMEM.SEM.LIST reflects the forget');

        # --- cross-memory search (also exercises the semantic store) ----------
        my $results = $kv->amem->search($agent, 3, [1, 0, 0]);
        ok(scalar(@$results) >= 1, 'AMEM.SEARCH returns at least the semantic match');
        is($results->[0][0], 'source', 'AMEM.SEARCH result shape starts with a labeled source');

        $kv->amem->sem_forget($agent, 'fact1');
    }
}

# --- working memory --------------------------------------------------------

{
    my $sid = unique_name('work');
    my $ok = eval { $kv->amem->work_set($sid, 'k1', 'v1'); 1 };
    if (!$ok) {
        ok(is_nolicense($@), 'AMEM.WORK.SET without the agent-memory license raises NotLicensed')
            or diag("unexpected error: $@");
    }
    SKIP: {
        skip 'agent-memory license feature not enabled by the test server', 5 unless $ok;

        is($kv->amem->work_get($sid, 'k1'), 'v1', 'AMEM.WORK.GET');
        is($kv->amem->work_get($sid, 'missing'), undef, 'AMEM.WORK.GET on a missing key is nil');
        is_deeply($kv->amem->work_list($sid), ['k1'], 'AMEM.WORK.LIST');
        is($kv->amem->work_del($sid, 'k1'), 1, 'AMEM.WORK.DEL');
        $kv->amem->work_set($sid, 'k2', 'v2');
        is($kv->amem->work_clear($sid), 1, 'AMEM.WORK.CLEAR');
    }
}

# --- episodic memory ---------------------------------------------------

{
    my $agent = unique_name('episagent');
    my $ok = eval { $kv->amem->epis_log($agent, 'note', 'did something', { metadata => '{"x":1}' }); 1 };
    if (!$ok) {
        ok(is_nolicense($@), 'AMEM.EPIS.LOG without the agent-memory license raises NotLicensed')
            or diag("unexpected error: $@");
    }
    SKIP: {
        skip 'agent-memory license feature not enabled by the test server', 5 unless $ok;

        $kv->amem->epis_log($agent, 'note', 'did another thing');

        my $events = $kv->amem->epis_query($agent);
        is(scalar(@$events), 2, 'AMEM.EPIS.QUERY with no filters returns everything logged');
        is_deeply([@{ $events->[0] }[0, 1]], ['type', 'note'], 'AMEM.EPIS.QUERY event shape starts with a labeled type');

        my $filtered = $kv->amem->epis_query($agent, { type => 'note', limit => 1 });
        is(scalar(@$filtered), 1, 'AMEM.EPIS.QUERY LIMIT is honored');

        my $stats = $kv->amem->epis_stats($agent);
        my %stats_h = @$stats;
        is($stats_h{total_events}, 2, 'AMEM.EPIS.STATS total_events');

        is($kv->amem->epis_clear($agent), 1, 'AMEM.EPIS.CLEAR');
    }
}

# --- summary (requires the separate amem-summary license feature) --------

{
    my $agent = unique_name('sumagent');
    my $ok = eval { $kv->amem->summary_set($agent, 'a running summary'); 1 };
    SKIP: {
        skip 'AMEM.SUMMARY requires the amem-summary license feature (not enabled on this server)', 5 unless $ok;
        is($kv->amem->summary_get($agent)->[0], 'a running summary', 'AMEM.SUMMARY.GET');
        is($kv->amem->summary_append($agent, ' plus more'), 2, 'AMEM.SUMMARY.APPEND bumps the version');
        ok((grep { $_ eq $agent } @{ $kv->amem->summary_list }) == 1, 'AMEM.SUMMARY.LIST');
        is($kv->amem->summary_drop($agent), 1, 'AMEM.SUMMARY.DROP');
        is($kv->amem->summary_get($agent), undef, 'AMEM.SUMMARY.GET after DROP is nil');
    }
    if (!$ok) {
        ok(is_nolicense($@), 'AMEM.SUMMARY.SET without the license feature raises NotLicensed')
            or diag("unexpected error: $@");
    }
}

$kv->close;
done_testing();
