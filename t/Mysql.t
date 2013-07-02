#!perl
use strict;
use warnings;

use Cwd;
use English qw( -no_match_vars );
use Test::More 'no_plan';

use lib 'lib';

use_ok 'Mail::Toaster::Mysql' ;

my $mysql = Mail::Toaster::Mysql->new;

isa_ok($mysql, 'Mail::Toaster::Mysql', 'mysql object');
ok( $mysql->db_vars(), 'db_vars');

