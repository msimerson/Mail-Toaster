#!perl
use strict;
use warnings;

use Cwd;
use English qw( -no_match_vars );
use Test::More;

use lib 'lib';

my $mod = 'Mail::Toaster::Base';
use_ok($mod);
my $base = $mod->new;
isa_ok( $base, $mod );

my $util = $base->util;
isa_ok( $util, 'Mail::Toaster::Utility' );

ok( ! $base->verbose, "verbose, unset" );
ok( $base->verbose(1), "verbose, set");
ok( $base->verbose, "verbose, get" );

done_testing();
exit;
