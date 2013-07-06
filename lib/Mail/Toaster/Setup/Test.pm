package Mail::Toaster::Setup::Test;

use strict;
use warnings;

use Carp;
use English '-no_match_vars';
use Params::Validate qw( :all );

use lib 'lib';
use parent 'Mail::Toaster::Base';

sub daemontools {
    my $self = shift;

    print "checking daemontools binaries...\n";
    my @bins = qw/ multilog softlimit setuidgid supervise svok svscan tai64nlocal /;
    foreach my $test ( @bins ) {
        my $bin = $self->util->find_bin( $test, fatal => 0, verbose=>0);
        $self->toaster->test("  $test", -x $bin );
    };

    return 1;
}

sub email_send {
    my $self = shift;
    my $email = $self->conf->{toaster_admin_email} || 'root';
    my $qdir = $self->conf->{qmail_dir} || '/var/qmail';
    my $ibin = "$qdir/bin/qmail-inject";
    if ( ! -x $ibin ) {
        return $self->error("qmail-inject ($ibin) not found!");
    };

    ## no critic
    open( my $INJECT, "| $ibin -a -f \"\" $email" ) or do {
        warn "FATAL: couldn't send using qmail-inject!\n";
        return;
    };
    ## use critic

    foreach ( qw/ clean spam eicar attach clam / ) {
        my $method = 'email_send_' . $_;
        $self->$method($INJECT, $email );
    };

    close $INJECT;

    return 1;
}

sub email_send_attach {
    my ( $self, $INJECT, $email ) = @_;

    print "\n\t\tSending .com test attachment - should fail.\n";
    print $INJECT <<"EOATTACH";
From: Mail Toaster Testing <$email>
To: Email Administrator <$email>
Subject: Email test (blocked attachment message)
Mime-Version: 1.0
Content-Type: multipart/mixed; boundary="gKMricLos+KVdGMg"
Content-Disposition: inline

--gKMricLos+KVdGMg
Content-Type: text/plain; charset=us-ascii
Content-Disposition: inline

This is an example of an Email message containing a virus. It should
trigger the virus scanner, and not be delivered.

If you are using qmail-scanner, the server admin should get a notification.

--gKMricLos+KVdGMg
Content-Type: text/plain; charset=us-ascii
Content-Disposition: attachment; filename="Eicar.com"

00000000000000000000000000000000000000000000000000000000000000000000

--gKMricLos+KVdGMg--

EOATTACH

}

sub email_send_clam {
    my ( $self, $INJECT, $email ) = @_;

    print "\n\t\tSending ClamAV test virus - should fail.\n";
    print $INJECT <<EOCLAM;
From: Mail Toaster testing <$email>
To: Email Administrator <$email>
Subject: Email test (virus message)

This is a viral message containing the clam.zip test virus pattern. It should be blocked by any scanning software using ClamAV.


--Apple-Mail-7-468588064
Content-Transfer-Encoding: base64
Content-Type: application/zip;
        x-unix-mode=0644;
        name="clam.zip"
Content-Disposition: attachment;
        filename=clam.zip

UEsDBBQAAAAIALwMJjH9PAfvAAEAACACAAAIABUAY2xhbS5leGVVVAkAA1SjO0El6E1BVXgEAOgD
6APzjQpgYGJgYGBh4Gf4/5+BYQeQrQjEDgxSDAQBIwPD7kIBBwbjAwEB3Z+DgwM2aDoYsKStqfy5
y5ChgndtwP+0Aj75fYYML5/+38J5VnGLz1nFJB4uRqaCMnEmOT8eFv1bZwRQjTwA5Degid0C8r+g
icGAt2uQn6uPsZGei48PA4NrRWZJQFF+cmpxMUNosGsQVNzZx9EXKJSYnuqUX+HI8Axqlj0QBLgy
MPgwMjIkOic6wcx8wNDXyM3IJAkMFAYGNoiYA0iPAChcwDwwGxRwjFA9zAxcEIYCODDBgAlMCkDE
QDTUXmSvtID8izeQaQOiQWHiGBbLAPUXsl+QwAEAUEsBAhcDFAAAAAgAvAwmMf08B+8AAQAAIAIA
AAgADQAAAAAAAAAAAKSBAAAAAGNsYW0uZXhlVVQFAANUoztBVXgAAFBLBQYAAAAAAQABAEMAAAA7
AQAAAAA=

--Apple-Mail-7-468588064


EOCLAM

}

sub email_send_clean {
    my ( $self, $INJECT, $email ) = @_;

    print "\n\t\tsending a clean message - should arrive unaltered\n";
    print $INJECT <<EOCLEAN;
From: Mail Toaster testing <$email>
To: Email Administrator <$email>
Subject: Email test (clean message)

This is a clean test message. It should arrive unaltered and should also pass any virus or spam checks.

EOCLEAN

}

sub email_send_eicar {
    my ( $self, $INJECT, $email ) = @_;

    # http://eicar.org/anti_virus_test_file.htm
    # X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*

    print "\n\t\tSending the EICAR test virus - should fail.\n";
    print $INJECT <<EOVIRUS;
From: Mail Toaster testing <$email'>
To: Email Administrator <$email>
Subject: Email test (eicar virus test message)
Mime-Version: 1.0
Content-Type: multipart/mixed; boundary="gKMricLos+KVdGMg"
Content-Disposition: inline

--gKMricLos+KVdGMg
Content-Type: text/plain; charset=us-ascii
Content-Disposition: inline

This is an example email containing a virus. It should trigger any good virus
scanner.

If it is caught by AV software, it will not be delivered to its intended
recipient (the email admin). The Qmail-Scanner administrator should receive
an Email alerting him/her to the presence of the test virus. All other
software should block the message.

--gKMricLos+KVdGMg
Content-Type: text/plain; charset=us-ascii
Content-Disposition: attachment; filename="sneaky.txt"

X5O!P%\@AP[4\\PZX54(P^)7CC)7}\$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!\$H+H*

--gKMricLos+KVdGMg--

EOVIRUS
      ;

}

sub email_send_spam {
    my ( $self, $INJECT, $email ) = @_;

    print "\n\t\tSending a sample spam message - should fail\n";

    print $INJECT 'Return-Path: sb55sb55@yahoo.com
Delivery-Date: Mon, 19 Feb 2001 13:57:29 +0000
Return-Path: <sb55sb55@yahoo.com>
Delivered-To: jm@netnoteinc.com
Received: from webnote.net (mail.webnote.net [193.120.211.219])
   by mail.netnoteinc.com (Postfix) with ESMTP id 09C18114095
   for <jm7@netnoteinc.com>; Mon, 19 Feb 2001 13:57:29 +0000 (GMT)
Received: from netsvr.Internet (USR-157-050.dr.cgocable.ca [24.226.157.50] (may be forged))
   by webnote.net (8.9.3/8.9.3) with ESMTP id IAA29903
   for <jm7@netnoteinc.com>; Sun, 18 Feb 2001 08:28:16 GMT
From: sb55sb55@yahoo.com
Received: from R00UqS18S (max1-45.losangeles.corecomm.net [216.214.106.173]) by netsvr.Internet with SMTP (Microsoft Exchange Internet Mail Service Version 5.5.2653.13)
   id 1429NTL5; Sun, 18 Feb 2001 03:26:12 -0500
DATE: 18 Feb 01 12:29:13 AM
Message-ID: <9PS291LhupY>
Subject: anti-spam test: checking SpamAssassin [if present] (There yours for FREE!)
To: undisclosed-recipients:;

Congratulations! You have been selected to receive 2 FREE 2 Day VIP Passes to Universal Studios!

Click here http://209.61.190.180

As an added bonus you will also be registered to receive vacations discounted 25%-75%!


@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
This mailing is done by an independent marketing co.
We apologize if this message has reached you in error.
Save the Planet, Save the Trees! Advertise via E mail.
No wasted paper! Delete with one simple keystroke!
Less refuse in our Dumps! This is the new way of the new millennium
To be removed please reply back with the word "remove" in the subject line.
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

';
}

sub imap_auth {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing only

    $self->imap_auth_nossl();
    $self->imap_auth_ssl();
};

sub imap_auth_nossl {
    my $self = shift;

    my $r = $self->util->install_module("Mail::IMAPClient", verbose => 0);
    $self->toaster->test("checking Mail::IMAPClient", $r );
    if ( ! $r ) {
        print "skipping imap test authentications\n";
        return;
    };

    eval "use Mail::IMAPClient";
    if ( $EVAL_ERROR ) {
        $self->audit("unable to load Mail::IMAPClient");
        return;
    };

    # an authentication that should succeed
    my $imap = Mail::IMAPClient->new(
        User     => $self->conf->{'toaster_test_email'} || 'test2@example.com',
        Password => $self->conf->{'toaster_test_email_pass'} || 'cHanGeMe',
        Server   => 'localhost',
    );
    if ( !defined $imap ) {
        $self->toaster->test( "imap connection", $imap );
        return;
    };

    $self->toaster->test( "authenticate IMAP user with plain passwords",
        $imap->IsAuthenticated() );

    my @features = $imap->capability
        or warn "Couldn't determine capability: $@\n";
    $self->audit( "Your IMAP server supports: " . join( ',', @features ) );
    $imap->logout;

    print "an authentication that should fail\n";
    $imap = Mail::IMAPClient->new(
        Server => 'localhost',
        User   => 'no_such_user',
        Pass   => 'hi_there_log_watcher'
    )
    or do {
        $self->toaster->test( "imap connection that should fail", 0);
        return 1;
    };
    $self->toaster->test( "  imap connection", $imap->IsConnected() );
    $self->toaster->test( "  test auth that should fail", !$imap->IsAuthenticated() );
    $imap->logout;
    return;
};

sub imap_auth_ssl {
    my $self = shift;

    my $user = $self->conf->{'toaster_test_email'}      || 'test2@example.com';
    my $pass = $self->conf->{'toaster_test_email_pass'} || 'cHanGeMe';

    my $r = $self->util->install_module( "IO::Socket::SSL", verbose => 0,);
    $self->toaster->test( "checking IO::Socket::SSL ", $r);
    if ( ! $r ) {
        print "skipping IMAP SSL tests due to missing SSL support\n";
        return;
    };

    require IO::Socket::SSL;
    my $socket = IO::Socket::SSL->new(
        PeerAddr => 'localhost',
        PeerPort => 993,
        Proto    => 'tcp',
        SSL_verify_mode => 'SSL_VERIFY_NONE',
    );
    $self->toaster->test( "  imap SSL connection", $socket);
    return if ! $socket;

    print "  connected with " . $socket->get_cipher() . "\n";
    print $socket ". login $user $pass\n";
    ($r) = $socket->peek =~ /OK/i;
    $self->toaster->test( "  auth IMAP SSL with plain password", $r ? 0 : 1);
    print $socket ". logout\n";
    close $socket;

#  no idea why this doesn't work, so I just forge an authentication by printing directly to the socket
#   my $imapssl = Mail::IMAPClient->new( Socket=>$socket, User=>$user, Password=>$pass) or warn "new IMAP failed: ($@)\n";
#   $imapssl->IsAuthenticated() ? print "ok\n" : print "FAILED.\n";

# doesn't work yet because courier doesn't support CRAM-MD5 via the vchkpw auth module
#   print "authenticating IMAP user with CRAM-MD5...";
#   $imap->connect;
#   $imap->authenticate();
#   $imap->IsAuthenticated() ? print "ok\n" : print "FAILED.\n";
#
#   print "logging out...";
#   $imap->logout;
#   $imap->IsAuthenticated() ? print "FAILED.\n" : print "ok.\n";
#   $imap->IsConnected() ? print "connection open.\n" : print "connection closed.\n";

}

sub pop3_auth {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    $OUTPUT_AUTOFLUSH = 1;

    my $r = $self->util->install_module( "Mail::POP3Client", verbose => 0,);
    $self->toaster->test("checking Mail::POP3Client", $r );
    eval "use Mail::POP3Client";
    if ( $EVAL_ERROR ) {
        print "unable to load Mail::POP3Client, skipping POP3 tests\n";
        return;
    };

    my %auths = (
        'POP3'          => { type => 'PASS',     descr => 'plain text' },
        'POP3-APOP'     => { type => 'APOP',     descr => 'APOP' },
        'POP3-CRAM-MD5' => { type => 'CRAM-MD5', descr => 'CRAM-MD5' },
        'POP3-SSL'      => { type => 'PASS', descr => 'plain text', ssl => 1 },
        'POP3-SSL-APOP' => { type => 'APOP', descr => 'APOP', ssl => 1 },
        'POP3-SSL-CRAM-MD5' => { type => 'CRAM-MD5', descr => 'CRAM-MD5', ssl => 1 },
    );

    foreach ( sort keys %auths ) {
        $self->pop3_auth_prot( $_, $auths{$_} );
    }

    return 1;
}

sub pop3_auth_prot {
    my $self = shift;
    my ( $name, $v ) = @_;

    my $type  = $v->{'type'};
    my $descr = $v->{'descr'};

    my $user = $self->conf->{'toaster_test_email'}        || 'test2@example.com';
    my $pass = $self->conf->{'toaster_test_email_pass'}   || 'cHanGeMe';
    my $host = $self->conf->{'pop3_ip_address_listen_on'} || 'localhost';
    $host = "localhost" if ( $host =~ /system|qmail|all/i );

    my $pop = Mail::POP3Client->new(
        HOST      => $host,
        AUTH_MODE => $type,
        $v->{ssl} ? ( USESSL => 1 ) : (),
    );

    if ( $v->{ssl} ) {
        my $socket = IO::Socket::SSL->new( PeerAddr => $host,
                                        PeerPort => 995,
                                        SSL_verify_mode => 'SSL_VERIFY_NONE',
                                        Proto    => 'tcp',
                                        )
            or do { warn "No socket!"; return };

         $pop->Socket($socket);
    }

    $pop->User($user);
    $pop->Pass($pass);
    $pop->Connect() >= 0 || warn $pop->Message();
    $self->toaster->test( "  $name authentication", ($pop->State eq 'TRANSACTION'));

#   if ( my @features = $pop->Capa() ) {
#       print "  POP3 server supports: " . join( ",", @features ) . "\n";
#   }
    $pop->Close;
}

sub smtp_auth {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my @modules = ('IO::Socket::INET', 'IO::Socket::SSL', 'Net::SSLeay', 'Socket qw(:DEFAULT :crlf)','Net::SMTP_auth');
    foreach ( @modules ) {
        eval "use $_";
        die $@ if $@;
        $self->toaster->test( "loading $_", 'ok' );
    };

    Net::SSLeay::load_error_strings();
    Net::SSLeay::SSLeay_add_ssl_algorithms();
    Net::SSLeay::randomize();

    my $host = $self->conf->{'smtpd_listen_on_address'} || 'localhost';
       $host = 'localhost' if ( $host =~ /system|qmail|all/i );

    my $smtp = Net::SMTP_auth->new($host);
    $self->toaster->test( "connect to smtp port on $host", $smtp );
    return 0 if ! defined $smtp;

    my @auths = $smtp->auth_types();
    $self->toaster->test( "  get list of SMTP AUTH methods", scalar @auths);
    $smtp->quit;

    $self->smtp_auth_pass($host, \@auths);
    $self->smtp_auth_fail($host, \@auths);
};

sub smtp_auth_pass {
    my $self = shift;
    my $host = shift;
    my $auths = shift or die "invalid params\n";

    my $user = $self->conf->{'toaster_test_email'}      || 'test2@example.com';
    my $pass = $self->conf->{'toaster_test_email_pass'} || 'cHanGeMe';

    # test each authentication method the server advertises
    foreach (@$auths) {

        my $smtp = Net::SMTP_auth->new($host);
        my $r = $smtp->auth( $_, $user, $pass );
        $self->toaster->test( "  authentication with $_", $r );
        next if ! $r;

        $smtp->mail( $self->conf->{'toaster_admin_email'} );
        $smtp->to('postmaster');
        $smtp->data();
        $smtp->datasend("To: postmaster\n");
        $smtp->datasend("\n");
        $smtp->datasend("A simple test message\n");
        $smtp->dataend();

        $smtp->quit;
        $self->toaster->test("  sending after auth $_", 1 );
    }
}

sub smtp_auth_fail {
    my $self = shift;
    my $host = shift;
    my $auths = shift or die "invalid params\n";

    my $user = 'non-exist@example.com';
    my $pass = 'non-password';

    foreach (@$auths) {
        my $smtp = Net::SMTP_auth->new($host);
        my $r = $smtp->auth( $_, $user, $pass );
        $self->toaster->test( "  failed authentication with $_", ! $r );
        $smtp->quit;
    }
}

sub run_all {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    print "testing...\n";

    $self->test_qmail;
    sleep 1;
    $self->daemontools;
    sleep 1;
    $self->ucspi;
    sleep 1;

    $self->dump_audit(quiet=>1);  # clear audit history

    $self->supervised_procs;
    sleep 1;
    $self->test_logging;
    sleep 1;
    $self->setup->vpopmail->test;
    sleep 1;

    $self->toaster->check_running_processes;
    sleep 1;
    $self->test_network;
    sleep 1;
    $self->crons;
    sleep 1;

    $self->qmail->check_rcpthosts;
    sleep 1;

    if ( ! $self->util->yes_or_no( "skip the mail scanner tests?", timeout  => 10 ) ) {
        $self->setup->simscan->test;
        print "\n\nFor more ways to test your Virus scanner, go here:
\n\t http://www.testvirus.org/\n\n";
    };
    sleep 1;

    if ( ! $self->util->yes_or_no( "skip the authentication tests?", timeout  => 10) ) {
        $self->auth();
    };

    # there's plenty more room here for more tests.

    # test DNS!
    # make sure primary IP is not reserved IP space
    # test reverse address for this machines IP
    # test resulting hostname and make sure it matches
    # make sure server's domain name has NS records
    # test MX records for server name
    # test for SPF records for server name

    # test for low disk space on /, qmail, and vpopmail partitions

    print "\ntesting complete.\n";
}

sub auth {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    $self->auth_setup or return;

    $self->imap_auth;
    $self->pop3_auth;
    $self->smtp_auth;

    print
"\n\nNOTICE: It is normal for some of the tests to fail. This test suite is useful for any mail server, not just a Mail::Toaster. \n\n";

    # webmail auth
    # other ?
}

sub auth_setup {
    my $self = shift;

    my $qmail_dir = $self->conf->{qmail_dir};
    my $assign    = "$qmail_dir/users/assign";
    my $email     = $self->conf->{toaster_test_email};
    my $pass      = $self->conf->{toaster_test_email_pass};

    my $domain = ( split( '@', $email ) )[1];
    print "test_auth: testing domain is: $domain.\n";

    if ( ! -e $assign || ! grep {/:$domain:/} `cat $assign` ) {
        print "domain $domain is not set up.\n";
        return if ! $self->util->yes_or_no( "may I add it for you?", timeout => 30 );

        my $vpdir = $self->conf->{vpopmail_home_dir};
        system "$vpdir/bin/vadddomain $domain $pass";
        system "$vpdir/bin/vadduser $email $pass";
    }

    open( my $ASSIGN, '<', $assign) or return;
    return if ! grep {/:$domain:/} <$ASSIGN>;
    close $ASSIGN;

    if ( $OSNAME eq "freebsd" ) {
        $self->freebsd->install_port( "p5-Mail-POP3Client" ) or return;
        $self->freebsd->install_port( "p5-Mail-IMAPClient" ) or return;
        $self->freebsd->install_port( "p5-Net-SMTP_auth"   ) or return;
        $self->freebsd->install_port( "p5-IO-Socket-SSL"   ) or return;
    }
    return 1;
};

sub crons {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my $tw = $self->util->find_bin( 'toaster-watcher.pl', verbose => 0);
    my $vpopdir = $self->conf->{'vpopmail_home_dir'} || "/usr/local/vpopmail";

    my @crons = ( "$vpopdir/bin/clearopensmtp", $tw);

    my $sqcache = "/usr/local/share/sqwebmail/cleancache.pl";
    push @crons, $sqcache if ( $self->conf->{'install_sqwebmail'} && -x $sqcache);

    print "checking cron processes\n";

    foreach (@crons) {
        $self->toaster->test("  $_", system( $_ ) ? 0 : 1 );
    }
}

sub test_dns {

    print <<'EODNS'
People forget to even have DNS setup on their Toaster, as Matt has said before. If someone forgot to configure DNS, chances are, little or nothing will work -- from port fetching to timely mail delivery.

How about adding a simple DNS check to the Toaster Setup test suite? And in the meantime, you could give some sort of crude benchmark, depending on the circumstances of the test data.  I am not looking for something too hefty, but something small and sturdy to make sure there is a good DNS server around answering queries reasonably fast.

Here is a sample of some DNS lookups you could perform.  What I would envision is that there were around 20 to 100 forward and reverse lookups, and that the lookups were timed.  I guess you could look them up in parallel, and wait a maximum of around 15 seconds for all of the replies.  The interesting thing about a lot of reverse lookups is that they often fail because no one has published them.

Iteration 1: lookup A records.
Iteration 2: lookup NS records.
Iteration 3: lookup MX records.
Iteration 4: lookup TXT records.
Iteration 5: Repeat step 1, observe the faster response time due to caching.

Here's a sample output!  Wow.

#toaster_setup.pl -s dnstest
Would you like to enter a local domain so I can test it in detail?
testmydomain-local.net
Would you like to test domains with underscores in them? (y/n)n
Testing /etc/rc.conf for a hostname= line...
This box is known as smtp.testmydomain-local.net
Verifying /etc/hosts exists ... Okay
Verifying /etc/host.conf exists ... Okay
Verifying /etc/nsswitch.conf exists ... Okay
Doing reverse lookups in in-addr.arpa using default name service....
Doing forward A lookups using default name service....
Doing forward NS lookups using default name service....
Doing forward MX lookups using default name service....
Doing forward TXT lookups using default name service....
Results:
[Any errors, like...]
Listing Reverses Not found:
10.120.187.45 (normal)
169.254.89.123 (normal)
Listing A Records Not found:
example.impossible.nonexistent.bogus.co.nl (normal)
Listing TXT Records Not found:
Attempting to lookup the same A records again....  Hmmm. much faster!
Your DNS Server (or its forwarder) seems to be caching responses. (Good)

Checking local domain known as testmydomain-local.net
Checking to see if I can query the testmydomain-local.net NS servers and retrieve the entire DNS record...
ns1.testmydomain-local.net....yes.
ns256.backup-dns.com....yes.
ns13.ns-ns-ns.net...no.
Do DNS records agree on all DNS servers?  Yes. identical.
Skipping SOA match.

I have discovered that testmydomain-local.net has no MX records.  Shame on you, this is a mail server!  Please fix this issue and try again.

I have discovered that testmydomain-local.net has no TXT records.  You may need to consider an SPF v1 TXT record.

Here is a dump of your domain records I dug up for you:
xoxoxoxox

Does hostname agree with DNS?  Yes. (good).

Is this machine a CNAME for something else in DNS?  No.

Does this machine have any A records in DNS?  Yes.
smtp.testmydomain-local.net is 192.168.41.19.  This is a private IP.

Round-Robin A Records in DNS pointing to another machine/interface?
No.

Does this machine have any CNAME records in DNS?  Yes. aka
box1.testmydomain-local.net
pop.testmydomain-local.net
webmail.testmydomain-local.net

***************DNS Test Output complete

Sample Forwards:
The first few may be cached, and the last one should fail.  Some will have no MX server, some will have many.  (The second to last entry has an interesting mail exchanger and priority.)  Many of these will (hopefully) not be found in even a good sized DNS cache.

I have purposely listed a few more obscure entries to try to get the DNS server to do a full lookup.
localhost
<vpopmail_default_domain if set>
www.google.com
yahoo.com
nasa.gov
sony.co.jp
ctr.columbia.edu
time.nrc.ca
distancelearning.org
www.vatican.va
klipsch.com
simerson.net
warhammer.mcc.virginia.edu
example.net
foo.com
example.impossible.nonexistent.bogus.co.nl

[need some obscure ones that are probably always around, plus some non-US sample domains.]

Sample Reverses:
Most of these should be pretty much static.  Border routers, nics and such.  I was looking for a good range of IP's from different continents and providers.  Help needed in some networks.  I didn't try to include many that don't have a published reverse name, but many examples exist in case you want to purposely have some.
127.0.0.1
224.0.0.1
198.32.200.50	(the big daddy?!)
209.197.64.1
4.2.49.2
38.117.144.45
64.8.194.3
72.9.240.9
128.143.3.7
192.228.79.201
192.43.244.18
193.0.0.193
194.85.119.131
195.250.64.90
198.32.187.73
198.41.3.54
198.32.200.157
198.41.0.4
198.32.187.58
198.32.200.148
200.23.179.1
202.11.16.169
202.12.27.33
204.70.25.234
207.132.116.7
212.26.18.3
10.120.187.45
169.254.89.123

[Looking to fill in some of the 12s, 50s and 209s better.  Remove some 198s]

Just a little project.  I'm not sure how I could code it, but it is a little snippet I have been thinking about.  I figure that if you write the code once, it would be quite a handy little feature to try on a server you are new to.

Billy

EODNS
      ;
}

sub test_logging {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    print "do the logging directories exist?\n";
    my $q_log = $self->conf->{'qmail_log_base'};
    foreach ( '', "pop3", "send", "smtp", "submit" ) {
        $self->toaster->test("  $q_log/$_", -d "$q_log/$_" );
    }

    print "checking log files?\n";
    my @active_log_files = ( "clean.log", "maildrop.log", "watcher.log",
                    "send/current",  "smtp/current",  "submit/current" );

    push @active_log_files, "pop3/current" if $self->conf->{'pop3_daemon'} eq 'qpop3d';

    foreach ( @active_log_files ) {
        $self->toaster->test("  $_", -f "$q_log/$_" );
    }
}

sub test_network {
    my $self = shift;
    return if $self->util->yes_or_no( "skip the network listener tests?",
            timeout  => 10,
        );

    my $netstat = $self->util->find_bin( 'netstat', fatal => 0, verbose=>0 );
    return unless $netstat && -x $netstat;

    if ( $OSNAME eq "freebsd" ) { $netstat .= " -alS" }
    if ( $OSNAME eq "darwin" )  { $netstat .= " -al" }
    if ( $OSNAME eq "linux" )   { $netstat .= " -a --numeric-hosts" }
    else { $netstat .= " -a" };      # should be pretty safe

    print "checking for listening tcp ports\n";
    my @listeners = `$netstat | grep -i listen`;
    foreach (qw( smtp http pop3 imap https submission pop3s imaps )) {
        $self->toaster->test("  $_", scalar grep {/$_/} @listeners );
    }

    print "checking for udp listeners\n";
    my @udps;
    push @udps, "snmp" if $self->conf->{install_snmp};

    foreach ( @udps ) {
        $self->toaster->test("  $_", `$netstat | grep $_` );
    }
}

sub test_qmail {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts } );

    my $qdir = $self->conf->{'qmail_dir'};
    print "does qmail's home directory exist?\n";
    $self->toaster->test("  $qdir", -d $qdir );

    print "checking qmail directory contents\n";
    my @tests = qw(alias boot control man users bin doc queue);
    push @tests, "configure" if ( $OSNAME eq "freebsd" );    # added by the port
    foreach (@tests) {
        $self->toaster->test("  $qdir/$_", -d "$qdir/$_" );
    }

    print "is the qmail rc file executable?\n";
    $self->toaster->test(  "  $qdir/rc", -x "$qdir/rc" );

    print "do the qmail users exist?\n";
    foreach (
        $self->conf->{'qmail_user_alias'}  || 'alias',
        $self->conf->{'qmail_user_daemon'} || 'qmaild',
        $self->conf->{'qmail_user_passwd'} || 'qmailp',
        $self->conf->{'qmail_user_queue'}  || 'qmailq',
        $self->conf->{'qmail_user_remote'} || 'qmailr',
        $self->conf->{'qmail_user_send'}   || 'qmails',
        $self->conf->{'qmail_log_user'}    || 'qmaill',
      )
    {
        $self->toaster->test("  $_", $self->setup->user_exists($_) );
    }

    print "do the qmail groups exist?\n";
    foreach ( $self->conf->{'qmail_group'}     || 'qmail',
              $self->conf->{'qmail_log_group'} || 'qnofiles',
        ) {
        $self->toaster->test("  $_", scalar getgrnam($_) );
    }

    print "do the qmail alias files have contents?\n";
    my $q_alias = "$qdir/alias/.qmail";
    foreach ( qw/ postmaster root mailer-daemon / ) {
        $self->toaster->test( "  $q_alias-$_", -s "$q_alias-$_" );
    }
}

sub supervised_procs {
    my $self = shift;

    print "do supervise directories exist?\n";
    my $q_sup = $self->conf->{'qmail_supervise'} || "/var/qmail/supervise";
    $self->toaster->test("  $q_sup", -d $q_sup);

    # check supervised directories
    foreach ( qw/ smtp send pop3 submit / ) {
        $self->toaster->test( "  $q_sup/$_",
            $self->toaster->supervised_dir_test( prot => $_, verbose=>1 ) );
    }

    print "do service directories exist?\n";
    my $q_ser = $self->conf->{'qmail_service'};

    my @active_service_dirs;
    foreach ( qw/ smtp send / ) {
        push @active_service_dirs, $self->toaster->service_dir_get( $_ );
    }

    push @active_service_dirs, $self->toaster->service_dir_get( 'pop3' )
        if $self->conf->{'pop3_daemon'} eq 'qpop3d';

    push @active_service_dirs, $self->toaster->service_dir_get( "submit" )
        if $self->conf->{'submit_enable'};

    foreach ( $q_ser, @active_service_dirs ) {
        $self->toaster->test( "  $_", -d $_ );
    }

    print "are the supervised services running?\n";
    my $svok = $self->util->find_bin( 'svok', fatal => 0 );
    foreach ( @active_service_dirs ) {
        $self->toaster->test( "  $_", system("$svok $_") ? 0 : 1 );
    }
};

sub ucspi {
    my $self  = shift;

    print "checking ucspi-tcp binaries...\n";
    foreach (qw( tcprules tcpserver rblsmtpd tcpclient recordio )) {
        $self->toaster->test("  $_", $self->util->find_bin( $_, fatal => 0, verbose=>0 ) );
    }

    if ( $self->conf->{install_mysql} && $self->conf->{'vpopmail_mysql'} ) {
        my $tcpserver = $self->util->find_bin( "tcpserver", fatal => 0, verbose=>0 );
        $self->toaster->test( "  tcpserver mysql support",
            scalar `strings $tcpserver | grep sql`
        );
    }

    return 1;
}

1;
__END__;



=item email_send


  ############ email_send ####################
  # Usage      : $toaster->email_send("clean" );
  #            : $toaster->email_send("spam"  );
  #            : $toaster->email_send("attach");
  #            : $toaster->email_send("virus" );
  #            : $toaster->email_send("clam"  );
  #
  # Purpose    : send test emails to test the content scanner
  # Returns    : 1 on success
  # Parameters : type (clean, spam, attach, virus, clam)
  # See Also   : email_send_[clean|spam|...]


Email test routines for testing a mail toaster installation.

This sends a test email of a specified type to the postmaster email address configured in toaster-watcher.conf.


=item email_send_attach


  ######### email_send_attach ###############
  # Usage      : internal only
  # Purpose    : send an email with a .com attachment
  # Parameters : an email address
  # See Also   : email_send

Sends a sample test email to the provided address with a .com file extension. If attachment scanning is enabled, this should trigger the content scanner (simscan/qmailscanner/etc) to reject the message.


=item email_send_clam

Sends a test clam.zip test virus pattern, testing to verify that the AV engine catches it.


=item email_send_clean

Sends a test clean email that the email filters should not block.


=item email_send_eicar

Sends an email message with the Eicar virus inline. It should trigger the AV engine and block the message.


=item email_send_spam

Sends a sample spam message that SpamAssassin should block.

=cut
