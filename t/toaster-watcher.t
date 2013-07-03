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

use_ok('Mail::Toaster');

my $toaster = Mail::Toaster->new(verbose=>0);
ok( defined $toaster, 'get Mail::Toaster object' );
isa_ok( $toaster, 'Mail::Toaster', 'object class' );

my $clean = 1;

# only run these tests on installed toasters
if (   !-w "/tmp"
    || !-d $toaster->conf->{'qmail_dir'}
    || !-d $toaster->conf->{'qmail_supervise'} )
{
    exit 0;
}

$r = $toaster->qmail->build_pop3_run();
ok( $r, 'build_pop3_run' ) if $r;

$r = $toaster->qmail->build_submit_run();
ok( $r, 'build_submit_run' ) if $r;

$r = $toaster->qmail->build_send_run();
ok( $r, 'build_send_run' ) if $r;

$r = $toaster->qmail->build_smtp_run();
ok( $r, 'build_smtp_run' ) if $r;

ok( $toaster->qmail->install_qmail_control_log_files( test_ok => 1 ),
    'created supervise/*/log/run'
);

ok( $toaster->setup->startup_script( test_ok=>1 ), 'startup_script' );

ok( $toaster->service_symlinks(), 'service_symlinks' );

ok( chdir($initial_working_directory), 'reset working directory' );
