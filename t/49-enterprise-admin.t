# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# TENANT.*, IAM.*, AUDIT.*, ENCRYPTION.*, REPLICATION.* and FEATURE.SETAT
# against a licensed server. The state changing calls only touch objects
# this test creates (a tenant, a role) and are undone at the end. Without
# the license every call raises NotLicensed, which is the assertion.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use HotKVTestUtil qw(test_url safe_name is_nolicense);

plan skip_all => 'set HOTKV_TEST_URL to run integration tests' unless test_url();

use HotKV;

my $kv = HotKV->new(url => test_url());

# --- tenancy -----------------------------------------------------------------

{
    my $id = safe_name('tenant');
    my $ok = eval { $kv->tenant->create($id, 'acme', { max_keys => 1000, max_memory => 1_048_576 }); 1 };
    if (!$ok) {
        ok(is_nolicense($@), 'TENANT.CREATE without the tenancy license raises NotLicensed') or diag($@);
    }
    SKIP: {
        skip 'tenancy license feature not enabled on the test server', 12 unless $ok;
        ok((grep { $_ eq $id } @{ $kv->tenant->list }) == 1, 'TENANT.LIST');
        my $info = $kv->tenant->info($id);
        is(ref($info), 'HASH', 'TENANT.INFO is a hashref');
        is($info->{id}, $id, 'TENANT.INFO id');
        is($info->{name}, 'acme', 'TENANT.INFO name');
        is($info->{state}, 'active', 'TENANT.INFO state');
        my $stats = $kv->tenant->stats($id);
        is($stats->{key_limit}, 1000, 'TENANT.STATS key_limit from MAX_KEYS');
        is($stats->{memory_limit}, 1_048_576, 'TENANT.STATS memory_limit from MAX_MEMORY');
        is($kv->tenant->suspend($id), 'OK', 'TENANT.SUSPEND');
        is($kv->tenant->info($id)->{state}, 'suspended', 'the tenant is suspended');
        is($kv->tenant->resume($id), 'OK', 'TENANT.RESUME');
        is($kv->tenant->bind($id, 'sdk_nobody'), 'OK', 'TENANT.BIND');
        is($kv->tenant->unbind($id, 'sdk_nobody'), 1, 'TENANT.UNBIND');
        $kv->tenant->drop($id);
    }
}

# --- IAM ---------------------------------------------------------------------

{
    my $role = safe_name('role');
    my $ok = eval { $kv->iam->role_create($role, 'read,write', { key_prefixes => ['a:', 'b:'], rate_limit => 100 }); 1 };
    if (!$ok) {
        ok(is_nolicense($@), 'IAM.ROLE.CREATE without the iam license raises NotLicensed') or diag($@);
    }
    SKIP: {
        skip 'iam license feature not enabled on the test server', 11 unless $ok;
        ok((grep { $_ eq $role } @{ $kv->iam->role_list }) == 1, 'IAM.ROLE.LIST');
        my $info = $kv->iam->role_info($role);
        is($info->{name}, $role, 'IAM.ROLE.INFO name');
        is($info->{permissions}, 'read,write', 'IAM.ROLE.INFO permissions');
        is($info->{rate_limit}, 100, 'IAM.ROLE.INFO rate_limit');
        is($kv->iam->user_assign('sdk_nobody', $role), 'OK', 'IAM.USER.ASSIGN');
        my $sid = eval { $kv->iam->auth('local', 'sdk_nobody', 'sdk-test-password') };
        SKIP: {
            skip 'IAM.AUTH did not open a session for the test user', 4 unless defined $sid;
            like($sid, qr/\A\d+\z/, 'IAM.AUTH returns an integer session id');
            my $sessions = $kv->iam->session_list;
            is(ref($sessions), 'ARRAY', 'IAM.SESSION.LIST is an arrayref');
            ok((grep { ($_->{username} // '') eq 'sdk_nobody' } @$sessions) >= 1, 'the new session is listed with its username');
            my $killed = eval { $kv->iam->session_kill($sid) };
            ok(defined $killed, 'IAM.SESSION.KILL answers') or diag($@);
        }
        is($kv->iam->role_delete($role), 1, 'IAM.ROLE.DELETE');
        my $gone = eval { $kv->iam->role_info($role) };
        ok((ref($gone) eq 'HASH' && !$gone->{permissions}) || (ref($@) && $@->isa('HotKV::Error::Server')),
            'IAM.ROLE.INFO of a deleted role has no permissions (or is an error)');
    }
}

# --- audit -------------------------------------------------------------------

{
    my $info = eval { $kv->audit->info };
    if (!$info) {
        ok(is_nolicense($@), 'AUDIT.INFO without the audit license raises NotLicensed') or diag($@);
    }
    SKIP: {
        skip 'audit license feature not enabled on the test server', 6 unless $info;
        is(ref($info), 'HASH', 'AUDIT.INFO is a hashref');
        ok(exists $info->{total_entries} && exists $info->{chain_valid} && exists $info->{last_sequence}, 'AUDIT.INFO fields');
        is($info->{chain_valid}, 1, 'the chain is valid');
        like($kv->audit->verify, qr/\AOK/, 'AUDIT.VERIFY');
        my $file = 'perl-sdk-audit-' . $$ . '.csv';
        is($kv->audit->export($file, { format => 'csv' }), 'OK', 'AUDIT.EXPORT FORMAT csv');
        unlink $file;    # the server wrote it; this removes it when the server shares our directory
        # With auditing switched off the server cannot rotate; either answer reaches the server.
        my $rot = eval { $kv->audit->rotate };
        ok(defined $rot || (ref($@) && $@->isa('HotKV::Error::Server')), 'AUDIT.ROTATE answers (OK, or a server error when auditing is off)');
    }
}

# --- encryption --------------------------------------------------------------

{
    my $info = eval { $kv->encryption->info };
    if (!$info) {
        ok(is_nolicense($@), 'ENCRYPTION.INFO without the encryption license raises NotLicensed') or diag($@);
    }
    SKIP: {
        skip 'encryption license feature not enabled on the test server', 4 unless $info;
        is(ref($info), 'HASH', 'ENCRYPTION.INFO is a hashref');
        is($info->{algorithm}, 'AES-256-GCM', 'ENCRYPTION.INFO algorithm');
        ok(exists $info->{enabled} && exists $info->{provider}, 'ENCRYPTION.INFO enabled and provider');
        is($kv->encryption->verify('/nonexistent/perl-sdk-file'), 0, 'ENCRYPTION.VERIFY of a missing file is 0');
    }
}

# --- replication -------------------------------------------------------------

{
    my $info = eval { $kv->replication->info };
    if (!$info) {
        ok(is_nolicense($@), 'REPLICATION.INFO without the replication license raises NotLicensed') or diag($@);
    }
    SKIP: {
        skip 'replication license feature not enabled on the test server', 6 unless $info;
        is(ref($info), 'HASH', 'REPLICATION.INFO is a hashref');
        ok(exists $info->{role} && exists $info->{repl_offset} && exists $info->{connected_replicas}, 'REPLICATION.INFO fields');
        is($kv->replication->pause, 'OK', 'REPLICATION.PAUSE');
        is($kv->replication->resume, 'OK', 'REPLICATION.RESUME');
        if ($info->{role} eq 'primary' || $info->{role} eq 'master') {
            my $err = eval { $kv->replication->failover; 1 } ? undef : $@;
            ok($err && $err->isa('HotKV::Error::Server') && $err->message =~ /not a replica/, 'REPLICATION.FAILOVER on a primary is refused');
        }
        else {
            pass('this server is a replica: REPLICATION.FAILOVER is not exercised');
        }
        is($kv->replication->info->{state}, $info->{state}, 'the state is unchanged after PAUSE and RESUME');
    }
}

# --- FEATURE.SETAT -----------------------------------------------------------

{
    my $group = safe_name('featsetat');
    my $ok = eval { $kv->feature->create($group, 'setat test', ['age', 'int64']); 1 };
    if (!$ok) {
        ok(is_nolicense($@), 'FEATURE.CREATE without the feature-store license raises NotLicensed') or diag($@);
    }
    SKIP: {
        skip 'feature-store license feature not enabled on the test server', 3 unless $ok;
        my $ts = (time - 3600) * 1000;
        is($kv->feature->setat($group, 'u1', $ts, 'age', 31), 'OK', 'FEATURE.SETAT');
        my $got = $kv->feature->get($group, 'u1', 'age');
        is_deeply($got->[0], ['age', 31], 'FEATURE.GET returns the value set with SETAT');
        is($got->[1], $ts, 'the entity is stamped with the given time');
        $kv->feature->drop($group);
    }
}

$kv->close;
done_testing();
