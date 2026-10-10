# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::AI::SemanticCache;

use strict;
use warnings;

use HotKV::TokenUsage;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::AI::SemanticCache - Nearest-neighbor LLM answer caching helper

=head1 SYNOPSIS

  my $cache = HotKV::AI::SemanticCache->new(client => $kv, ns => 'faq-v1');
  $cache->create(384, { threshold => 0.86 });

  my $result = $cache->get_or_call(
      query  => 'how do I reset my password',
      vector => $embed->('how do I reset my password'),  # any embedding provider
      call   => sub { my_llm_call(...) },                # only runs on a miss
  );
  print $result->{cached} ? "cache hit ($result->{similarity})\n" : "miss\n";
  print $result->{response}, "\n";

=head1 DESCRIPTION

Wraps L<HotKV::Commands::SemanticCache> (C<SCACHE.*>, on the
C<< $client->scache >> accessor). The caller supplies the embedding vector
for each query (this SDK has no dependency on, and no opinion about, any
particular embedding provider); the helper looks up the nearest cached
answer above the configured similarity threshold and, on a miss, stores the
new answer next to its vector for future lookups.

=head1 METHODS

=head2 new(%opts)

C<client> (required), C<ns> (required: the C<SCACHE> namespace).

=cut

sub new {
    my ($class, %opts) = @_;
    die "hotkv: HotKV::AI::SemanticCache needs client => ...\n" unless $opts{client};
    die "hotkv: HotKV::AI::SemanticCache needs ns => ...\n" unless defined $opts{ns} && length $opts{ns};
    return bless { client => $opts{client}, ns => $opts{ns} }, $class;
}

=head2 create($dims, \%opts)

Convenience passthrough to C<< $client->scache->create($ns, $dims, \%opts) >>.
opts: C<metric>, C<threshold>, C<ttl>.

=cut

sub create {
    my ($self, $dims, @rest) = @_;
    return $self->{client}->scache->create($self->{ns}, $dims, @rest);
}

=head2 get_or_call(%args)

C<query> (the raw query text, stored alongside the answer for a miss so it
can be inspected later; not used for matching), C<vector> (required
arrayref: the query's embedding), C<call> (required coderef, invoked with
no arguments only on a miss; it may return a plain scalar (the response
text) or a hashref C<{ response, model, input_tokens, output_tokens,
cached_tokens, cache_write_5m_tokens, cache_write_1h_tokens }>: only
C<response> is required, and when C<model> is also given, a
L<HotKV::TokenUsage> is built from these fields (C<cached_tokens> becomes
its C<cache_read_tokens>) and stored with the cache entry, so a later hit
attributes it, and its cost once the model is priced, through C<stats>'s
C<usage_saved_*> counters), C<threshold> (optional override for this
lookup only), C<ttl> (optional seconds, forwarded to C<SCACHE.SET> on a
miss).

Returns C<{ response, cached, similarity }>: C<cached> is 1 on a hit (with
C<similarity> from the server) or 0 on a miss (C<similarity> is C<undef>).

=cut

sub get_or_call {
    my ($self, %args) = @_;
    my $query     = $args{query};
    my $vector    = $args{vector};
    my $fn        = $args{call};
    my $threshold = $args{threshold};
    my $ttl       = $args{ttl};
    die "hotkv: get_or_call needs vector => [...]\n" unless ref $vector eq 'ARRAY';
    die "hotkv: get_or_call needs call => sub { ... }\n" unless ref $fn eq 'CODE';

    my %get_opts;
    $get_opts{threshold} = $threshold if defined $threshold;
    my $hit = $self->{client}->scache->get($self->{ns}, $vector, \%get_opts);
    if (defined $hit) {
        return { response => $hit->[0], cached => 1, similarity => $hit->[1] };
    }

    my $result = $fn->();
    my ($response, $fields);
    if (ref($result) eq 'HASH' && exists $result->{response}) {
        $response = $result->{response};
        $fields   = $result;
    }
    else {
        $response = $result;
        $fields   = {};
    }

    my $token_usage;
    if (defined $fields->{model}) {
        $token_usage = HotKV::TokenUsage->new(
            model                 => $fields->{model},
            input_tokens          => $fields->{input_tokens}          // 0,
            output_tokens         => $fields->{output_tokens}         // 0,
            cache_read_tokens     => $fields->{cached_tokens}         // 0,
            cache_write_5m_tokens => $fields->{cache_write_5m_tokens} // 0,
            cache_write_1h_tokens => $fields->{cache_write_1h_tokens} // 0,
        );
    }

    my %set_opts;
    $set_opts{ttl}   = $ttl         if defined $ttl;
    $set_opts{usage} = $token_usage if $token_usage;
    $self->{client}->scache->set($self->{ns}, (defined $query ? $query : ''), $response, $vector, \%set_opts);

    return { response => $response, cached => 0, similarity => undef };
}

1;
