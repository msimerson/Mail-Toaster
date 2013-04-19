#!perl
use strict;
use warnings;

use English qw( -no_match_vars );
use Test::More;
use Test::NoWarnings;

use lib 'lib';
use Mail::Toaster;
my $toaster = Mail::Toaster->new(debug=>0);

if ( lc( $OSNAME ) ne "darwin" ) {
    diag "OS is not Darwin";
    done_testing(1);
    exit 0;
}

require_ok('Mail::Toaster::Darwin');

ok( Mail::Toaster::Darwin->new( toaster => $toaster ), 'new darwin object' );

done_testing();
