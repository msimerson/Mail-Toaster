
use strict;
use warnings;

use lib 'lib';

use Config;
use Cwd;
use English qw( -no_match_vars );
use Test::More;

if ( $OSNAME =~ /cygwin|win32|windows/i ) {
    plan skip_all => "no windows support";
};

use_ok( 'Mail::Toaster' );

my $toaster = Mail::Toaster->new(verbose=>0);

my $setup_location = "bin/toaster_setup.pl";

ok( -e $setup_location, 'found toaster_setup.pl');
ok( -x $setup_location, 'is executable');

my $this_perl = $Config{'perlpath'} || $EXECUTABLE_NAME;

#use Data::Dumper; warn Dumper(@INC) and exit;
my $cmd = "$this_perl $setup_location -s test2";
ok( $toaster->util->syscmd( $cmd, fatal => 0, verbose => 0 ), "$cmd" );

done_testing();
