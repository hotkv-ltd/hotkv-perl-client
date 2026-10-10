# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.
#
# No server: the exact argument lists of the administrative commands that no
# integration test sends because they change global state on a server
# (ENCRYPTION.ROTATE) plus the argument order of the option
# heavy ones, checked against the grammar in the server's command reference.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";

use RecordingClient;

my $rec = RecordingClient->new;

$rec->encryption->rotate('/etc/hotkv/new.key');
is_deeply($rec->last_call, ['ENCRYPTION.ROTATE', '/etc/hotkv/new.key'], 'ENCRYPTION.ROTATE new_key_file');

$rec->tenant->create('t1', 'acme', { max_keys => 5, max_memory => 100, max_egress => 7 });
is_deeply($rec->last_call, ['TENANT.CREATE', 't1', 'acme', 'MAX_MEMORY', 100, 'MAX_KEYS', 5, 'MAX_EGRESS', 7],
    'TENANT.CREATE id name then the quota options');

$rec->iam->role_create('r', ['read', 'write'], { key_prefixes => ['a:', 'b:'], rate_limit => 10, memory_quota => 99 });
is_deeply($rec->last_call, ['IAM.ROLE.CREATE', 'r', 'read,write', 'KEY_PREFIXES', 'a:,b:', 'RATE_LIMIT', 10, 'MEMORY_QUOTA', 99],
    'IAM.ROLE.CREATE name permissions then the options');

$rec->iam->auth('oidc', 'bob', 'tok');
is_deeply($rec->last_call, ['IAM.AUTH', 'oidc', 'bob', 'tok'], 'IAM.AUTH source username credential');

$rec->audit->export('audit.csv', { format => 'csv' });
is_deeply($rec->last_call, ['AUDIT.EXPORT', 'audit.csv', 'FORMAT', 'csv'], 'AUDIT.EXPORT file FORMAT fmt');

$rec->feature->setat('g', 'e', 1700000000000, 'age', 3);
is_deeply($rec->last_call, ['FEATURE.SETAT', 'g', 'e', 1700000000000, 'age', 3], 'FEATURE.SETAT group entity ms features');

# Newer and blocking command argument order.
$rec->lmpop(['a', 'b'], 'left', { count => 2 });
is_deeply($rec->last_call, ['LMPOP', 2, 'a', 'b', 'LEFT', 'COUNT', 2], 'LMPOP numkeys keys dir COUNT');
$rec->blmpop(1.5, ['a'], 'right');
is_deeply($rec->last_call, ['BLMPOP', 1.5, 1, 'a', 'RIGHT'], 'BLMPOP timeout numkeys keys dir');
$rec->bzmpop(0, ['z'], 'min', { count => 3 });
is_deeply($rec->last_call, ['BZMPOP', 0, 1, 'z', 'MIN', 'COUNT', 3], 'BZMPOP timeout numkeys keys MIN COUNT');
$rec->hgetex('h', ['f1', 'f2'], { px => 500 });
is_deeply($rec->last_call, ['HGETEX', 'h', 'PX', 500, 'FIELDS', 2, 'f1', 'f2'], 'HGETEX key PX FIELDS n fields');
$rec->hsetex('h', ['f', 'v', 'g', 'w'], { fnx => 1, exat => 99 });
is_deeply($rec->last_call, ['HSETEX', 'h', 'FNX', 'EXAT', 99, 'FIELDS', 2, 'f', 'v', 'g', 'w'], 'HSETEX key FNX EXAT FIELDS n pairs');
$rec->msetex(['a', 1, 'b', 2], { xx => 1, keepttl => 1 });
is_deeply($rec->last_call, ['MSETEX', 2, 'a', 1, 'b', 2, 'XX', 'KEEPTTL'], 'MSETEX numkeys pairs XX KEEPTTL');
$rec->set('k', 'v', { ifdeq => 'abc', get => 1 });
is_deeply($rec->last_call, ['SET', 'k', 'v', 'IFDEQ', 'abc', 'GET'], 'SET IFDEQ before GET');
$rec->delex('k', { ifne => 'x' });
is_deeply($rec->last_call, ['DELEX', 'k', 'IFNE', 'x'], 'DELEX IFNE');
$rec->lcs('a', 'b', { idx => 1, minmatchlen => 4, withmatchlen => 1 });
is_deeply($rec->last_call, ['LCS', 'a', 'b', 'IDX', 'MINMATCHLEN', 4, 'WITHMATCHLEN'], 'LCS IDX MINMATCHLEN WITHMATCHLEN');
$rec->xadd('s', '*', 'f', 'v', { maxlen => 10, idmp => ['p', 'i1'] });
is_deeply($rec->last_call, ['XADD', 's', 'MAXLEN', '=', 10, 'IDMP', 'p', 'i1', '*', 'f', 'v'], 'XADD trim then IDMP producer iid then id');
$rec->sort('l', { by => 'w_*', limit => [0, 5], get => ['#', 'o_*'], desc => 1, alpha => 1, store => 'dst' });
is_deeply($rec->last_call, ['SORT', 'l', 'BY', 'w_*', 'LIMIT', 0, 5, 'GET', '#', 'GET', 'o_*', 'DESC', 'ALPHA', 'STORE', 'dst'], 'SORT option order');
$rec->georadius('g', 1, 2, 3, 'km', { withdist => 1, count => 2, any => 1, asc => 1, store => 'd' });
is_deeply($rec->last_call, ['GEORADIUS', 'g', 1, 2, 3, 'KM', 'WITHDIST', 'COUNT', 2, 'ANY', 'ASC', 'STORE', 'd'], 'GEORADIUS option order');
$rec->bitfield('b', ['SET', 'u8', 0, 255], 'GET', 'u8', 0);
is_deeply($rec->last_call, ['BITFIELD', 'b', 'SET', 'u8', 0, 255, 'GET', 'u8', 0], 'BITFIELD flattens its sub-commands');
$rec->client_tracking(1, { redirect => 7, prefix => ['a:', 'b:'], bcast => 1, noloop => 1 });
is_deeply($rec->last_call, ['CLIENT', 'TRACKING', 'ON', 'REDIRECT', 7, 'PREFIX', 'a:', 'PREFIX', 'b:', 'BCAST', 'NOLOOP'], 'CLIENT TRACKING options');
$rec->function_restore('blob', { policy => 'flush' });
is_deeply($rec->last_call, ['FUNCTION', 'RESTORE', 'blob', 'FLUSH'], 'FUNCTION RESTORE payload policy');
$rec->fcall('f', ['k1'], ['a1', 'a2']);
is_deeply($rec->last_call, ['FCALL', 'f', 1, 'k1', 'a1', 'a2'], 'FCALL name numkeys keys args');
$rec->sflush([[0, 100], [200, 300]], { mode => 'async' });
is_deeply($rec->last_call, ['SFLUSH', 0, 100, 200, 300, 'ASYNC'], 'SFLUSH ranges then mode');
$rec->trimslots([[0, 100], [200, 300]]);
is_deeply($rec->last_call, ['TRIMSLOTS', 'RANGES', 2, 0, 100, 200, 300], 'TRIMSLOTS RANGES n pairs');
$rec->clusterscan(5, { match => 'a*', count => 10, type => 'string', slot => 3 });
is_deeply($rec->last_call, ['CLUSTERSCAN', 5, 'MATCH', 'a*', 'COUNT', 10, 'TYPE', 'string', 'SLOT', 3], 'CLUSTERSCAN options');
$rec->bf->insert('f', ['x', 'y'], { capacity => 10, error => 1e-05, nocreate => 1 });
is_deeply($rec->last_call, ['BF.INSERT', 'f', 'CAPACITY', 10, 'ERROR', '0.00001', 'NOCREATE', 'ITEMS', 'x', 'y'], 'BF.INSERT writes the error rate as plain decimal');
$rec->cms->merge('d', ['a', 'b'], [2, 1]);
is_deeply($rec->last_call, ['CMS.MERGE', 'd', 2, 'a', 'b', 'WEIGHTS', 2, 1], 'CMS.MERGE dest numkeys keys WEIGHTS');
$rec->topk->reserve('t', 3, { width => 8, depth => 7, decay => 0.9 });
is_deeply($rec->last_call, ['TOPK.RESERVE', 't', 3, 8, 7, '0.9'], 'TOPK.RESERVE key k width depth decay');

done_testing;
