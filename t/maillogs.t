#!perl
use strict;
use warnings;

use English qw( -no_match_vars );
use Test::More;
use Test::NoWarnings;

use lib "lib";

my $mod = "Date::Parse";
unless (eval "require $mod" )
{
    diag( "skipping tests, Date::Parse not installed yet");
    done_testing(1);
    exit 0;
}
unless (-w "/var/log/mail")
{
	diag "skipping tests, /var/log/mail not writable";
    done_testing(1);
    exit 0;
}

require_ok( 'Mail::Toaster' );

my $toaster = Mail::Toaster->new(debug=>0);
ok ( defined $toaster, 'Mail::Toaster object' );
ok ( $toaster->isa('Mail::Toaster'), 'check object class' );

my $util = $toaster->get_util;

my $maillogs_location = "bin/maillogs";

ok( -e $maillogs_location, 'found maillogs');
ok( -x $maillogs_location, 'is executable');

unless ( -d "/var/log/mail/counters" &&
         -s "/var/log/mail/counters/webmail.txt" ) {
    exit;
};


my @log_types = qw( smtp send rbl imap pop3 webmail spamassassin );

foreach my $type (@log_types) {
    if ( $UID == 0 ) {
        ok( $util->syscmd( "$maillogs_location $type",
                fatal   => 0,
                debug   => 0,
            ), "maillogs $type",
        );
    }
    else {
        ok( ! $util->syscmd( "$maillogs_location -a list -s matt -h From ",
                fatal => 0,
                debug => 0,
            ), "maillogs $type",
        );
    }
}

done_testing();
