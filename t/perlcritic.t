#!perl

use Test::More;

eval "use Test::Perl::Critic";

Test::More::plan(
    skip_all => "Test::Perl::Critic required for testing PBP compliance",
) if $@;

#plan skip_all => "     tests are too slow! disabled.";

all_critic_ok();
