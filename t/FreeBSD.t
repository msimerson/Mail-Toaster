use strict;
use warnings;

use English qw( -no_match_vars );
use Test::More;

use lib 'lib';
use lib 'inc';

if ( $OSNAME ne "freebsd" ) {
    plan skip_all => "OS is not FreeBSD";
}
else {
    plan 'no_plan';
};

require_ok( 'Mail::Toaster' );
require_ok( 'Mail::Toaster::FreeBSD' );

my $toaster = Mail::Toaster->new(debug=>0);
my $freebsd = Mail::Toaster::FreeBSD->new(toaster=>$toaster);
ok ( defined $freebsd, 'Mail::Toaster::FreeBSD is an object' );
ok ( $freebsd->isa('Mail::Toaster::FreeBSD'), 'check object class' );


my $conf = $toaster->get_config;
my $util = $toaster->get_util;

# drive_spin_down
	# how exactly do I test this? 
		# a) check for SCSI disks, 
		# b) see if there is more than one
    ok ( $freebsd->drive_spin_down( drive=>"0:1:0", test_ok=>1, debug=>0), 'drive_spin_down');
    ok ( ! $freebsd->drive_spin_down( drive=>"0:1:0", test_ok=>0, debug=>0), 'drive_spin_down');



# get_port_category
    my @ports = qw/ openssl p5-Net-DNS qmail gdbm /;
    foreach ( @ports ) {
        my $r = $freebsd->get_port_category($_);
        ok( $r && -d "/usr/ports/$r/$_", "get_port_category, $_, $r" );
    };
    

# get_version
    ok ( $freebsd->get_version(), 'get_version');
    my $os_ver = `/usr/bin/uname -r`; chomp $os_ver;
    cmp_ok ( $os_ver, "eq", $freebsd->get_version(0), 'get_version');


# is_port_installed
	ok ( $freebsd->is_port_installed( "perl", 
            debug => 0, 
            fatal => 0,
            test_ok=> 1,
        ), 'is_port_installed');


# install_portupgrade
    ok ( $freebsd->install_portupgrade( test_ok=>1, fatal=>0 ), 'install_portupgrade');


# package_install
	ok ( $freebsd->package_install( 
            port=>"perl", 
            debug=>0,
            fatal=>0,
            test_ok=>1,
       ), 'package_install');


# install_port
	ok ( $freebsd->install_port( "perl", 
	    dir   => 'perl5.8', 
        fatal => 0,
	    test_ok=> 1, 
	), 'install_port');


# port_options
    ok ( $freebsd->port_options(
        port => 'p5-Tar-Diff',
        opts => 'blah,test,deleteme\n',
        test_ok=>1,
    ), 'port_options');


# ports_update
    ok ( $freebsd->ports_update(
            debug=>0,
            fatal=>0,
            test_ok=>1,
        ), 'ports_update');


# portsnap
    ok ( $freebsd->portsnap(
            debug=>0,
            fatal=>0,
            test_ok=>1,
        ), 'portsnap');


# conf_check
	ok ( $freebsd->conf_check(
	    check => "hostname", 
	    line  => "hostname='mail.example.com'",
        fatal => 0,
        test_ok => 1,
	), 'conf_check' );


