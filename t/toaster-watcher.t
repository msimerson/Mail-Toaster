#!perl
use strict;
use warnings;

use Cwd;
use English qw( -no_match_vars );
use Test::More 'no_plan';

use lib "lib";

my $network++;
my $deprecated = 0;    # run the deprecated tests.
my $r;
my $initial_working_directory = cwd;

BEGIN {
    use_ok('Mail::Toaster');
    use_ok('Mail::Toaster::Qmail');
    use_ok('Mail::Toaster::DNS');
    use_ok('Mail::Toaster::Setup');

}
require_ok('Mail::Toaster');
require_ok('Mail::Toaster::Qmail');

my $toaster = Mail::Toaster->new(debug=>0);
ok( defined $toaster, 'get Mail::Toaster object' );
ok( $toaster->isa('Mail::Toaster'), 'check object class' );

my $util  = $toaster->get_util();
my $conf  = $toaster->get_config();
my $qmail = Mail::Toaster::Qmail->new(toaster=>$toaster);
my $setup = Mail::Toaster::Setup->new(toaster=>$toaster,conf=>$conf);

my $clean = 1;

# only run these tests on installed toasters
if (   !-w "/tmp"
    || !-d $conf->{'qmail_dir'}
    || !-d $conf->{'qmail_supervise'} )
{
    exit 0;
}

$r = $qmail->build_pop3_run();
ok( $r, 'build_pop3_run' ) if $r;

$r = $qmail->build_submit_run();
ok( $r, 'build_submit_run' ) if $r;

$r = $qmail->build_send_run();
ok( $r, 'build_send_run' ) if $r;

$r = $qmail->build_smtp_run();
ok( $r, 'build_smtp_run' ) if $r;

ok( $qmail->install_qmail_control_log_files( test_ok => 1 ),
    'created supervise/*/log/run'
);

ok( $setup->startup_script( test_ok=>1 ), 'startup_script' );

ok( $toaster->service_symlinks(), 'service_symlinks' );

ok( chdir($initial_working_directory), 'reset working directory' );
