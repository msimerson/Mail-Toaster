#!perl
use strict;
use warnings;

use Cwd;
use English qw( -no_match_vars );
use Test::More 'no_plan';

use lib "lib";

BEGIN { use_ok('Mail::Toaster::Mysql'); }
require_ok('Mail::Toaster::Mysql');

my $toaster = Mail::Toaster->new(debug=>0);
my $mysql = Mail::Toaster::Mysql->new('log'=>$toaster);

ok($mysql, 'mysql object');
ok( $mysql->db_vars(), 'db_vars');

