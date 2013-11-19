
use strict;
use warnings;

use Cwd;
use Test::More;

use lib 'lib';
use_ok('Mail::Toaster::Setup');

my $verbose = 0;
my %test_params = ( fatal => 0, verbose => $verbose );

my $setup = Mail::Toaster::Setup->new;
isa_ok( $setup, 'Mail::Toaster::Setup', 'object class' );

my $initial_working_directory = cwd;
my @subs_to_test = qw/ apache autorespond clamav courier_imap cronolog
  daemontools djbdns dovecot expat ezmlm lighttpd munin
  openssl_conf qmailadmin razor roundcube spamassassin 
  squirrelmail sqwebmail vqadmin
/;

# 3 tests per sub
foreach my $sub (@subs_to_test) {

    my $install_sub = "install_$sub";
    my $before = $setup->conf->{$install_sub};    # preserve initial settings

    $setup->conf->{$install_sub} = 1;                  # enable install in $conf

    # test to insure params and initial tests are passed
    ok(  $setup->$sub( test_ok => 1, %test_params), $sub );
    ok( !$setup->$sub( test_ok => 0, %test_params), $sub );

    $setup->conf->{$install_sub} = 0;                  # disable install

    # and then make sure it refuses to install
    ok( !$setup->$sub( %test_params ), $sub );

    # set $setup->conf->install_sub back to its initial state
    $setup->conf->{$install_sub} = $before;
}

# config
ok( $setup->config->config( test_ok => 1, %test_params ), 'config' );
ok( !$setup->config->config( test_ok => 0, %test_params ), 'config' );

# dependencies
ok( $setup->dependencies( test_ok => 1 ), 'dependencies' );
ok( !$setup->dependencies( test_ok => 0, %test_params), 'dependencies' );

#ok ( $setup->dependencies( verbose=>1 ), 'dependencies' );

# filtering
ok( $setup->filtering( test_ok => 1 ), 'filtering' );
ok( !$setup->filtering( test_ok => 0, %test_params ), 'filtering' );

# is_newer
    ok ($setup->is_newer( min=>"5.3.30", cur=>"5.3.31", verbose=>0), 'is_newer third');
    ok ($setup->is_newer( min=>"5.3.30", cur=>"5.4.30", verbose=>0), 'is_newer second');
    ok ($setup->is_newer( min=>"5.3.30", cur=>"6.3.30", verbose=>0), 'is_newer first');
    ok (! $setup->is_newer( min=>"5.3.30", cur=>"5.3.29", verbose=>0), 'is_newer third neg');
    ok (! $setup->is_newer( min=>"5.3.30", cur=>"5.2.30", verbose=>0), 'is_newer second neg');
    ok (! $setup->is_newer( min=>"5.3.30", cur=>"4.3.30", verbose=>0), 'is_newer first neg');

# nictool
ok( $setup->nictool( test_ok => 1 ), 'nictool' );
ok( !$setup->nictool( test_ok => 0, verbose => 1, fatal=>0 ), 'nictool' );

# set this back to where we started so subsequent testing scripts work
chdir($initial_working_directory);

done_testing();
