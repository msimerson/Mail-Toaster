#!/usr/bin/perl
use strict;
use warnings;

use English qw( -no_match_vars );
use Test::More;

use lib 'lib';

require_ok( 'Mail::Toaster::Qmail' );

my $qmail = Mail::Toaster::Qmail->new;
isa_ok( $qmail, 'Mail::Toaster::Qmail', 'object class' );

my $r;
my $has_net_dns;
my $conf = $qmail->conf;

# get_list_of_rwls
    $qmail->conf( { 'rwl_list.dnswl.org'=> 1} );
	$r = $qmail->get_list_of_rwls(debug=>0 );
	ok( @$r[0], 'get_list_of_rwls'); 
    $qmail->conf( $conf );

# test_each_rbl
    $r = $qmail->test_each_rbl( rbls=>$r, debug=>0, fatal=>0 );
    if ( $r ) {
        ok( @$r[0], 'test_each_rbl');
    }
    else {
        warn "test_each_rbl failed\n";
        $qmail->dump_audit();
        $qmail->dump_errors();
    };


# get_list_of_rbls
    $qmail->conf( {'rbl_bl.spamcop.net'=> 1} );
	$r = $qmail->get_list_of_rbls(debug=>0,fatal=>0 );
    # some folks have problems resolving bl.spamcop.net
    if ( $r ) {  
        cmp_ok( $r, "eq", " \\\n\t\t-r bl.spamcop.net", 'get_list_of_rbls'); 

        # test one with a sort order
        $qmail->conf(  {'rbl_bl.spamcop.net'=> 2} );
        $r = $qmail->get_list_of_rbls( debug=>0, fatal=>0 );
        cmp_ok( $r, "eq", " \\\n\t\t-r bl.spamcop.net", 'get_list_of_rbls'); 
    };

	# no enabled rbls!
    $qmail->conf( {'rbl_bl.spamcop.net'=> 0} );
	ok( ! $qmail->get_list_of_rbls( debug=>0, fatal=>0 ), 
        'get_list_of_rbls nok');
	#cmp_ok( $r, "eq", "", 'get_list_of_rbls nok');

	# ignore custom error messages
    $qmail->conf( {'rbl_bl.spamcop.net_message'=> 2} );
	$r = $qmail->get_list_of_rbls( debug=>0, fatal=>0 );
	ok( ! $r, 'get_list_of_rbls nok');


# get_list_of_rwls
    $qmail->conf( {'rwl_list.dnswl.org'=> 1} );
	$r = $qmail->get_list_of_rwls( debug=>0 );
	ok( @$r[0] eq "list.dnswl.org", 'get_list_of_rwls'); 

	# no enabled rwls!
    $qmail->conf( {'rwl_list.dnswl.org'=> 0} );
	$r = $qmail->get_list_of_rwls( debug=>0 );
	ok( ! @$r[0], 'get_list_of_rwls nok');

$qmail->dump_audit( quiet => 1 );

# service_dir_get
	# a normal smtp invocation
	ok( $qmail->toaster->service_dir_get( prot=>"smtp" ) eq "/var/service/smtp", 'service_dir_get smtp');

	# a normal invocation with a conf file shortcut
	ok( $qmail->toaster->service_dir_get( prot=>"smtp" ) eq "/var/service/smtp", 'service_dir_get smtp');

	# a normal send invocation
	ok( $qmail->toaster->service_dir_get( prot=>'send' ) eq "/var/service/send", 'service_dir_get send');

	# a normal pop3 invocation
	ok( $qmail->toaster->service_dir_get( prot=>"pop3" ) eq "/var/service/pop3", 'service_dir_get pop3');

$qmail->conf( $conf );
$qmail->dump_audit( quiet => 1 );

# _set_checkpasswd_bin
	# this test will only succeed on a fully installed toaster
    ok( $qmail->_set_checkpasswd_bin( prot=>"pop3" ), '_set_checkpasswd_bin' )
        if -d $conf->{'vpopmail_home_dir'};


# supervised_hostname_qmail
	ok( $qmail->supervised_hostname_qmail( prot=>'pop3' ), 
		'supervised_hostname_qmail' );

	# invalid type
#	ok( ! $qmail->supervised_hostname_qmail( prot=>['invalid'] ), 
#        'supervised_hostname_qmail' );


# build_pop3_run
	if ( -d $conf->{'qmail_supervise'} && -d $conf->{'vpopmail_home_dir'} ) {

		# only run these tests if vpopmail is installed
		ok( $qmail->build_pop3_run(), 'build_pop3_run');
		ok( $qmail->build_send_run(), 'build_send_run');
		ok( $qmail->build_smtp_run(), 'build_smtp_run');
        if ( $conf->{submit_enable} ) {
            ok( $qmail->build_submit_run(), 'build_submit_run');
        };
	};

# check_control
	my $qmail_dir = $conf->{'qmail_dir'} || "/var/qmail";
	my $qmail_control_dir = $qmail_dir . "/control";

	if ( -d $qmail_control_dir ) {
		ok( $qmail->check_control( dir=> $qmail_control_dir, debug=>0 ) , 'check_control' );
		ok( ! $qmail->check_control( dir=>"/should-not-exist", debug=>0 ) , 'check_control' );
	};


# check_rcpthosts
	# only run the test if the files exist
	if ( -s "$qmail_control_dir/rcpthosts" && -s $qmail_dir . '/users/assign' ) {
		ok( $qmail->check_rcpthosts, 'check_rcpthosts');
	};


# config
	# 
	ok( $qmail->config( test_ok=>1 ), 'config' );
	ok( ! $qmail->config( test_ok=>0 ), 'config' );


# control_create
	ok( $qmail->control_create( test_ok=>1 ), 'control_create' );
	ok( ! $qmail->control_create( test_ok=>0 ), 'control_create' );
	

# get_domains_from_assign
	ok( $qmail->get_domains_from_assign( test_ok=>1 ), 'get_domains_from_assign');
	ok( ! $qmail->get_domains_from_assign( test_ok=>0 ), 'get_domains_from_assign');


# install_qmail
	ok( $qmail->install_qmail( test_ok=>1 ), 'install_qmail');
	ok( ! $qmail->install_qmail( test_ok=>0 ), 'install_qmail');


# install_qmail_control_files
	ok( $qmail->install_qmail_control_files( test_ok=>1), 'install_qmail_control_files');
	ok( ! $qmail->install_qmail_control_files(test_ok=>0), 'install_qmail_control_files');


# install_qmail_groups_users
	ok( $qmail->install_qmail_groups_users( test_ok=>1), 'install_qmail_groups_users');
	ok( ! $qmail->install_qmail_groups_users( test_ok=>0), 'install_qmail_groups_users');


# install_supervise_run
	ok( $qmail->install_supervise_run( tmpfile=>'/tmp/foo', test_ok=>1 ), 'install_supervise_run');
	ok( ! $qmail->install_supervise_run( tmpfile=>'/tmp/foo', test_ok=>0 ), 'install_supervise_run');


# install_qmail_control_log_files
	ok( $qmail->install_qmail_control_log_files( test_ok=>1 ), 'install_qmail_control_log_files');
	ok( ! $qmail->install_qmail_control_log_files( test_ok=>0 ), 'install_qmail_control_log_files');


# netqmail
	ok( $qmail->netqmail( debug=>0, test_ok=>1  ), 'netqmail');
	ok( ! $qmail->netqmail( debug=>0, test_ok=>0 ), 'netqmail');


# netqmail_virgin
	ok( $qmail->netqmail_virgin( debug=>0, test_ok=>1  ), 'netqmail_virgin');
	ok( ! $qmail->netqmail_virgin( debug=>0, test_ok=>0 ), 'netqmail_virgin');

# queue_check
	if ( -d $qmail_dir ) {
		ok( $qmail->queue_check( debug=>0 ), 'queue_check');
	};

# rebuild_ssl_temp_keys
	if ( -d $qmail_control_dir ) {
		ok( $qmail->rebuild_ssl_temp_keys( debug=>0, fatal=>0, test_ok=>1 ), 'rebuild_ssl_temp_keys');
	}

# restart
    my $send = $qmail->toaster->service_dir_get( prot=>'send');
	if ( -d $send ) {
		ok( $qmail->restart( prot=>'send', test_ok=>1 ), 'restart send');
	};

	if ( $qmail->toaster->supervised_dir_test( prot=>"send", fatal=>0 ) ) {

# send_start
        ok( $qmail->send_start( test_ok=>1, debug=>0, fatal=>0 ) , 'send_start');

# send_stop
        ok( $qmail->send_stop( test_ok=>1, debug=>0, fatal=>0 ) , 'send_start');
	}

# restart
	if ( $qmail->toaster->service_dir_test( prot => 'smtp', fatal=>0 ) ) {
        if ( ! $conf->{smtpd_daemon} || $conf->{smtpd_daemon} eq 'qmail' ) {
            ok( $qmail->restart( prot=> 'smtp' ), 'restart smtp' );
        };
	};

# smtp_set_qmailqueue
	if ( -d $qmail_dir && -f "$qmail_dir/bin/qmail-queue" ) {

        $qmail->conf( { 'filtering_method' => 'smtp'} );
		ok( $qmail->smtp_set_qmailqueue(), 'smtp_set_qmailqueue');
	
        $qmail->conf( { 'filtering_method' => 'user'} );
		$conf->{'filtering_method'} = "user";
		ok( ! $qmail->smtp_set_qmailqueue(), 'smtp_set_qmailqueue');
        $qmail->conf( $conf );

# _test_smtpd_config_values
        my $sup_dir = $qmail->toaster->supervised_dir_test( prot=>"send", debug=>0,fatal=>0 );
        if ( -d $conf->{'vpopmail_home_dir'} && $sup_dir && -d $sup_dir ) {
		    ok( $qmail->_test_smtpd_config_values( test_ok=>1 ), 
		    	'_test_smtpd_config_values');
        };
	};

# _smtp_sanity_tests
	ok( $qmail->_smtp_sanity_tests(), '_smtp_sanity_tests');

done_testing();
exit;
