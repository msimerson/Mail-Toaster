#!perl
use strict;
use warnings;

use English qw( -no_match_vars );
use Test::More;

use lib "lib";

my $mod = "Date::Parse";
unless (eval "require $mod" )
{
	Test::More::plan( skip_all => "skipping tests, Date::Parse not installed yet");
}
unless (-w "/var/log/mail")
{
	Test::More::plan( skip_all => "skipping tests, /var/log/mail not writable");
}
plan 'no_plan';

require_ok( 'Mail::Toaster' );

my $toaster = Mail::Toaster->new(verbose=>0);
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
                verbose   => 0,
            ), "maillogs $type",
        );
    }
    else {
        ok( ! $util->syscmd( "$maillogs_location -a list -s matt -h From ",
                fatal => 0,
                verbose => 0,
            ), "maillogs $type",
        );
    }
}
