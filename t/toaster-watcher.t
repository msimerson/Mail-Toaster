#!perl
use strict;
use warnings;

use Cwd;
use English qw( -no_match_vars );
use Test::More;

use lib 'lib';
use_ok('Mail::Toaster');

my $network++;
my $deprecated = 0;    # run the deprecated tests.
my $r;
my $initial_working_directory = cwd;

my $toaster = Mail::Toaster->new;
isa_ok( $toaster, 'Mail::Toaster', 'object class' );

my $clean = 1;

# only run these tests on an installed toaster
if (   !-w "/tmp"
    || !-d $toaster->conf->{qmail_dir}
    || !-d $toaster->conf->{qmail_supervise} )
{
    done_testing();
    exit;
}

# the tests can't succeed unless run as root
if ( $UID != 0 ) {
    done_testing();
    exit;
};

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

done_testing();
exit;
