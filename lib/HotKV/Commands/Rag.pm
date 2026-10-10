# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::Commands::Rag;

use strict;
use warnings;

use HotKV::Protocol;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::Commands::Rag - RAG.* retrieval-augmented generation pipeline

Needs a server license that includes the C<rag-pipeline> feature.
Reachable as C<< $client->rag >>.

=head2 create($name, $dimensions, \%opts)

C<RAG.CREATE name dimensions [STRATEGY fixed|sentence|paragraph]
[CHUNK_SIZE n] [CHUNK_OVERLAP n]> -> C<OK>. opts: C<strategy>
(C<fixed_size> is accepted by the server as a synonym for C<fixed>),
C<chunk_size>, C<chunk_overlap>.

=head2 ingest($pipeline, $doc_id, $text, \%opts)

C<RAG.INGEST pipeline doc_id text [META k1 v1 ...] [VECTORS vec1 vec2 ...]>
-> integer, chunks ingested. opts: C<meta> (flat arrayref of key/value
pairs), C<vectors> (arrayref with one entry per chunk produced from
C<$text>; each entry is either an arrayref of numbers, joined with commas
for you, or an already comma-joined string).

=head2 search($pipeline, $query_text, \%opts)

C<RAG.SEARCH pipeline query_text [K n] [ALPHA f] [VECTOR v1,v2,...]
[FILTER k1 v1 ...]> -> arrayref of results, each a flat array of
C<6 + 2*meta_count> elements: C<chunk_id, doc_id, text, score, vector_score,
bm25_score, meta_key, meta_value, ...>. opts: C<k> (default 5 server side),
C<alpha> (default 0.5), C<vector> (arrayref of numbers, joined for you, or
a string), C<filter> (flat arrayref of key/value pairs).

=head2 stats($pipeline)

C<RAG.STATS pipeline> -> flat array of 9 pairs: name, dimensions,
totalDocs, totalChunks, totalIngested, totalQueries, chunkSize,
chunkStrategy, chunkOverlap.

=head2 drop($pipeline)

C<RAG.DROP pipeline> -> C<OK>.

=head2 list

C<RAG.LIST> -> arrayref of pipeline names.

=cut

sub new { my ($class, $ex) = @_; return bless { ex => $ex }, $class; }
sub _opts { my ($a) = @_; return (@$a && ref($a->[-1]) eq 'HASH') ? pop(@$a) : {}; }
sub _joinvec { my ($v) = @_; return ref($v) eq 'ARRAY' ? join(',', map { HotKV::Protocol::format_number($_) } @$v) : $v; }

sub create {
    my ($self, $name, $dims, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('RAG.CREATE', $name, $dims);
    push @args, 'STRATEGY', $opts->{strategy} if defined $opts->{strategy};
    push @args, 'CHUNK_SIZE', $opts->{chunk_size} if defined $opts->{chunk_size};
    push @args, 'CHUNK_OVERLAP', $opts->{chunk_overlap} if defined $opts->{chunk_overlap};
    return $self->{ex}->_call(@args);
}

sub ingest {
    my ($self, $pipeline, $doc_id, $text, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('RAG.INGEST', $pipeline, $doc_id, $text);
    push @args, 'META', @{ $opts->{meta} } if $opts->{meta} && @{ $opts->{meta} };
    push @args, 'VECTORS', map { _joinvec($_) } @{ $opts->{vectors} } if $opts->{vectors} && @{ $opts->{vectors} };
    return $self->{ex}->_call(@args);
}

sub search {
    my ($self, $pipeline, $query_text, @rest) = @_;
    my $opts = _opts(\@rest);
    my @args = ('RAG.SEARCH', $pipeline, $query_text);
    push @args, 'K', $opts->{k} if defined $opts->{k};
    push @args, 'ALPHA', $opts->{alpha} if defined $opts->{alpha};
    push @args, 'VECTOR', _joinvec($opts->{vector}) if defined $opts->{vector};
    push @args, 'FILTER', @{ $opts->{filter} } if $opts->{filter} && @{ $opts->{filter} };
    return $self->{ex}->_call(@args);
}

sub stats { my ($self, $pipeline) = @_; return $self->{ex}->_call('RAG.STATS', $pipeline); }
sub drop  { my ($self, $pipeline) = @_; return $self->{ex}->_call('RAG.DROP', $pipeline); }
sub list  { my ($self) = @_; return $self->{ex}->_call('RAG.LIST'); }

1;
