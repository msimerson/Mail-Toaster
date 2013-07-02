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

done_testing();
exit;
