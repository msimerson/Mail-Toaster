#!perl
use strict;
use warnings;

use Cwd;
use English qw( -no_match_vars );
use Test::More 'no_plan';

use lib 'lib';

use_ok('Mail::Toaster::Setup::Test');

my $test = Mail::Toaster::Setup::Test->new;
isa_ok( $test, 'Mail::Toaster::Setup::Test', 'object class' );


# email_send

# email_send_attach

# email_send_clam

# email_send_clean

# email_send_eicar

# email_send_spam

