#!perl
use strict;
use warnings;

use Test::More;

eval "use Test::Pod::Coverage 1.04";
plan skip_all => "Test::Pod::Coverage 1.04 required for testing POD coverage" if $@;

# don't run these tests when distributed on CPAN
plan skip_all => "Test::Pod::Coverage disabled for CPAN release.";

all_pod_coverage_ok();
