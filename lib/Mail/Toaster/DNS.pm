package Mail::Toaster::DNS;

use strict;
use warnings;

our $VERSION = '5.33';

use Carp;
use Params::Validate qw( :all );

use lib 'lib';
use Mail::Toaster 5.33;

my ( $log, $toaster, $util, %std_opts );

sub new {
    my $class = shift;
    my %p     = validate( @_,
        {   'log' => { type => OBJECT,  optional => 1 },
            fatal => { type => BOOLEAN, optional => 1, default => 1 },
            debug => { type => BOOLEAN, optional => 1 },
        }
    );

    $log = $toaster = $p{'log'};
    $util = $log->get_util;

    my $debug = $log->get_debug;  # inherit from our parent
    my $fatal = $log->get_fatal;
    $debug = $p{debug} if defined $p{debug};  # explicity overridden
    $fatal = $p{fatal} if defined $p{fatal};

    my $self = {
        'log' => $log,
        debug => $debug,
        fatal => $fatal,
    };
    bless $self, $class;

    # globally scoped hash, populated with defaults as requested by the caller
    %std_opts = (
        'test_ok' => { type => BOOLEAN, optional => 1 },
        'fatal'   => { type => BOOLEAN, optional => 1, default => $fatal },
        'debug'   => { type => BOOLEAN, optional => 1, default => $debug },
        'quiet'   => { type => BOOLEAN, optional => 1, default => 0 },
    );

    return $self;
}

sub is_ip_address {
    my $self = shift;
    my %p = validate(
        @_,
        {   'ip'  => { type => SCALAR, },
            'rbl' => { type => SCALAR, },
            %std_opts,
        },
    );

    my %args = $toaster->get_std_args( %p );
    my ( $ip, $rbl ) = ( $p{'ip'}, $p{'rbl'} );

    $ip =~ /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/
        or return $log->error( "invalid IP address format: $ip", %args);

    return "$4.$3.$2.$1.$rbl";
}

sub rbl_test {
    my $self = shift;
    my %p = validate(
        @_, {   
            'zone'  => SCALAR,
            'conf'  => {
                    type     => HASHREF,
                    optional => 1,
                    default  => { rbl_enable_lookup_using => 'net-dns' }
                },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    my ( $conf, $zone ) = ( $p{'conf'}, $p{'zone'} );

    #	$net_dns->tcp_timeout(5);   # really shouldn't matter
    #	$net_dns->udp_timeout(5);

    # make sure zone has active name servers
    return if ! $self->rbl_test_ns( conf => $conf, rbl => $zone );

    # test an IP that should always return an A record
    return if ! $self->rbl_test_positive_ip( conf => $conf, rbl => $zone );

    # test an IP that should always yield a negative response
    return if ! $self->rbl_test_negative_ip( conf => $conf, rbl => $zone );

    return 1;
}

sub rbl_test_ns {
    my $self = shift;
    my %p = validate( @_, {   
            'rbl'   => SCALAR,
            'conf'  => { type => HASHREF, optional => 1, },
            %std_opts,
        },
    );

    my ( $conf, $rbl ) = ( $p{'conf'}, $p{'rbl'} );
    my %args = $toaster->get_std_args( %p );

    my $testns = $rbl;

    # overrides for dnsbl's where the NS doesn't match the dnsbl name
    if    ( $rbl =~ /rbl\.cluecentral\.net$/ ) { $testns = "rbl.cluecentral.net"; }
    elsif ( $rbl eq "spews.blackhole.us" ) { $testns = "ls.spews.dnsbl.sorbs.net"; }
    elsif ( $rbl =~ /\.dnsbl\.sorbs\.net$/ ) { $testns = "dnsbl.sorbs.net" }

    my $ns = $self->resolve(record=>$testns, type=>'NS', %args ) || 0;

    $log->audit( "found $ns NS servers");
    return $ns;
}

sub rbl_test_positive_ip {
    my $self = shift;
    my %p = validate(
        @_,
        {   'conf' => { type => HASHREF, optional => 1, },
            'rbl'  => { type => SCALAR, },
            %std_opts,
        },
    );

    my %args = $toaster->get_std_args( %p );
    my ( $conf, $rbl ) = ( $p{'conf'}, $p{'rbl'} );

    # an IP that should always return an A record
    # for most RBL's this is 127.0.0.2, (2.0.0.127.bl.example.com)
    my $ip      = 0;
    my $test_ip = $rbl eq "korea.services.net"     ? "61.96.1.1"
                : $rbl eq "kr.rbl.cluecentral.net" ? "61.96.1.1"
                : $rbl eq "cn-kr.blackholes.us"    ? "61.96.1.1"
                : $rbl eq "cn.rbl.cluecentral.net" ? "210.52.214.8"
                : $rbl =~ /rfc-ignorant\.org$/     ? 0         # no test ips!
                : "127.0.0.2";

    return if ! $test_ip;
    $log->audit( "rbl_test_positive_ip: testing with ip $test_ip");

    my $test = $self->is_ip_address( ip => $test_ip, rbl => $rbl, %args ) or return;
    $log->audit( "\tquerying $test..." );

    my @rrs = $self->resolve( record => $test, type => 'A' );

    foreach my $rr ( @rrs ) {
        next unless $rr =~ /127\.[0-1]\.[0-9]{1,3}/;
        $ip++;
        $log->audit( " from $rr matched.");
    }

    $log->audit( "rbl_test_positive_ip: we have $ip addresses.");
    return $ip;
}

sub rbl_test_negative_ip {
    my $self = shift;
    my %p = validate( @_, {   
            'rbl'   => SCALAR,
            'conf'  => { type => HASHREF, optional => 1, },
            %std_opts,
        },
    );

    my %args = $toaster->get_std_args( %p );
    my ( $conf, $rbl ) = ( $p{'conf'}, $p{'rbl'} );

    my $test_ip = $rbl eq "korea.services.net"     ? "208.75.177.127"
                : $rbl eq "kr.rbl.cluecentral.net" ? "208.75.177.127"
                : $rbl eq "cn.rbl.cluecentral.net" ? "208.75.177.127"
                : $rbl eq "us.rbl.cluecentral.net" ? "210.52.214.8"
                : "208.75.177.127";

    my $test = $self->is_ip_address( ip => $test_ip, rbl => $rbl, %args ) or return;
    $log->audit( "querying $test" );

    my @rrs = $self->resolve( record => $test, type => 'A', %args );
    return 1 if scalar @rrs == 0;

    foreach my $rr ( @rrs ) {
        next unless $rr =~ /127\.0\.0/;
        $log->audit( " from $rr matched.");
    }
    return 0;
}

sub resolve {
    my $self = shift;
    my %p = validate(@_, {
            record => SCALAR,
            type   => SCALAR,
            timeout=> { type=>SCALAR,  optional=>1, default=>5  },
            conf   => { type=>HASHREF, optional=>1, },
            %std_opts,
        },
    );

    my ( $conf, $record, $type ) = ( $p{'conf'}, $p{'record'}, $p{'type'} );
    #my %args = $toaster->get_std_args( %p );

    return $self->resolve_dig($record, $type ) 
        if ( $conf 
            && $conf->{'rbl_enable_lookup_using'}
            && $conf->{'rbl_enable_lookup_using'} eq "dig" );

    return $self->resolve_dig($record, $type ) if ! $log->has_module("Net::DNS");
    return $self->resolve_net_dns($record, $type, $p{timeout} );
};

sub resolve_net_dns {
    my ($self, $record, $type, $timeout) = @_;

    $log->audit("resolving $record type $type with Net::DNS");

    require Net::DNS;
    my $net_dns = Net::DNS::Resolver->new;

    $timeout ||= '5';
    $net_dns->tcp_timeout($timeout);
    $net_dns->udp_timeout($timeout);

    my $query = $net_dns->query( $record, $type ) or
        return $log->error( "resolver query failed for $record: " . $net_dns->errorstring, fatal => 0);

    my @records;
    foreach my $rr (grep { $_->type eq $type } $query->answer ) {
        if ( $type eq "NS" ) {
            $log->audit("\t$record $type: ". $rr->nsdname );
            push @records, $rr->nsdname;
        } 
        elsif ( $type eq "A" ) {
            $log->audit("\t$record $type: ". $rr->address );
            push @records, $rr->address;
        }
        elsif ( $type eq "PTR" ) {
            push @records, $rr->rdatastr;
            $log->audit("\t$record $type: ". $rr->rdatastr );
        }
        else {
            $log->error("unknown record type: $type", fatal => 0);
        };
    }
    return @records;
};

sub resolve_dig {
    my ($self, $record, $type) = @_;

    $log->audit("resolving $record type $type with dig");

    my $dig = $util->find_bin( 'dig' );

    my @records;
    foreach (`$dig $type $record +short`) {
        chomp;
        push @records, $_;
        $log->audit("found $_");
    }
    return @records;
};

1;
__END__


=head1 NAME

Mail::Toaster::DNS - DNS functions, primarily to test RBLs


=head1 SYNOPSIS

A set of subroutines for testing rbls to verify that they are functioning properly. If Net::DNS is installed it will be used but we can also test using dig. 


=head1 DESCRIPTION

These functions are used by toaster-watcher to determine if RBL's are available when generating qmail's smtpd/run control file.


=head1 SUBROUTINES

=over 

=item new

Create a new DNS method:

   use Mail::Toaster;
   use Mail::Toaster::DNS;
   my $toaster = Mail::Toaster->new();
   my $dns     = Mail::Toaster::DNS->new(log=>$toaster);


=item rbl_test

After the demise of osirusoft and the DDoS attacks currently under way against RBL operators, this little subroutine becomes one of necessity for using RBL's on mail servers. It is called by the toaster-watcher.pl script to test the RBLs before including them in the SMTP invocation.

	my $r = $dns->rbl_test(conf=>$conf, zone=>"bl.example.com");
	if ($r) { print "bl tests good!" };

 arguments required:
    zone - the zone of a blacklist to test

Tests to make sure that name servers are found for the zone and then run several test queries against the zone to verify that the answers it returns are sane. We want to detect if a RBL operator does something like whitelist or blacklist the entire planet.

If the blacklist fails any test, the sub will return zero and you should not use that blacklist.


=item rbl_test_ns

	my $count = $t_dns->rbl_test_ns(
	    conf  => $conf, 
	    rbl   => $rbl, 
	);

 arguments required:
    rbl   - the reverse zone we use to test this rbl.

This script requires a zone name. It will then return a count of how many NS records exist for that zone. This sub is used by the rbl tests. Before we bother to look up addresses, we make sure valid nameservers are defined.


=item rbl_test_positive_ip

	$t_dns->rbl_test_positive_ip( rbl=>'sbl.spamhaus.org' );

 arguments required:
    rbl   - the reverse zone we use to test this rbl.

 arguments optional:
    conf

A positive test is a test that should always return a RBL match. If it should and does not, then we assume that RBL has been disabled by its operator.

Some RBLs have test IP(s) to verify they are working. For geographic RBLs (like korea.services.net) we can simply choose any IP within their allotted space. Most other RBLs use 127.0.0.2 as a positive test.

In the case of rfc-ignorant.org, they have no known test IPs and thus we have to skip testing them.


=item rbl_test_negative_ip

	$t_dns->rbl_test_negative_ip(conf=>$conf, rbl=>$rbl);

This test is a little more difficult as RBL operators don't typically have an IP that is whitelisted. The DNS location based lists are very easy to test negatively. For the rest I'm listing my own IP as the default unless the RBL has a specific one. At the very least, my site won't get blacklisted that way. ;) I'm open to better suggestions.



=back

=head1 AUTHOR

Matt Simerson <matt@tnpi.net>


=head1 BUGS

None known. Report any to author.


=head1 TODO

=head1 SEE ALSO

The following man/perldoc pages: 

 Mail::Toaster 
 Mail::Toaster::Conf
 toaster.conf
 toaster-watcher.conf

 http://mail-toaster.org/


=head1 COPYRIGHT AND LICENSE

Copyright (c) 2004-2008, The Network People, Inc.  All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut

