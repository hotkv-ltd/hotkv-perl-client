# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'HotKV',
    VERSION_FROM     => 'lib/HotKV.pm',
    ABSTRACT         => 'A high-performance Perl client for HotKV, a RESP2/RESP3-compatible in-memory data store with built-in AI and LLM-serving features.',
    AUTHOR           => 'HotKV Ltd <support@hotkv.com>',
    LICENSE          => 'apache_2_0',
    MIN_PERL_VERSION => '5.016',

    # Runtime dependencies: core modules only (bundled with Perl 5.16+).
    # IO::Socket::SSL is required only when TLS is actually requested and is
    # therefore listed under META_MERGE as a recommendation, not here.
    PREREQ_PM => {
        'B'                  => 0,
        'Carp'               => 0,
        'Digest::SHA'        => 0,
        'Encode'             => 0,
        'Errno'              => 0,
        'Exporter'           => 0,
        'IO::Select'         => 0,
        'IO::Socket::INET'   => 0,
        'IO::Socket::UNIX'   => 0,
        'Scalar::Util'       => 0,
        'Socket'             => 0,
        'Time::HiRes'        => 0,
    },
    TEST_REQUIRES => {
        'FindBin'    => 0,
        'Test::More' => 0,
    },

    test => { TESTS => 't/*.t' },
    clean => { FILES => 'HotKV-* Makefile.old' },

    META_MERGE => {
        'meta-spec' => { version => 2 },
        resources => {
            homepage   => 'https://hotkv.com',
            repository => {
                type => 'git',
                url  => 'https://github.com/hotkv-ltd/hotkv-perl-client.git',
                web  => 'https://github.com/hotkv-ltd/hotkv-perl-client',
            },
            bugtracker => {
                web => 'https://github.com/hotkv-ltd/hotkv-perl-client/issues',
            },
        },
        prereqs => {
            runtime => {
                recommends => {
                    # Only needed when connecting with tls => 1 (hotkvs://).
                    'IO::Socket::SSL' => '2.060',
                },
            },
            test => {
                recommends => {
                    # t/80 and t/25 need TLS.
                    'IO::Socket::SSL' => '2.060',
                },
            },
        },
        no_index => {
            directory => ['examples'],
        },
    },
);
