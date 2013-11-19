#!perl
use strict;
use warnings;

use Cwd;
use English qw( -no_match_vars );
use Test::More;

use lib 'lib';

my $mod = 'Mail::Toaster::Base';
use_ok($mod);
my $base = $mod->new;
isa_ok( $base, $mod );

my $util = $base->util;
isa_ok( $util, 'Mail::Toaster::Utility' );

ok( ! $base->verbose, "verbose, unset" );

ok( $base->audit("test message 1"), "audit");
ok( $base->dump_audit, "dump_audit");

ok( $base->verbose(1), "verbose, set");
ok( $base->verbose, "verbose, get" );

ok( $base->audit("test message 2"), "audit");
ok( $base->dump_audit, "dump_audit");

ok( ! $base->error("test error 1", fatal=>0), "error");
ok( $base->dump_errors, "dump_errors");

done_testing();
exit;
