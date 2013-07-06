package Mail::Toaster::Setup::Simscan;

use strict;
use warnings;

use Carp;
#use Config;
#use Cwd;
#use Data::Dumper;
#use File::Copy;
#use File::Path;
use English '-no_match_vars';
use Params::Validate ':all';
use Sys::Hostname;

use lib 'lib';
use parent 'Mail::Toaster::Base';

sub install {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    return $p{test_ok} if defined $p{test_ok}; # for testing

    my $ver = $self->conf->{'install_simscan'} or do {
        $self->audit( "simscan install, skipping (disabled)" );
        return;
    };

    if ( $OSNAME eq 'freebsd' ) {
        my $r = $self->install_freebsd_port();
        return $r if $ver eq 'port';
    };

    my $user    = $self->conf->{'simscan_user'} || "clamav";
    my $reje    = $self->conf->{'simscan_spam_hits_reject'};
    my $qdir    = $self->conf->{'qmail_dir'};
    my $custom  = $self->conf->{'simscan_custom_smtp_reject'};

    if ( -x "$qdir/bin/simscan" ) {
        return 0
            if ! $self->util->yes_or_no(
                "simscan is already installed, do you want to reinstall?",
                timeout => 60,
            );
    }

    my $bin;
    my $confcmd = "./configure ";
    $confcmd .= "--enable-user=$user ";
    $confcmd .= $self->simscan_ripmime( $ver );
    $confcmd .= $self->simscan_clamav;
    $confcmd .= $self->simscan_spamassassin;
    $confcmd .= $self->simscan_regex;
    $confcmd .= "--enable-received=y "       if $self->conf->{'simscan_received'};
    $confcmd .= "--enable-spam-hits=$reje "  if ($reje);
    $confcmd .= "--enable-attach=y " if $self->conf->{'simscan_block_attachments'};
    $confcmd .= "--enable-qmaildir=$qdir "   if $qdir;
    $confcmd .= "--enable-qmail-queue=$qdir/bin/qmail-queue " if $qdir;
    $confcmd .= "--enable-per-domain=y "     if $self->conf->{'simscan_per_domain'};
    $confcmd .= "--enable-custom-smtp-reject=y " if $custom;
    $confcmd .= "--enable-spam-passthru=y " if $self->conf->{'simscan_spam_passthru'};

    if ( $self->conf->{'simscan_quarantine'} && -d $self->conf->{'simscan_quarantine'} ) {
        $confcmd .= "--enable-quarantinedir=$self->conf->{'simscan_quarantine'}";
    }

    print "configure: $confcmd\n";
    my $patches = [];
    push @$patches, 'simscan-1.4.0-clamav.3.patch' if $confcmd =~ /clamavdb/;

    $self->util->install_from_source(
       'package'      => "simscan-$ver",
#       site           => 'http://www.inter7.com',
        site           => "http://downloads.sourceforge.net",
        url            => '/simscan',
        targets        => [ $confcmd, 'make', 'make install-strip' ],
        bintest        => "$qdir/bin/simscan",
        source_sub_dir => 'mail',
        patches        => $patches,
        patch_url      => $self->conf->{'toaster_dl_site'}.$self->conf->{'toaster_dl_url'}.'/patches',
    );

    $self->config();
}

sub simscan_clamav {
    my ( $self ) = @_;

    return '' if ! $self->conf->{'simscan_clamav'};

    my $bin = $self->util->find_bin( "clamdscan", fatal => 0 );
    croak "couldn't find $bin, install ClamAV!\n" if !-x $bin;

    my $cmd .= "--enable-clamdscan=$bin ";
    $cmd .= "--enable-clamavdb-path=";
    $cmd .= -d "/var/db/clamav"  ?  "/var/db/clamav "
          : -d "/usr/local/share/clamav" ? "/usr/local/share/clamav "
          : -d "/opt/local/share/clamav" ? "/opt/local/share/clamav "
          : croak "can't find the ClamAV db path!";

    $bin = $self->util->find_bin( "sigtool", fatal => 0 );
    croak "couldn't find $bin, install ClamAV!" if ! -x $bin;
    $cmd .= "--enable-sigtool-path=$bin ";
    return $cmd;
};

sub config {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my ( $file, @lines );

    my $reje = $self->conf->{'simscan_spam_hits_reject'};

    my @attach;
    if ( $self->conf->{'simscan_block_attachments'} ) {

        $file = "/var/qmail/control/ssattach";
        foreach ( split( /,/, $self->conf->{'simscan_block_types'} ) ) {
            push @attach, ".$_";
        }
        $self->util->file_write( $file, lines => \@attach );
    }

    $file = "/var/qmail/control/simcontrol";
    if ( !-e $file ) {
        my @opts;
        $self->conf->{'simscan_clamav'}
          ? push @opts, "clam=yes"
          : push @opts, "clam=no";

        $self->conf->{'simscan_spamassassin'}
          ? push @opts, "spam=yes"
          : push @opts, "spam=no";

        $self->conf->{'simscan_trophie'}
          ? push @opts, "trophie=yes"
          : push @opts, "trophie=no";

        $reje
          ? push @opts, "spam_hits=$reje"
          : print "no reject.\n";

        if ( @attach > 0 ) {
            my $line  = "attach=";
            my $first = shift @attach;
            $line .= "$first";
            foreach (@attach) { $line .= ":$_"; }
            push @opts, $line;
        }

        @lines = "#postmaster\@example.com:" . join( ",", @opts );
        push @lines, "#example.com:" . join( ",", @opts );
        push @lines, "#";
        push @lines, ":" . join( ",",             @opts );

        if ( -e $file ) {
            $self->util->file_write( "$file.new", lines => \@lines );
            print
"\nNOTICE: simcontrol written to $file.new. You need to review and install it!\n";
        }
        else {
            $self->util->file_write( $file, lines => \@lines );
        }
    }

    my $user  = $self->conf->{'simscan_user'}       || 'simscan';
    my $group = $self->conf->{'smtpd_run_as_group'} || 'qmail';

    $self->util->syscmd( "pw user mod simscan -G qmail,clamav" );
    $self->util->chown( '/var/qmail/simscan', uid => $user, gid => $group );
    $self->util->chown( '/var/qmail/bin/simscan', uid => $user, gid=>$group );
    $self->util->chmod( dir => '/var/qmail/simscan', mode => '0770' );

    if ( -x "/var/qmail/bin/simscanmk" ) {
        $self->util->syscmd( "/var/qmail/bin/simscanmk" );
        system "/var/qmail/bin/simscanmk";
    }
}

sub install_freebsd_port {
    my $self = shift;

    my @args;
    push @args, "SPAMC_ARGS=" . $self->conf->{simscan_spamc_args} if $self->conf->{simscan_spamc_args};
    push @args, 'SPAM_HITS=' . $self->conf->{simscan_spam_hits_reject} if $self->conf->{simscan_spam_hits_reject};
    push @args, 'SIMSCAN_USER=' . $self->conf->{simscan_user} if $self->conf->{simscan_user};
    push @args, 'QUARANTINE_DIR=' . $self->conf->{simscan_quarantine} if $self->conf->{'simscan_quarantine'};
    push @args, 'QMAIL_PREFIX=' . $self->conf->{qmail_dir} || '/var/qmail';

    $self->freebsd->install_port( "simscan",
        category => 'mail',
        flags => join( ",", @args ),
        options => "# Options for simscan-1.4.0_6
_OPTIONS_READ=simscan-1.4.0_6
_FILE_COMPLETE_OPTIONS_LIST=ATTACH CLAMAV DOMAIN DROPMSG DSPAM HEADERS PASSTHRU RIPMIME SPAMD USER
OPTIONS_FILE_SET+=ATTACH
OPTIONS_FILE_SET+=CLAMAV
OPTIONS_FILE_SET+=DOMAIN
OPTIONS_FILE_UNSET+=DROPMSG
OPTIONS_FILE_UNSET+=DSPAM
OPTIONS_FILE_SET+=HEADERS
OPTIONS_FILE_UNSET+=PASSTHRU
OPTIONS_FILE_SET+=RIPMIME
OPTIONS_FILE_SET+=SPAMD
OPTIONS_FILE_SET+=USER
",
    );

    return $self->config();
};

sub simscan_regex {
    my ($self) = @_;
    return '' if ! $self->conf->{'simscan_regex_scanner'};

    my $config = "--enable-regex=y ";

    if ( $OSNAME eq "freebsd" ) {
        $self->freebsd->install_port( 'pcre' );
        $config .= "--with-pcre-include=/usr/local/include ";
    }
    else {
        print "\n\nWARNING: is pcre installed?\n\n";
    }
    return $config;
};

sub simscan_ripmime {
    my ($self, $ver ) = @_;

    if ( ! $self->setup->is_newer( min => "1.0.8", cur => $ver ) ) {
        print "ripmime doesn't work with simcan < 1.0.8\n";
        return '';
    };

    return "--disable-ripmime " if ! $self->conf->{'simscan_ripmime'};

    my $bin = $self->util->find_bin( "ripmime", fatal => 0, verbose=>0);
    unless ( -x $bin ) {
        croak "couldn't find $bin, install ripmime!\n";
    }
    $self->setup->ripmime() or return '';
    return "--enable-ripmime=$bin ";
};

sub simscan_spamassassin {
    my ($self) = @_;

    return '' if ! $self->conf->{'simscan_spamassassin'};

    my $spamc = $self->util->find_bin( "spamc", fatal => 0 );
    my $cmd = "--enable-spam=y --enable-spamc-user=y --enable-spamc=$spamc ";

    my $spamc_args = $self->conf->{'simscan_spamc_args'};
    $cmd .= "--enable-spamc-args=$spamc_args " if $spamc_args;

    if ( $self->conf->{'simscan_received'} ) {
        my $bin = $self->util->find_bin( "spamassassin", fatal => 0 );
        croak "couldn't find $bin, install SpamAssassin!\n" if !-x $bin;
        $cmd .= "--enable-spamassassin-path=$bin ";
    }
    return $cmd;
};

sub test {
    my $self  = shift;
    my %p = validate( @_, { $self->get_std_opts },);

    my $qdir = $self->conf->{'qmail_dir'};

    if ( ! $self->conf->{'install_simscan'} ) {
        print "simscan installation disabled, skipping test!\n";
        return;
    }

    print "testing simscan...";
    my $scan = "$qdir/bin/simscan";
    unless ( -x $scan ) {
        print "FAILURE: Simscan could not be found at $scan!\n";
        return;
    }

    $ENV{"QMAILQUEUE"} = $scan;
    $self->setup->test->email_send;
}

1;
