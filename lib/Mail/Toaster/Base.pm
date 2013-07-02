package Mail::Toaster::Base;
use strict;
use warnings;

our $VERSION = '5.41';

use Params::Validate ':all';

our (@audit, $last_audit, @errors, $last_error, $debug, $verbose); # package variables
our ($conf, $apache, $darwin, $dns, $freebsd, $log, $qmail, $setup, $toaster, $util );

our %std_opts = (
        test_ok => { type => BOOLEAN, optional => 1 },
        debug   => { type => BOOLEAN, optional => 1, default => 1 },
        fatal   => { type => BOOLEAN, optional => 1, default => 1 },
        quiet   => { type => BOOLEAN, optional => 1, default => 0 },
    );

sub new {
    my $class = shift;

    my %p = validate( @_, { %std_opts } );

    my $self = {
        audit  => [],
        errors => [],
        last_audit => 0,
        last_error => 0,
        debug  => $p{debug},
        fatal  => $p{fatal},
        quiet  => undef,
    };
    bless( $self, $class );

    my @caller = caller;
    warn sprintf( "Base.pm loaded by %s, %s, %s\n", @caller ) if $caller[0] ne 'main';
    return $self;
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
    return $_[0]->{verbose} if 1 == scalar @_;
    return $_[0]->{verbose} = $_[1];
};

sub conf {
    $conf = $_[1] if $_[1];
    return $conf if $conf;
    $conf = $_[0]->util->parse_config( "toaster-watcher.conf" );
};

sub debug {
    return $_[0]->{debug} if 1 == scalar @_;
    return $_[0]->{debug} = $_[1];
};

sub audit {
    my $self = shift;
    my $mess = shift;

    my %p = validate( @_, { %std_opts } );

    if ($mess) {
        push @audit, $mess;
        print "$mess\n" if $self->{debug} || $p{debug};
    }

    return \@audit;
}

sub dump_audit {
    my $self = shift;
    my %p = validate( @_, { %std_opts } );

    scalar @audit or return;
    return if ! $last_audit;
    return if $last_audit == scalar @audit; # nothing new

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
    my $debug = $p{debug};
    my $fatal = $p{fatal};

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

    if ( $debug || $fatal ) {
        $self->dump_audit();
        $self->dump_errors();
    }

    exit 1 if $fatal;
    return;
}

sub dump_errors {
    my $self = shift;
    my $last_error or return;

    return if $last_error == scalar @errors; # everything dumped

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
    return;
};

sub get_std_args {
    my $self = shift;
    my %p = @_;
    my %args;
    foreach ( qw/ debug fatal test_ok quiet / ) {
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

