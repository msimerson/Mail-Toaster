#!/usr/bin/perl
use strict;
use warnings;

use Data::Dumper;
use English 'no_match_vars';
use File::stat;
use Getopt::Long;
use Pod::Usage;
use Sys::Hostname;

die "This script must be run as root\n" if $UID != 0;
die "DateTime not installed" if ! eval "use DateTime";
die "DateTime not installed" if $@;

GetOptions (
   'dir=s'      => \my $backup_dir,
   "email=s"    => \my $email,
   'hostname=s' => \my $hostname,
   "verbose"    => \my $verbose,
);

# get the email address, and make sure it exists
$email ||= ask("Restore which email address", $ARGV[0] );
my ($user,$domain) = split('@', $email);
my $maildir = "/usr/local/vpopmail/domains/$domain/$user";
die "no maildir ($maildir) exists for $email\n" if ! -d $maildir;

# determine where the backups are located
$backup_dir ||= '/mnt/snapshots/'; #  ask("Where are backups stored", '/mnt/snapshots/');
$hostname ||= ask("Hostname", hostname);

# get a list of snapshots we can restore from
my $dirs = get_snapshots($backup_dir, $hostname, $maildir);
#print Dumper($dirs);

# ask the operator which one they wish to restore to
my $selection = ask("Enter the # next to the date you wish to restore from", 1);
die "that number doesn't exist!" if ! $dirs->{$selection};

# assemble and present the rsync command
my $cmd = "rsync -iavH --exclude 'courier*' $dirs->{$selection}/ $maildir/";

print <<EOWARN 
\nCAUTION: restoring a mailbox will merge the contents of the current mailbox
with the contents of the archived mailbox. This may cause some message
duplicates (a message read today, but unread in the backup) but is preferable
to a 'perfect restore', which would delete all messages that have arrived
since the snapshot was taken.

This is your restore command:

$cmd

You can test it first with the -n flag to rsync.

EOWARN
;

my $answer = ask("Shall I restore the mailbox? (y/n)", 'n' );
die "okay, not restoring\n" if $answer ne 'y';
system $cmd;
#pod2usage( "$0 -e $email" );

sub get_snapshots {
    my ($dir,$host,$maildir) = @_;
    $dir .= '/' if ( substr($dir,-1,1) ne '/' );

    opendir D, $dir or die "couldn't open $dir: $!";
    my @list = readdir(D);
    closedir(D);

    my %dirs;
    my $i = 1;

    foreach my $f ( sort @list ) {
        next if $f =~ /^\.\.?$/;
        my $path = $dir . $f;
        next if ! -d $path;
        $path .= '/' . $host . $maildir;  # rsnapshot has hostname subdir
        if ( ! -d $path ) {
            print "\tno backup for $email at $path\n";
            next;
        };
        #print "$path\n";
        my $dt = DateTime->from_epoch( epoch => stat($dir.$f)->mtime );
        print "\t$i \t " . $dt->ymd . "\n";
        $dirs{$i} = $path;
        $i++;
    }
    return \%dirs;
};

sub ask {
    my $question = shift;
    my $default = shift;
    my $response;

PROMPT:
    print "$question";
    print " [$default]" if defined $default;
    print ": ";
    $response = <STDIN>;
    chomp $response;

    return $response if length $response  > 0; # they typed something, return it
    return $default if defined $default;   # return the default, if available
    return '';                             # return empty handed
}


=head1 NAME
 
email_restore - Restore messages from a backup snapshot
 
=head1 USAGE
 
   ./email_restore -e user@example.com
 
 
=head1 REQUIRED ARGUMENTS
 
  email - a valid email address on this server

=head1 OPTIONS
 
  dir   - the path to the email backups
  host  - the hostname of this server (default: `hostname`)
 
=head1 DESCRIPTION
 
Restore email messages from backups.
 
=head1 CONFIGURATION AND ENVIRONMENT
 
Expects backups to be in rsnapshot format (host/[daily|weekly|monthly].N/$path)


=head1 BUGS AND LIMITATIONS
 
Requires that you have backups accessible (mounted locally) to this script. This could easily be extended to support restores across the network.
 
=head1 AUTHOR
 
Matt Simerson  (matt@tnpi.net)
 
