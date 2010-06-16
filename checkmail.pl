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
            from => 'mailtest@testhost.domain.example',
            # a syntactically valid "random" - reliably not existing - localpart
            rand => 'ZOq62fow1i'
           );

################################### Modules ####################################
use strict;
use File::Basename;
use Getopt::Std;
use Net::DNS;
use Net::SMTP;

################################# Main program #################################

$Getopt::Std::STANDARD_HELP_VERSION = 1;
my $myself = basename($0);

# read commandline options
my %options;
getopts('Vhqlrf:m:', \%options);

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
  print "Usage: $myself [-hqlr] [-m <host>] <address>|-f <file>\n";
  print "Options: -V  display copyright and version\n";
  print "         -h  show documentation\n";
  print "         -q  quiet (no output, just exit with 0/1/2/3)\n";
  print "         -l  extended logging\n";
  print "         -r  test random address to verify verification\n";
  print "  -m <host>  no DNS lookup, just test this host\n";
  print "  <address>  mail address to check\n\n";
  print "  -f <file>  parse file (one address per line)\n";
  exit(100);
};

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
  (undef,my $domain) = splitaddress($address);
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
      $status = connection_failed();
    # delivery attempt was successful?
    } elsif ($success) {
      # -r: try random address (which should be guaranteed to be invalid)
      if ($options{'r'}) {
        (undef,my $domain) = splitaddress($address);
        my ($success,$code,@message) = try_rcpt_to(\$smtp,$config{'rand'}.'@'.$domain,$logr);
        # connection failure?
        if ($success < 0) {
          $status = connection_failed();
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

################################# splitaddress #################################
# split mail address into local and domain part
# IN : $address: a mail address
# OUT: $local : local part
#      $domain: domain part
sub splitaddress {
  my($address)=@_;
  (my $lp = $address) =~ s/^([^@]+)@.*/$1/;
  (my $domain = $address) =~ s/[^@]+\@(\S*)$/$1/;
  return ($lp,$domain);
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
# OUT: $success: true or false
#      $code   : SMTP status code
#      $message: SMTP status message
#      \$log will be changed
sub try_rcpt_to {
  my($smtpr,$recipient,$logr)=@_;
  $$logr .= sprintf("RCPT TO:<%s>\n",$recipient);
  my $success = $$smtpr->to($recipient);
  if ($$smtpr->code) {
    log_smtp_reply($logr,$$smtpr->code,$$smtpr->message);
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

############################## connection_failed ###############################
# print failure message and return status 1
# OUT: 1
sub connection_failed {
  print "  > Connection failure.\n" if !($options{'q'});
  return 1;
}
