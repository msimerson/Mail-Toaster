use strict;
use warnings;

use Test::More;
use English qw( -no_match_vars );

use lib 'lib';

use_ok('Mail::Toaster::DNS');
my $dns = Mail::Toaster::DNS->new;
isa_ok( $dns, 'Mail::Toaster::DNS', 'dns object class' );

# rbl_test_ns
my $zone = 'spamcop.net';
my $has_ns = $dns->rbl_test_ns( rbl => $zone );
if ( ! $has_ns ) {
    $dns->dump_audit();
    $dns->error( "Your nameserver fails to resolve $zone. Consider installing dnscache locally.");
    done_testing();
    exit;
};

ok( $has_ns, "rbl_test_ns +, $zone" );
my $r = $dns->rbl_test_positive_ip( rbl => $zone );
if ( $r ) {
    ok( $r, "rbl_test_positive_ip +" );
    ok( $dns->rbl_test_negative_ip( rbl => $zone ), "rbl_test_negative_ip +" );
    ok( $dns->rbl_test( zone => $zone ), 'rbl_test +' );
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

done_testing();
exit;
