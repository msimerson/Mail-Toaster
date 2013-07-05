package Mail::Toaster::Base;
use strict;
use warnings;

our $VERSION = '5.41';

use Params::Validate ':all';

our $verbose = our $last_audit = our $last_error = 0; # package variables
our (@audit, @errors); # package wide message stacks
our ($conf, $log);
our ($apache, $darwin, $dns, $freebsd, $qmail, $logs, $mysql, $setup, $toaster, $util );

our %std_opts = (
        test_ok => { type => BOOLEAN, optional => 1 },
        verbose => { type => BOOLEAN, optional => 1, default => $verbose },
        fatal   => { type => BOOLEAN, optional => 1, default => 1 },
        quiet   => { type => BOOLEAN, optional => 1, default => 0 },
    );

sub new {
    my $class = shift;
    my %p = validate( @_, { %std_opts } );
    my @caller = caller;
#   warn sprintf( "Base.pm loaded by %s, %s, %s\n", @caller ) if $caller[0] ne 'main';
    return bless {}, $class;
}

sub apache {
    my $self = shift;
    return $apache if ref $apache;
    require Mail::Toaster::Apache;
    return $apache = Mail::Toaster::Apache->new();
}

sub darwin {
    my $self = shift;
    return $darwin if ref $darwin;
    require Mail::Toaster::Darwin;
    return $darwin = Mail::Toaster::Darwin->new();
}

sub dns {
    my $self = shift;
    return $dns if ref $dns;
    require Mail::Toaster::DNS;
    return $dns = Mail::Toaster::DNS->new();
}

sub freebsd {
    my $self = shift;
    return $freebsd if ref $freebsd;
    require Mail::Toaster::FreeBSD;
    return $freebsd = Mail::Toaster::FreeBSD->new();
}

sub logs {
    my $self = shift;
    return $logs if ref $logs;
    require Mail::Toaster::Logs;
    return $logs = Mail::Toaster::Logs->new();
}

sub mysql {
    my $self = shift;
    return $mysql if ref $mysql;
    require Mail::Toaster::Mysql;
    return $mysql = Mail::Toaster::Mysql->new();
}

sub qmail {
    my $self = shift;
    return $qmail if ref $qmail;
    require Mail::Toaster::Qmail;
    return $qmail = Mail::Toaster::Qmail->new();
}

sub setup {
    my $self = shift;
    return $setup if ref $setup;
    require Mail::Toaster::Setup;
    return $setup = Mail::Toaster::Setup->new();
}

sub toaster {
    my $self = shift;
    return $toaster if ref $toaster;
    require Mail::Toaster;
    return $toaster = Mail::Toaster->new();
}

sub util {
    my $self = shift;
    return $util if ref $util;
    require Mail::Toaster::Utility;
    return $util = Mail::Toaster::Utility->new();
}

sub verbose {
    return $verbose if 1 == scalar @_;
    return $verbose = $std_opts{verbose}{default} = $_[1];
};

sub conf {
    $conf = $_[1] if $_[1];
    return $conf if $conf;
    $conf = $_[0]->util->parse_config( "toaster-watcher.conf" );
};

sub audit {
    my $self = shift;
    my $mess = shift;

    my %p = validate( @_, { %std_opts } );

    if ($mess) {
        push @audit, $mess;
        print "$mess\n" if $verbose || $p{verbose};
    }

    return \@audit;
}

sub dump_audit {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );

    if ( 0 == scalar @audit ) {
        print "dump_audit: no audit messages\n" if $p{verbose};
        return 1;
    };

    if ( $last_audit == scalar @audit ) {
        print "dump_audit: all messages dumped\n" if $p{verbose};
        return 1;
    };

    if ( $p{quiet} ) {   # hide/mask unreported messages
        $last_audit = scalar @audit;
        $last_error = scalar @errors;
        return 1;
    };

    print "\n\t\t\tAudit History Report \n\n";
    for( my $i = $last_audit; $i < scalar @audit; $i++ ) {
        print "   $audit[$i]\n";
        $last_audit++;
    };
    return 1;
};

sub error {
    my $self = shift;
    my $message = shift;
    my %p = validate( @_,
        {   location => { type => SCALAR,  optional => 1, },
            %std_opts,
        },
    );

    my $location = $p{location};
    my $verbose = $p{verbose} || $verbose;

    if ( $message ) {
        my @caller = $p{caller} || caller;

        # append message and location to the error stack
        push @errors, {
            errmsg => $message,
            errloc => $location || join( ", ", $caller[0], $caller[2] ),
            };
    }
    else {
        $message = $errors[-1];
    }

    if ( $verbose || $p{fatal} ) {
        $self->dump_audit;
        $self->dump_errors;
    }

    exit 1 if $p{fatal};
    return;
}

sub dump_errors {
    my $self = shift;

    if ( $last_error == scalar @errors ) {
        print "all error messages dumped!\n" if $verbose;
        return 1;
    };

    print "\n\t\t\t Error History Report \n\n";
    my $i = 0;
    foreach ( @errors ) {
        $i++;
        next if $i < $last_error;
        my $msg = $_->{errmsg};
        my $loc = " at $_->{errloc}";
        print $msg;
        for (my $j=length($msg); $j < 90-length($loc); $j++) { print '.'; };
        print " $loc\n";
    };
    print "\n";
    $last_error = $i;
    return 1;
};

sub get_std_args {
    my $self = shift;
    my %p = @_;
    my %args;
    foreach ( qw/ verbose fatal test_ok quiet / ) {
        if ( defined $p{$_} ) {
            $args{$_} = $p{$_};
            next;
        };
        if ( $self->{$_} ) {
            $args{$_} = $self->{$_};
        };
    };
    return %args;
};

sub get_std_opts { return %std_opts };

sub log {
    my $self = shift;
    my $mess = shift or return;

    my $logfile = $conf->{'toaster_watcher_log'} or do {
        warn "ERROR: no log file defined!\n";
        return;
    };
    return if ( -e $logfile && ! -w $logfile );

    $self->util->logfile_append(
        file  => $logfile,
        lines => [$mess],
        fatal => 0,
    );
};


1;

