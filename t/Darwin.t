#!perl
use strict;
use warnings;

use English qw( -no_match_vars );
use Test::More;

if ( lc $OSNAME ne 'darwin' ) {
    plan skip_all => "OS is not Darwin";
}

use lib 'lib';
require Mail::Toaster::Darwin;

require_ok('Mail::Toaster::Darwin');

ok( Mail::Toaster::Darwin->new, 'new darwin object' );

done_testing();
exit;
