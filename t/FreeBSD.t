use strict;
use warnings;

use English '-no_match_vars';
use Test::More;

use lib 'lib';

if ( $OSNAME ne "freebsd" ) {
    plan skip_all => "OS is not FreeBSD";
    exit;
}

require_ok( 'Mail::Toaster::FreeBSD' );

my $freebsd = Mail::Toaster::FreeBSD->new();
isa_ok( $freebsd, 'Mail::Toaster::FreeBSD', 'check object class' );

# drive_spin_down
	# how exactly do I test this?
		# a) check for SCSI disks,
		# b) see if there is more than one
    ok ( $freebsd->drive_spin_down( drive=>"0:1:0", test_ok=>1, verbose=>0), 'drive_spin_down');
    ok ( ! $freebsd->drive_spin_down( drive=>"0:1:0", test_ok=>0, verbose=>0), 'drive_spin_down');



# get_port_category
if ( -f '/usr/ports/Makefile' ) {
    my @ports = qw/ openssl p5-Net-DNS qmail gdbm /;
    foreach ( @ports ) {
        my $r = $freebsd->get_port_category($_);
        ok( $r && -d "/usr/ports/$r/$_", "get_port_category, $_, $r" );
    };
}

# get_version
    ok ( $freebsd->get_version(), 'get_version');
    my $os_ver = `/usr/bin/uname -r`; chomp $os_ver;
    cmp_ok ( $os_ver, "eq", $freebsd->get_version(0), 'get_version');


# is_port_installed
	ok ( $freebsd->is_port_installed( "perl",
            verbose => 0,
            fatal => 0,
            test_ok=> 1,
        ), 'is_port_installed');


# install_portupgrade
    ok ( $freebsd->install_portupgrade( test_ok=>1, fatal=>0 ), 'install_portupgrade');


# install_package
	ok ( $freebsd->install_package( "perl",
            verbose=>0,
            fatal=>0,
            test_ok=>1,
       ), 'install_package');


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


# update_ports
    ok ( $freebsd->update_ports(
            verbose=>0,
            fatal=>0,
            test_ok=>1,
        ), 'update_ports');


# portsnap
    ok ( $freebsd->portsnap(
            verbose=>0,
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

done_testing();
exit;
