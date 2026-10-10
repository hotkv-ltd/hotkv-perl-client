# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

package HotKV::LLMPrice;

use strict;
use warnings;

use HotKV::Protocol;

our $VERSION = '1.0.0';

=head1 NAME

HotKV::LLMPrice - One LLMSTATS.PRICE table entry

=head1 DESCRIPTION

The reply of C<< $client->llmstats->price_get >> (and each element of
C<price_list>). Prices are USD per 1,000,000 tokens. C<source> is
C<"default"> (built in), C<"custom"> (set with C<price_set>) or
C<"unpriced"> (an unknown model: every price C<0>, not an error).

=head1 METHODS

=head2 new(%fields)

C<model>, C<source> (default C<''>), C<priced>, C<retired> (default
C<0>), C<input_usd_per_mtok>, C<output_usd_per_mtok>,
C<cache_read_usd_per_mtok>, C<cache_write_5m_usd_per_mtok>,
C<cache_write_1h_usd_per_mtok> (the five prices default to C<0>).

=cut

my @FIELDS = qw(
    model source priced retired input_usd_per_mtok output_usd_per_mtok
    cache_read_usd_per_mtok cache_write_5m_usd_per_mtok cache_write_1h_usd_per_mtok
);

# The 5 price fields' names, i.e. the bulk string decimal fields a
# LLMSTATS.PRICE GET/LIST reply needs numified by
# HotKV::Commands::Support::pairs_to_h. Kept as a package array (not a
# lexical) so callers can pass it straight through as float_keys.
our @FLOAT_FIELDS = qw(
    input_usd_per_mtok output_usd_per_mtok cache_read_usd_per_mtok
    cache_write_5m_usd_per_mtok cache_write_1h_usd_per_mtok
);

my %ZERO_FIELD = map { ($_ => 1) } ('priced', 'retired', @FLOAT_FIELDS);

sub new {
    my ($class, %args) = @_;
    my %self;
    for my $f (@FIELDS) {
        $self{$f} = exists $args{$f} && defined $args{$f} ? $args{$f} : ($ZERO_FIELD{$f} ? 0 : '');
    }
    return bless \%self, $class;
}

=head2 from_fields(\%fields)

Builds a C<HotKV::LLMPrice> from a C<{field_name =E<gt> value}> hashref
already parsed by field name (see
L<HotKV::Commands::Support/pairs_to_h>, with C<float_keys =E<gt>
\@HotKV::LLMPrice::FLOAT_FIELDS>); unknown keys are ignored, missing ones
fall back to C<new>'s own defaults above.

=cut

sub from_fields {
    my ($class, $fields) = @_;
    my %known = map { ($_ => 1) } @FIELDS;
    my %args = map { ($_ => $fields->{$_}) } grep { $known{$_} } CORE::keys %$fields;
    return $class->new(%args);
}

=head2 model / source / priced / retired / input_usd_per_mtok / output_usd_per_mtok / cache_read_usd_per_mtok / cache_write_5m_usd_per_mtok / cache_write_1h_usd_per_mtok

Plain accessors. C<priced> and C<retired> are the server's integer 0/1.

=cut

sub model                       { return $_[0]->{model}; }
sub source                      { return $_[0]->{source}; }
sub priced                      { return $_[0]->{priced}; }
sub retired                     { return $_[0]->{retired}; }
sub input_usd_per_mtok          { return $_[0]->{input_usd_per_mtok}; }
sub output_usd_per_mtok         { return $_[0]->{output_usd_per_mtok}; }
sub cache_read_usd_per_mtok     { return $_[0]->{cache_read_usd_per_mtok}; }
sub cache_write_5m_usd_per_mtok { return $_[0]->{cache_write_5m_usd_per_mtok}; }
sub cache_write_1h_usd_per_mtok { return $_[0]->{cache_write_1h_usd_per_mtok}; }

=head2 format_price($value)

Formats C<$value> as the plain decimal string C<LLMSTATS.PRICE SET>
requires: digits, optional C<.>, 1 to 6 fractional digits, no sign, no
exponent. A string that already matches that grammar is passed through
unchanged (the caller's own decimal string); anything else is treated as
a number and formatted to 6 decimals with trailing zeros (and a bare
trailing C<.>) trimmed, C<0> if that leaves nothing.

=cut

sub format_price {
    my ($class, $value) = @_;
    $value = 0 unless defined $value && length $value;
    return HotKV::Protocol::format_usd($value);
}

1;
