#!/usr/bin/perl
use strict;

=head1 NAME

migrate.pl

=head1 SYNOPSIS

migrate.pl - migrate email domains from one Mail Toaster to another.


=head1 VERSION

This is version .06.


=head1 SYNOPSIS

  ./migrate.pl 


=head1 DESCRIPTION



=head1 CHANGES

July 7, 06 - merged in some automation additions. use with caution.

=head1 TODO

Create the new users using vadduser -s. Will be more reliable in fringe cases where someone tampered with the vpopmail tables, as well as working on systems where password learning feature is disabled.

=cut

use lib 'lib';
use Mail::Toaster::Mysql;   
use Mail::Toaster::Utility; 

my $toaster = Mail::Toaster->new();
my $util  = Mail::Toaster::Utility->new( log => $toaster );
my $mysql = Mail::Toaster::Mysql->new( log => $toaster );

my ($type, $domain, $newhost) = @ARGV;
my $vpopdir = "/usr/local/vpopmail";
my $exists = 0;

unless ( $newhost && $newhost ne "" ) { _usage($domain, $newhost); };

if    ($type eq "user")   { migrate_user    ($domain, $newhost) } 
elsif ($type eq "domain") { migrate_vpopmail($domain, $newhost) } 
else                      { _usage          ($domain, $newhost) }


sub migrate_vpopmail
{
	my ($domain, $host) = @_;

	my @users = get_userlist_from_mysql($domain);

	unless ( @users > 0 ) {
		warn "no users found for $domain!\n";
		exit 0;
	};

	print "run the following commands on $host:\n";

	my $postmaster = add_postmaster(undef, $domain, $host, @users);  # show the domain creation cmd
	add_emails(undef, $domain, $host, @users);    # the email accounts to add

	if ( $util->yes_or_no( "\nshall I try it for you?", force=>1) ) 
	{
		# does the domain directory exist on the other end?
		unless ( $util->syscmd("ssh $host test -d $vpopdir/domains/$domain", debug=>0)) {
			$exists++;
			print "target directory already exists on $host!\n\tmoving it out of the way...";
			$util->syscmd("ssh $host mv $vpopdir/domains/$domain $vpopdir/domains/$domain.bak", debug=>0);
			print "done.\n";
		};

		print "creating the domain and email accounts on $host.\n";
		$postmaster = add_postmaster(1, $domain, $host, @users);     # create the domain
		if ( ! $postmaster ) {                                   # add the rest of the accounts.
			die "failed to add postmaster account! I cannot continue.\n";
		};
		add_emails(1, $domain, $host, @users);
	};

	# this test could/should be automated!
	unless ( $util->yes_or_no( "\nhas the previous task completed successfully (w/o errors)? ", force=>1) ) {
		die "ok, bombing out!\n";
	};

	# get list of users and domains
	# create domains and users on the new server
	add_domain_to_smtproutes($domain, $host);

	# migrate contents of mailboxes to new server
	rsync_mailboxes_to_new($domain, $host);

	# test local email forwarding
	send_test_email("old", $domain);  # should get forwarded to new server via smtproutes

	# test remove email delivery
	send_test_email($host, $domain);  

	# delete the domain locally
	delete_domain($domain);

	# make sure we can still accept email for it
	verify_domain_exists_in_rcpthosts($domain);

	# forward email for this domain to the new server
	verify_domain_exists_in_smtproutes($host, $domain);
};

sub add_emails
{
	my ($do, $domain, $host, @r) = @_;

    my $vadduser = "$vpopdir/bin/vadduser";
	foreach (@r) {
		next if ($_->{'pw_name'} eq "postmaster");
		#print "name: $_->{'pw_name'} \n";

		$vadduser .= "-n" if $_->{'pw_clear_passwd'} eq "";

		my $cmd = "$vadduser '$_->{'pw_name'}\@$_->{'pw_domain'}' '$_->{'pw_clear_passwd'}'";
		print " $cmd\n";

		if ( $do ) {
			$util->syscmd("ssh $host $cmd", debug=>0);
		}
	};
};

sub add_postmaster
{
	my ($do, $domain, $host, @r) = @_;

	foreach (@r) {                                
		next unless ($_->{'pw_name'} eq "postmaster");    # find the postmaster account
		my $cmd = "$vpopdir/bin/vadddomain '$domain' '$_->{'pw_clear_passwd'}'";
		print "  $cmd\n";
		if ( $do ) {
			$util->syscmd("ssh $host $cmd", debug=>0); # add the domain on the new server.
			return 1;
		};
	};

	return 0;
}

sub migrate_user
{
	my ($domain, $host) = @_;

	my $homedir = (getpwnam($domain))[7];
	die "no homedir for $domain" unless -d $homedir;

	print "\nrsync -avn -e ssh $homedir $host:/home/\n";

	print "add user with:\n";

	my $r = `grep $domain /etc/master.passwd`;

	print "$r\n";
}

sub get_userlist_from_mysql
{
	my $domain = shift;

	_check_my_cnf();
	my $dot = $mysql->parse_dot_file(".my.cnf", "[mysql]", 0);

	my ($dbh, $dsn, $drh) = $mysql->connect($dot, 0, 1 );

	my $query = "select * from vpopmail.vpopmail where pw_domain=\"$domain\"";

	return $mysql->get_hashes($dbh, $query, 1);
};

sub add_domain_to_smtproutes
{
	my ($domain, $host) = @_;

	print "checking smtproutes for $domain...";

	if  ( ! `grep $domain /var/qmail/control/smtproutes` ) {
		print "missing.\nadding $domain to smtproutes...";
		$util->file_write("/var/qmail/control/smtproutes", lines=>["$domain:$host"], append=>1);
	};

	if ( `grep $domain /var/qmail/control/smtproutes`) {
		print "ok.\n";
		return 1;
	};

	print "FAILED.\n";
	return 0;
}

sub send_test_email
{
	my ($host, $domain) = @_;

	$host ? print "on this (the old server), " : print "on the server $host, ";
	print "send an email to postmaster\@$domain with:\n
mail postmaster\@$domain
test email
testing
.\n\nand make sure it gets delivered properly.";

	unless ( $util->yes_or_no( "\nhave you completed the previous task successfully?", force=>1) ) {
		die "ok, bombing out!\n";
	};
};

sub delete_domain
{
	my ($domain) = @_;

	print "now delete the domain from the (old) server with:\n";
	print "\n  $vpopdir/bin/vdeldomain $domain";

	if ( $util->yes_or_no( "\nshall I try it for you?", force=>1) ) {
		$util->syscmd("$vpopdir/bin/vdeldomain $domain", debug=>0);
	};

	unless ( $util->yes_or_no( "\nhave you completed the previous task successfully?", force=>1) ) {
		die "ok, bombing out!\n";
	};
};

sub verify_domain_exists_in_rcpthosts 
{
	my ($domain) = @_;

	print "checking rcpthosts for $domain...";
	my $r = `grep $domain /var/qmail/control/rcpthosts`;
	$r ? print "ok.\n" : print "FAILED.\n";

	unless ($r) {
		if ($util->yes_or_no( "shall I fix that for you?", force=>1) ){
			$util->file_write("/var/qmail/control/rcpthosts", lines=>[$domain], append=>1);
		};
	};
};

sub verify_domain_exists_in_smtproutes
{
	my ($host, $domain) = @_;

	print "checking smtproutes for $domain...";
	my $r = `grep $domain /var/qmail/control/smtproutes`;
	$r ? print "ok.\n" : print "FAILED.\n";

	unless ($r) {
		if ($util->yes_or_no( "shall I do that for you?", force=>1) ){
			$util->file_write("/var/qmail/control/smtproutes", lines=>["$domain:$host"], append=>1);
		};
	};
};

sub rsync_mailboxes_to_new
{
	my ($domain, $host) = @_;

	if ($exists) {
		print "executing commands on $host\n";
		my $cleanup = "rm -r $vpopdir/domains/$domain";
		my $clean2  = "mv $vpopdir/domains/$domain.bak $vpopdir/domains/$domain";
		print "   $cleanup\n";
		$util->syscmd("ssh $host $cleanup", debug=>0);
		print "   $clean2\n";
		$util->syscmd("ssh $host $clean2", debug=>0);
	};

	my $cmd = "rsync -av -e ssh --delete $vpopdir/domains/$domain $host:$vpopdir/domains/";

	print "rsync the maildirs from this (old) server to the new one with:\n\n   $cmd \n\n";

	if ( $util->yes_or_no( "\nshall I try it for you?", force=>1) ) {
		$util->syscmd($cmd, debug=>0);
	};

	unless ( $util->yes_or_no( "\nhas the previous task completed successfully?", force=>1) ) {
		die "ok, bombing out!\n";
	};
};

sub _usage {
	my ($dom, $host) = @_;
	print "
This script must be run on the OLD server and it will copy files to new server. You'll need two things set up.

	1. rsync installed on both systems
	2. SSH key based authentication for root from old to new

The former you can figure out yourself. The latter is a little harder, but not terribly difficult. First, you need to have SSH as root enabled on the new server. Do NOT allow root authentication with passwords. Accomplish this by setting PermitRootLogin to without-password in your sshd_config file and restarting the sshd daemon. Then generate a ssh key on the old server (ssh-keygen -d) and add the public key (.ssh/id_dsa.pub) to ~/.ssh/authorized_keys on the new server.

	usage: $0 user   username    newhost.fqdn.com  (user   = /etc/passwd username)
	       $0 domain example.com newhost.fqdn.com  (domain = vpopmail domain name)

";

	die "\n" unless ($dom and $host);
}

sub _check_my_cnf
{

    my ($homedir) = (getpwuid ($<))[7];

	unless ( $util->is_readable( "$homedir/.my.cnf" ) )
	{
		print "\nHey bubba, I need to connect to your MySQL server as the root or vpopmail user. To facilitate this, I expect a configured ~/.my.cnf file. This file format is the same as the mysql client uses and properly configured might look like this:

[mysql]
user       = vpopmail
pass       = superSecretReallySecurePasswordBecauseImSmart

Create that file now, make sure it's readable by the user only (chmod 0400 ~/.my.cnf), and then rerun this script.

";
		die "\n";
	};
}

exit 0;


=head1 DEPENDENCIES

  Mail Toaster


=head1 BUGS AND LIMITATIONS

    Needs more and better documentation, and explanations of what it is doing

    Needs to migrate valias entries from MySQL


Please report any bugs or feature requests to
C<bug-mail-toaster@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.


=head1 AUTHOR

Matt Simerson  C<< <matt@tnpi.net> >>


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2004-2008, The Network People, Inc. C<< <info@tnpi.net> >>. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the follo
wing disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the fo
llowing disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED ANDON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.  

