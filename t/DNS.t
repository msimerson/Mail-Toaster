use strict;
use warnings;

use Test::More 'no_plan';
use English qw( -no_match_vars );

use lib 'lib';
use Mail::Toaster;

my $toaster = Mail::Toaster->new(debug=>0);
my $util = $toaster->get_util;

BEGIN { use_ok('Mail::Toaster::DNS') }
require_ok('Mail::Toaster::DNS');

# basic OO mechanism
my $dns = Mail::Toaster::DNS->new( toaster => $toaster );
ok( defined $dns, 'new (get a Mail::Toaster::DNS object)' );
ok( $dns->isa('Mail::Toaster::DNS'), 'dns object class' );

# rbl_test_ns
my $zone = 'cbl.abuseat.org';
my $has_ns = $dns->rbl_test_ns( rbl => $zone );
if ( $has_ns ) {
    ok( $has_ns, "rbl_test_ns +, $zone" );
    my $r = $dns->rbl_test_positive_ip( rbl => $zone );
    if ( $r ) {
        ok( $r, "rbl_test_positive_ip +" );
        ok( $dns->rbl_test_negative_ip( rbl => $zone ), "rbl_test_negative_ip +" );
        ok( $dns->rbl_test( zone => $zone ), 'rbl_test +' );
    };
} else {
    $util->dump_audit();
    $util->error( "Your nameserver fails to resolve $zone. Consider installing dnscache locally.");
    $util->dump_errors();
};

# queries that should fail
$zone = 'bl.spamchop.net';
ok( !$dns->rbl_test_ns( rbl => $zone ), "rbl_test_ns -, $zone" );
ok( !$dns->rbl_test_positive_ip( rbl => $zone ), 'rbl_test_positive_ip -' );
ok( $dns->rbl_test_negative_ip( rbl => $zone ), 'rbl_test_negative_ip -' );
ok( !$dns->rbl_test( zone => $zone ), 'rbl_test -' );

# resolve
my ($ip) = $dns->resolve( record => "www.freebsd.org", type => 'A' );
ok( $ip, 'resolve A' );
ok( $dns->resolve( record => "freebsd.org", type => "NS" ), 'resolve NS' );

