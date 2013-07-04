#!perl
use strict;
use warnings;

use English qw( -no_match_vars );
use Test::More;

use lib "lib";

eval "require Date::Parse";
if ( $@ ) {
	plan skip_all => "Date::Parse not installed";
}

if ( ! -w '/var/log/mail' ) {
	plan skip_all => "/var/log/mail not writable";
}

my $count_dir = "/var/log/mail/counters";
unless ( -d $count_dir ) {
	plan skip_all => "$count_dir does not existent";
};

require_ok( 'Mail::Toaster' );

my $toaster = Mail::Toaster->new;
isa_ok( $toaster, 'Mail::Toaster', 'object class' );

my $maillogs_location = "bin/maillogs";

ok( -e $maillogs_location, 'found maillogs');
ok( -x $maillogs_location, 'is executable');

my @log_types = qw( smtp send rbl imap pop3 webmail spamassassin );

foreach my $type (@log_types) {
    next if $UID != 0;
    ok( $toaster->util->syscmd( "$maillogs_location $type",
            fatal   => 0,
            verbose   => 0,
        ), "maillogs $type",
    );
}

done_testing();
exit;
