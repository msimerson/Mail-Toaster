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

my $toaster = Mail::Toaster->new(verbose=>0);
ok( defined $toaster, 'get Mail::Toaster object' );
ok( $toaster->isa('Mail::Toaster'), 'check object class' );
my $conf = $toaster->conf();
ok( ref $conf, 'conf');

# audit
$toaster->dump_audit( quiet => 1);
$toaster->audit("line one");
#$toaster->dump_audit();
$toaster->audit("line two");
$toaster->audit("line three");
$toaster->dump_audit( quiet=>1);

# check
ok( $toaster->check( verbose => 0, test_ok=> 1 ), 'check' );

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

# service_dir_create
ok( $toaster->service_dir_create( fatal => 0, test_ok => 1 ),
    'service_dir_create' );

# service_dir_test
if ( -d "/var/service" ) {
    ok( $toaster->service_dir_test(), 'service_dir_test' );
}

# supervise_dir_get 
ok ( $toaster->supervise_dir_get( "send" ), 'supervise_dir_get');


# supervise_dirs_create
ok( $toaster->supervise_dirs_create( test_ok => 1 ), 'supervise_dirs_create' );

$toaster->dump_audit(quiet => 1);

# supervised_dir_test
ok(
    $toaster->supervised_dir_test( 'smtp', test_ok => 1,),
    'supervised_dir_test smtp'
);

ok(
    $toaster->supervised_dir_test( 'submit', test_ok => 1,),
    'supervised_dir_test submit'
);

ok(
    $toaster->supervised_dir_test( 'send', test_ok => 1,),
    'supervised_dir_test send'
);

# check_running_processes
ok( $toaster->check_running_processes( test_ok=> 1), 'check_running_processes' );


# get_toaster_htdocs
ok( $toaster->get_toaster_htdocs(), 'get_toaster_htdocs' );

# get_toaster_cgibin
ok( $toaster->get_toaster_cgibin(), 'get_toaster_cgibin' );

# supervised_do_not_edit_notice
ok( $toaster->supervised_do_not_edit_notice(),
    'supervised_do_not_edit_notice' );

$toaster->dump_audit(quiet=>1);
my $setuidgid = $toaster->util->find_bin( "setuidgid", fatal=>0, verbose=>0 );
foreach ( qw/ smtpd pop3 submit / ) {

# supervised_hostname
    ok( $toaster->supervised_hostname( $_ ), "supervised_hostname $_" );

# supervised_multilog
    if ( $setuidgid ) {
        ok( $toaster->supervised_multilog( $_, fatal=>0 ), "supervised_multilog $_");
    };

# supervised_log_method
    ok( $toaster->supervised_log_method( $_ ), "supervised_log_method $_");
};


# supervise_restart
    # we do not want to try this during testing.

# supervised_tcpserver
    # this test would fail unless on a built toaster.
