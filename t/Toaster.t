#!perl
use strict;
use warnings;

use Cwd;
use English qw( -no_match_vars );
use Test::More 'no_plan';

use lib 'lib';

BEGIN {
    use_ok('Mail::Toaster');
}
require_ok('Mail::Toaster');

my $toaster = Mail::Toaster->new(debug=>0);
ok( defined $toaster, 'get Mail::Toaster object' );
ok( $toaster->isa('Mail::Toaster'), 'check object class' );
ok( ref $toaster->get_config(), 'get_config');

my $util = $toaster->get_util;

# audit
$toaster->dump_audit( quiet => 1);
$toaster->audit("line one");
#$toaster->dump_audit();
$toaster->audit("line two");
$toaster->audit("line three");
$toaster->dump_audit( quiet=>1);

# find_config
ok( $toaster->find_config( file => 'services', fatal => 0 ), 
    'find_config valid' ); 

# same as above but with etcdir defined
ok( $toaster->find_config( file => 'services',
        etcdir => '/etc',
        fatal  => 0,
    ),
    'find_config valid'
);

# this one fails because etcdir is set incorrect
ok( !$toaster->find_config( file   => 'services',
        etcdir => '/ect',
        fatal  => 0
    ),
    'find_config invalid dir'
);

$toaster->dump_audit( quiet => 1 );

# this one fails because the file does not exist
ok( !$toaster->find_config( file  => 'country-bumpkins.conf', fatal => 0),
    'find_config non-existent file'
);

# parse_line 
my ( $foo, $bar ) = $toaster->parse_line( ' localhost1 = localhost, disk, da0, disk_da0 ' ); 
ok( $foo eq "localhost1", 'parse_line lead & trailing whitespace' ); 
ok( $bar eq "localhost, disk, da0, disk_da0", 'parse_line lead & trailing whitespace' ); 
 
( $foo, $bar ) = $toaster->parse_line( 'localhost1=localhost, disk, da0, disk_da0' ); 
ok( $foo eq "localhost1", 'parse_line no whitespace' ); 
ok( $bar eq "localhost, disk, da0, disk_da0", 'parse_line no whitespace' ); 

( $foo, $bar ) = $toaster->parse_line( ' htmldir = /usr/local/www/toaster ' );
ok( $foo && $bar, 'parse_line' );

( $foo, $bar )
    = $toaster->parse_line( ' hosts   = localhost lab.simerson.net seattle.simerson.net ' );
ok( $foo eq "hosts", 'parse_line' );
ok( $bar eq "localhost lab.simerson.net seattle.simerson.net", 'parse_line' );


# parse_config
# this fails because the filename is wrong
ok( !$toaster->parse_config( 
        file  => 'toaster-wacher.conf', 
        debug => 0, 
        fatal => 0 
    ), 
    'parse_config invalid filename' 
); 
 
# this fails because etcdir is set (incorrectly) 
ok( !$toaster->parse_config( 
        file   => 'toaster-watcher.conf', 
        etcdir => "/ect", 
        debug  => 0, 
        fatal  => 0 
    ), 
    'parse_config invalid filename' 
); 
 
# this works because find_config will check for -dist in the local dir
my $conf;
ok( $conf = $toaster->parse_config(
        file  => 'toaster-watcher.conf',
        debug => 0,
        fatal => 0
    ),
    'parse_config correct'
);

$toaster->dump_audit( quiet => 1 );

# check
ok( $toaster->check( debug => 0, test_ok=> 1 ), 'check' );

if ( $UID == 0 ) {

# learn_mailboxes
    if ( -d $conf->{'qmail_log_base'} ) {
        ok( $toaster->learn_mailboxes( 
            fatal => 0,
            test_ok => 1, 
        ), 'learn_mailboxes +' );

# clean_mailboxes
        ok( $toaster->clean_mailboxes( test_ok=>1, fatal => 0 ),
            'clean_mailboxes +' );
    }
    else {
        # these should fail if the toaster logs are not set up yet
        ok( ! $toaster->clean_mailboxes( fatal => 0 ),
            'clean_mailboxes -' );

        ok( ! $toaster->learn_mailboxes( 
            fatal => 0,
            test_ok => 0, 
        ), 'learn_mailboxes -' );
    }
}

# maildir_clean_spam
ok( !$toaster->maildir_clean_spam( path => '/home/domains/fake.com/user' ),
    'maildir_clean_spam'
);

# get_maildir_paths
my $qdir   = $conf->{'qmail_dir'};
my $assign = "$qdir/users/assign";
my $assign_size = -s $assign;

my $r = $toaster->get_maildir_paths( fatal => 0 );
if ( -r $assign && $assign_size > 10 ) { ok( $r, 'get_maildir_paths' );  }
else                                   { ok( !$r, 'get_maildir_paths' ); };

# build_spam_list
ok(
    !$toaster->build_spam_list( path => '/home/example.com/user' ),
    'build_spam_list'
);

# maildir_clean_trash
ok(
    !$toaster->maildir_clean_trash( path => '/home/example.com/user',),
    'maildir_clean_trash'
);

# maildir_clean_sent
ok(
    !$toaster->maildir_clean_sent( path => '/home/example.com/user',),
    'maildir_clean_sent'
);

# maildir_clean_new
ok(
    !$toaster->maildir_clean_new( path => '/home/example.com/user',),
    'maildir_clean_new'
);

# maildir_clean_ham
ok( !$toaster->maildir_clean_ham( path => '/home/example.com/user',),
        'maildir_clean_ham'
);

# build_ham_list
ok( !$toaster->build_ham_list( path => '/home/example.com/user' ),
        'build_ham_list'
);

# service_dir_create
ok( $toaster->service_dir_create( fatal => 0, test_ok => 1 ),
    'service_dir_create' );

# service_dir_test
if ( -d "/var/service" ) {
    ok( $toaster->service_dir_test(), 'service_dir_test' );
}

# supervise_dir_get 
ok ( $toaster->supervise_dir_get( prot=>"send" ), 'supervise_dir_get');


# supervise_dirs_create
ok( $toaster->supervise_dirs_create( test_ok => 1 ), 'supervise_dirs_create' );

$toaster->dump_audit(quiet => 1);

# supervised_dir_test
ok(
    $toaster->supervised_dir_test( prot => 'smtp', test_ok => 1,),
    'supervised_dir_test smtp'
);

ok(
    $toaster->supervised_dir_test( prot => 'submit', test_ok => 1,),
    'supervised_dir_test submit'
);

ok(
    $toaster->supervised_dir_test( prot => 'send', test_ok => 1,),
    'supervised_dir_test send'
);

# check_processes
ok( $toaster->check_processes( test_ok=> 1), 'check_processes' );

# email_send

# email_send_attach

# email_send_clam

# email_send_clean

# email_send_eicar

# email_send_spam

# get_toaster_htdocs
ok( $toaster->get_toaster_htdocs(), 'get_toaster_htdocs' );

# get_toaster_cgibin
ok( $toaster->get_toaster_cgibin(), 'get_toaster_cgibin' );

# supervised_do_not_edit_notice
ok( $toaster->supervised_do_not_edit_notice(),
    'supervised_do_not_edit_notice' );

$toaster->dump_audit(quiet=>1);
my $setuidgid = $util->find_bin( "setuidgid", fatal=>0, debug=>0 );
foreach ( qw/ smtpd pop3 submit / ) {

# supervised_hostname
    ok( $toaster->supervised_hostname( prot => $_ ), 
        "supervised_hostname $_" );

# supervised_multilog
    if ( $setuidgid ) {
        ok( $toaster->supervised_multilog( prot => $_, fatal=>0 ),
            "supervised_multilog $_"
        );
    };

# supervised_log_method
    ok( $toaster->supervised_log_method( prot => $_ ), 
        "supervised_log_method $_");
};


# supervise_restart
    # we do not want to try this during testing.

# supervised_tcpserver
    # this test would fail unless on a built toaster.
