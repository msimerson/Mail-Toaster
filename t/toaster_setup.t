
use strict;
use warnings;

use lib "lib";

use Config;
use Cwd;
use English qw( -no_match_vars );
use Test::More 'no_plan';
use Test::NoWarnings;

BEGIN { 
    use_ok( 'Mail::Toaster' );
};
require_ok( 'Mail::Toaster' );

my $toaster = Mail::Toaster->new(debug=>0);
my $util = $toaster->get_util;

my $setup_location = "bin/toaster_setup.pl";

ok( -e $setup_location, 'found toaster_setup.pl');
ok( -x $setup_location, 'is executable');

#my $wd = cwd; print "wd: $wd\n";
#ok (system "$setup_location -s test2", 'test2');

my $this_perl = `which $EXECUTABLE_NAME`; 
chomp $this_perl;
if ($OSNAME ne 'VMS')
    {$this_perl .= $Config{_exe}
        unless $this_perl =~ m/$Config{_exe}$/i;}

#use Data::Dumper; warn Dumper(@INC) and exit;
my $cmd = "$this_perl $setup_location -s test2";
ok( $util->syscmd( $cmd, fatal => 0, debug => 0 ), 'toaster_setup.pl',);

