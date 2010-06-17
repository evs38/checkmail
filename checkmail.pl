#! /usr/bin/perl -W
#
# checkmail Version 0.3 by Thomas Hochstein
#
# This script tries to verify the deliverability of (a) mail address(es).
# 
# Copyright (c) 2002-2010 Thomas Hochstein <thh@inter.net>
#
# It can be redistributed and/or modified under the same terms under 
# which Perl itself is published.

our $VERSION = "0.3";

################################# Configuration ################################
# Please fill in a working configuration!
my %config=(
            # value used for HELO/EHLO - a valid hostname you own
            helo => 'testhost.domain.example',
            # value used for MAIL FROM: - a valid address under your control
            from => 'mailtest@testhost.domain.example'
           );

################################### Modules ####################################
use strict;
use File::Basename;
use Getopt::Std;
use Mail::Address;
use Net::DNS;
use Net::SMTP;

################################# Main program #################################

$Getopt::Std::STANDARD_HELP_VERSION = 1;
my $myself = basename($0);

# read commandline options
my %options;
getopts('Vhqlrf:m:s:e:', \%options);

# -V: display version
if ($options{'V'}) {
  print "$myself v $VERSION\nCopyright (c) 2010 Thomas Hochstein <thh\@inter.net>\n";
  print "This program is free software; you may redistribute it and/or modify it under the same terms as Perl itself.\n";
  exit(100);
};

# -h: feed myself to perldoc
if ($options{'h'}) {
  exec('perldoc', $0);
  exit(100);
};

# display usage information if neither -f nor an address are present
if (!$options{'f'} and !$ARGV[0]) {
  print "Usage: $myself [-hqlr] [-m <host>] [-s <from>] [-e <EHLO>] <address>|-f <file>\n";
  print "Options: -V  display copyright and version\n";
  print "         -h  show documentation\n";
  print "         -q  quiet (no output, just exit with 0/1/2/3)\n";
  print "         -l  extended logging\n";
  print "         -r  test random address to verify verification\n";
  print "  -m <host>  no DNS lookup, just test this host\n";
  print "  -s <from>  override configured value for MAIL FROM\n";
  print "  -e <EHLO>  override configured value for EHLO\n";
  print "  <address>  mail address to check\n\n";
  print "  -f <file>  parse file (one address per line)\n";
  exit(100);
};

# -s / -e: override configuration
$config{'from'} = $options{'s'} if $options{'s'};
$config{'helo'} = $options{'e'} if $options{'e'};

# -f: open file and read addresses to @adresses
my @addresses;
if ($options{'f'}) {
 if (-e $options{'f'}) {
  open FILE, "<$options{'f'}" or die("$myself ERROR: Could not open file $options{'f'} for reading: $!");
 } else {
  die("$myself ERROR: File $options{'f'} does not exist!\n");
 };
 while(<FILE>) {
  chomp;
  push(@addresses,$_);
 };
 close FILE;
# fill @adresses with single address to check
 } else {
  push(@addresses,$ARGV[0]);
};

# loop over each address and test it
my (%targets,$curstat,$status,$log,$message);
foreach (@addresses) {
  my $address = $_;
  my $domain = Mail::Address->new('',$address)->host;
  printf("  * Testing %s ...\n",$address) if !($options{'q'});
  $log .=  "\n===== BEGIN $address =====\n";
  # get list of target hosts or take host forced via -m
  if (!$options{'m'}) {
	  %targets = %{gettargets($domain,\$log)};
  } else {
    $message = sprintf("Connection to %s forced by -m.\n",$options{'m'});
    $log .= $message;
    print "    $message" if !($options{'q'});
    # just one target host with preference 0
    $targets{$options{'m'}} = 0;
  };
  if (%targets) {
    $curstat = checkaddress($address,\%targets,\$log);
  } else {
    $curstat = 2;
    $message = 'DNS lookup failure';
    printf("  > Address is INVALID (%s).\n",$message) if !($options{'q'});
    $log .= $message . '.';
  };
  $log   .=  "====== END $address ======\n";
  $status = $curstat if (!defined($status) or $curstat > $status);
};

print $log if ($options{'l'});

# status 0: valid / batch processing
#        1: connection failed or temporary failure
#        2: invalid
#        3: cannot verify
#D print "\n-> EXIT $status\n";
exit($status);

################################## gettargets ##################################
# get mail exchanger(s) or A record(s) for a domain
# IN : $domain: domain to query the DNS for
# OUT: \%targets: reference to a hash containing a list of target hosts
sub gettargets {
  my ($domain,$logr) = @_;
  # resolver objekt
  my $resolver = Net::DNS::Resolver->new(udp_timeout => 15, tcp_timeout => 15);

  my %targets;
  # get MX record(s) as a list sorted by preference
  if (my @mxrr = mx($resolver,$domain)) {
    print_dns_result($domain,'MX',scalar(@mxrr),undef,$logr);
    foreach my $rr (@mxrr) {
	 $targets{$rr->exchange} = $rr->preference;
	 $$logr .= sprintf("(%d) %s\n",$rr->preference,$rr->exchange);
    };
  # no MX record found; log and try A record(s)
  } else {
    print_dns_result($domain,'MX',undef,$resolver->errorstring,$logr);
    print("    Falling back to A record ...\n") if !($options{'q'});
	# get A record(s)
    if (my $query = $resolver->query($domain,'A','IN')) {
      print_dns_result($domain,'A',$query->header->ancount,undef,$logr);
      foreach my $rr ($query->answer) {
        $targets{$rr->address} = 0;
        $$logr .= sprintf("- %s\n",$rr->address);
      };
    # no A record found either; log and fail
    } else {
      print_dns_result($domain,'A',undef,$resolver->errorstring,$logr);
      printf("    %s has neither MX nor A records - mail cannot be delivered.\n",$domain) if !($options{'q'});
    };
  };
  return \%targets;
};

################################# checkaddress #################################
# test address for deliverability
# IN : $address: adress to be tested
#      \%targets: reference to a hash containing a list of MX hosts
#      \$log    : reference to the log (to be printed out via -l)
# OUT: ---
#      \$log will be changed
sub checkaddress {
  my ($address,$targetsr,$logr) = @_;
  my %targets = %{$targetsr};
  my $status;
  # walk %targets in order of preference
  foreach my $host (sort { $targets{$a} <=> $targets{$b} } keys %targets) {
    printf("  / Trying %s (%s) with %s\n",$host,$targets{$host} || 'A',$address) if !($options{'q'});
	  $$logr .= sprintf("%s:\n%s\n",$host,"-" x (length($host)+1));
	  $status = checksmtp($address,$host,$logr);
	  last if ($status != 1);
  };
  return $status;
};

################################### checksmtp ##################################
# connect to a remote machine on port 25 and test deliverability of a mail
# address by doing the SMTP dialog until RCPT TO stage
# IN : $address: address to test
#      $target : target host
#      \$log    : reference to the log (to be printed out via -l)
# OUT: .........: reference to a hash containing a list of target hosts
#      \$log will be changed
sub checksmtp {
  my ($address,$target,$logr) = @_;
  my ($status);
  # start SMTP connection
  if (my $smtp = Net::SMTP->new($target,Hello => $config{'helo'},Timeout => 30)) {
    $$logr .= $smtp->banner; # Net::SMTP doesn't seem to support multiline greetings.
    $$logr .= "EHLO $config{'helo'}\n";
    log_smtp_reply($logr,$smtp->code,$smtp->message);
    $smtp->mail($config{'from'});
    $$logr .= "MAIL FROM:<$config{'from'}>\n";
    log_smtp_reply($logr,$smtp->code,$smtp->message);
    # test address
    my ($success,$code,@message) = try_rcpt_to(\$smtp,$address,$logr);
    # connection failure?
    if ($success < 0) {
      $status = connection_failed(@message);
    # delivery attempt was successful?
    } elsif ($success) {
      # -r: try random address (which should be guaranteed to be invalid)
      if ($options{'r'}) {
        my ($success,$code,@message) = try_rcpt_to(\$smtp,create_rand_addr(Mail::Address->new('',$address)->host),$logr);
        # connection failure?
        if ($success < 0) {
          $status = connection_failed(@message);
        # verification impossible?
        } elsif ($success) {
          $status = 3;
          print "  > Address verificaton impossible. You'll have to send a test mail ...\n" if !($options{'q'});
        }
      }
      # if -r is not set or status was not set to 3: valid address
      if (!defined($status)) {
        $status = 0;
        print "  > Address is valid.\n" if !($options{'q'});
      };
    # delivery attempt failed?
    } else {
      $status = 2;
      print "  > Address is INVALID:\n" if !($options{'q'});
      print '    ' . join('    ',@message) if !($options{'q'});
    }
    # terminate SMTP connection
    $smtp->quit;
    $$logr .= "QUIT\n";
    log_smtp_reply($logr,$smtp->code,$smtp->message);
  } else {
    # SMTP connection failed / timeout
    $status = connection_failed();
    $$logr .= "---Connection failure---\n";
  };
  return $status;
}

############################### create_rand_addr ###############################
# create a random mail address
# IN : $domain: the domain part
# OUT: $address: the address
sub create_rand_addr {
  my($domain)=@_;
  my $allowed = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789-+_=';
  my $address = '';
  while (length($address) < 15) { 
    $address .= substr($allowed, (int(rand(length($allowed)))),1);
  };
  return ($address.'@'.$domain);
};

################################ parse_dns_reply ###############################
# parse DNS response codes and return code and description
# IN : $response: a DNS response code
# OUT: "$response ($desciption)"
sub parse_dns_reply {
  my($response)=@_;
  my %dnsrespcodes = (NOERROR  => 'empty response',
                      NXDOMAIN => 'non-existent domain',
                      SERVFAIL => 'DNS server failure',
                      REFUSED  => 'DNS query refused',
                      FORMERR  => 'format error',
                      NOTIMP   => 'not implemented');
  if(defined($dnsrespcodes{$response})) {
    return sprintf('%s (%s)',$response,$dnsrespcodes{$response});
  } else {
    return $response;
  };
};

############################### print_dns_result ###############################
# print and log result of DNS query
# IN : $domain: domain the DNS was queried for
#      $type  : record type (MX, A, ...)
#      $count : number of records found
#      $error : DNS response code
#      \$log : reference to the log (to be printed out via -l)
# OUT: ---
#      \$log will be changed
sub print_dns_result {
  my ($domain,$type,$count,$error,$logr) = @_;
  if (defined($count)) {
    printf("    %d %s record(s) found for %s\n",$count,$type,$domain) if !($options{'q'});
    $$logr .= sprintf("%s DNS record(s):\n",$type);
  } else {
    printf("    No %s records found for %s: %s\n",$type,$domain,parse_dns_reply($error)) if !($options{'q'});
    $$logr .= sprintf("No %s records found: %s\n",$type,parse_dns_reply($error));
  };
  return;
};

################################## try_rcpt_to #################################
# send RCPT TO and return replies
# IN : \$smtp    : a reference to an SMTP object
#      $recipient: a mail address
#      \$log     : reference to the log (to be printed out via -l)
# OUT: $success: exit code (0 for false, 1 for true, -1 for tempfail)
#      $code   : SMTP status code
#      $message: SMTP status message
#      \$log will be changed
sub try_rcpt_to {
  my($smtpr,$recipient,$logr)=@_;
  $$logr .= sprintf("RCPT TO:<%s>\n",$recipient);
  my $success;
  $$smtpr->to($recipient);
  if ($$smtpr->code) {
    log_smtp_reply($logr,$$smtpr->code,$$smtpr->message);
    $success = analyze_smtp_reply($$smtpr->code,$$smtpr->message);
  } else {
    $success = -1;
    $$logr .= "---Connection failure---\n";
  };
  return ($success,$$smtpr->code,$$smtpr->message);
};

################################ log_smtp_reply ################################
# log result of SMTP command
# IN : \$log    : reference to the log (to be printed out via -l)
#      $code    : SMTP status code
#      @message : SMTP status message
# OUT: ---
#      \$log will be changed
sub log_smtp_reply {
  my($logr,$code,@message)=@_;
  $$logr .= sprintf('%s %s',$code,join('- ',@message));
  return;
}

############################### analyze_smtp_reply ##############################
# analyze SMTP response codes and messages
# IN : $code    : SMTP status code
#      @message : SMTP status message
# OUT: exit code (0 for false, 1 for true, -1 for tempfail)
sub analyze_smtp_reply {
  my($code,@message)=@_;
  my $type = substr($code, 0, 1);
  if ($type == 2) {
    return 1;
  } elsif ($type == 5) {
    return 0;
  } elsif ($type == 4) {
    return -1;
  };
  return -1;
}

############################## connection_failed ###############################
# print failure message and return status 1
# IN : @message : SMTP status message
# OUT: 1
sub connection_failed {
  my(@message)=@_;
  print "  ! Connection failed or other temporary failure.\n" if !($options{'q'});
  printf("    %s\n",join('    ',@message)) if @message;
  return 1;
}

__END__

################################ Documentation #################################

=head1 NAME

checkmail - check deliverability of a mail address

=head1 SYNOPSIS

B<checkmail> [B<-Vhqlr>] [B<-m> I<host>]  [-s I<sender>] [-e I<EHLO>] I<address>|B<-f> I<file>

=head1 REQUIREMENTS

=over 2

=item -

Perl 5.8 or later

=item -

File::Basename

=item -

Getopt::Std

=item -

Mail::Address I<(CPAN)>

=item -

Net::DNS I<(CPAN)>

=item -

Net::SMTP

=back

Furthermore you'll need a working DNS installation.

=head1 DESCRIPTION

checkmail checks the vailidity / deliverability of a mail address.
You may submit just one address as the last argument or a file
containing one address on each line using the B<-f> option.

=head2 Configuration

For the time being, all configuration is done in the script. You have
to set the following elements of the %config hash:

=over 4

=item B<$config{'helo'}>

The hostname to be used for I<HELO> or I<EHLO> in the SMTP dialog.

=item B<$config{'from'}>

The sender address to be used for I<MAIL FROM> while testing.

=back

You may override that configuration by using the B<-e> and B<-s>
command line options.

=head2 Usage

After configuring the script you may run your first test with

    checkmail user@example.org

B<checkmail> will try to determine the mail exchanger(s) (MX)
responsible for I<example.org> by querying the DNS for the respective
MX records and then try to connect via SMTP (on port 25) to each of
them in order of precedence (if necessary). It will run through the
SMTP dialog until just before the I<DATA> stage, i.e. doing I<EHLO>,
I<MAIL FROM> and I<RCPT TO>. If no MX is defined, B<checkmail> will
fall back to the I<example.org> host itself, provided there is at
least one A record defined in the DNS. If there are neither MX nor A
records for I<example.org>, mail is not deliverable and B<checkmail>
will fail accordingly. If no host can be reached, B<checkmail> will
fail, too. Finally B<checkmail> will fail if mail to the given
recipient is not accepted by the respective host.

If B<checkmail> fails, you'll not be able to deliver mail to that
address - at least not using the configured sender address and from
the host you're testing from. However, the opposite is not true: a
mail you send may still not be delivered even if a test via
B<checkmail> succeeds. The receiving entity may reject your mail after
the I<DATA> stage, due to content checking or without any special
reason, or it may even drop, filter or bounce your mail after finally
accepting it. There is no way to be sure a mail will be accepted short
of sending a real mail to the address in question.

You may, however, try to detect hosts that will happily accept any and
all recipient in the SMTP dialog and just reject your mail later on,
for example to defeat exactly the kind of check you try to do.
B<checkmail> will do that by submitting a recipient address that is
known to be invalid; if that address is accepted, too, you'll know
that you can't reliably check the validity of any address on that
host. You can force that check by using the B<-r> option.

If you don't want to see just the results of your test, you can get a
B<complete log> of the SMTP dialog by using the B<-l> option. That may be
helpful to test for temporary failure conditions.

On the other hand you may use the B<-q> option to suppress all output;
B<checkmail> will then terminate with one of the following B<exit
status>:
       
=over 4

=item B<0>

address(es) seem/seems to be valid

=item B<1>

temporary error (connection failure or temporary failure)

=item B<2>

address is invalid

=item B<3>

address cannot reliably be checked (test using B<-r> failed)

=back

You can do B<batch processing> using B<-f> and submitting a file with
one address on each line. In that case the exit status is set to the
highest value generated by testing all addresses, i.e. it is set to
B<0> if and only if no adress failed, but to B<2> if even one address
failed and to B<3> if even one addresses couldn't reliably be checked.

And finally you can B<suppress DNS lookups> for MX and A records and
just force B<checkmail> to connect to a particular host using the
B<-m> option.

B<Please note:> You shouldn't try to validate addresses while working
from a dial-up or blacklisted host. If in doubt, use the B<-l> option
to have a closer look on the SMTP dialog yourself.

=head1 OPTIONS

=over 3

=item B<-V> (version)

Print out version and copyright information on B<checkmail> and exit.

=item B<-h> (help)

Print this man page and exit.

=item B<-q> (quit)

Suppress output and just terminate with a specific exit status.

=item B<-l> (log)

Log and print out the whole SMTP dialog.

=item B<-r> (random address)

Also try a reliably invalid address to catch hosts that try undermine
address verification.

=item B<-m> I<host> (MX to use)

Force a connection to I<host> to check deliverability to that
particular host irrespective of DNS entries. For example:

    checkmail -m test.host.example user@domain.example

=item B<-s> I<sender> (value for MAIL FROM)

Override configuration and use I<sender> for MAIL FROM.

=item B<-e> I<EHLO> (value for EHLO)

Override configuration and use I<EHLO> for EHLO.

=item B<-f> I<file> (file)

Process all addresses from I<file> (one on each line).

=back

=head1 INSTALLATION

Just copy checkmail to some directory and get started.

You can run your first test with

    checkmail user@example.org

=head1 ENVIRONMENT

See documentation of I<Net::DNS::Resolver>.

=head1 FILES

=over 4

=item F<checkmail.pl>

The script itself.

=back

=head1 BUGS

Please report any bugs or feature request to the author or use the
bug tracker at L<http://bugs.th-h.de/>!

=head1 SEE ALSO

L<http://th-h.de/download/scripts.php> will have the current
version of this program.

This program is maintained using the Git version control system. You
may clone L<git://code.th-h.de/mail/checkmail.git> to check out the
current development tree or browse it on the web via
L<http://code.th-h.de/?p=mail/checkmail.git>.

=head1 AUTHOR

Thomas Hochstein <thh@inter.net>

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2002-2010 Thomas Hochstein <thh@inter.net>

This program is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut
