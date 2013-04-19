#!perl
use strict;
#use warnings;

use lib "lib";

use Config;
use English qw( -no_match_vars );
use Test::More 'no_plan';

require_ok( 'Mail::Toaster' );

my $toaster = Mail::Toaster->new(debug=>0);
ok ( defined $toaster, 'Mail::Toaster object' );
ok ( $toaster->isa('Mail::Toaster'), 'check object class' );

my $conf = $toaster->get_config;
my $util = $toaster->get_util;

my $qqtool_location = "bin/qqtool.pl";

ok( -e $qqtool_location, 'found qqtool.pl');
ok( -x $qqtool_location, 'is executable');

my $queue = $conf->{'qmail_dir'} . "/queue";

### $queue
### require: -d $queue
### require: -r $queue

my $this_perl = `which $EXECUTABLE_NAME`;
chomp $this_perl;
if ($OSNAME ne 'VMS')
    {$this_perl .= $Config{_exe}
        unless $this_perl =~ m/$Config{_exe}$/i;}

ok( $util->syscmd( "$this_perl $qqtool_location -a list -s matt -h From ",
        fatal   => 0,
        debug   => 0,
    ), 'qqtool.pl' );
