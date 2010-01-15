#!/usr/bin/perl -w
#
# checkmail.pl
##############

# (c) 2002-2005 Thomas Hochstein  <thh@inter.net>
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free
# Software Foundation; either version 2 of the License, or (at your option)
# any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
# more details.

# Versionsnummer ######################
$ver = '0.2 beta (20050803)';

# Modules #############################
use Getopt::Std;
use Net::DNS;
use Net::SMTP;

# Konfiguration #######################
# Hier  passende Werte einsetzen!     #
#######################################
%config=();
# HELO-/EHLO-Parameter - a valid hostname you own
$config{'helo'} = 'testhost.domain.example';
# MAIL FROM:-Parameter - a valid address you control
$config{'from'} = 'mailtest@testhost.domain.example';
# Zufaelliger Localpart fuer -r - a valid random localpart
$config{'rand'} = 'ZOq62fow1i';

################################################################
# Hauptprogramm #######################

# Konfiguration einlesen
my %options;
getopts('hqlrf:m:', \%options);

if ($options{'h'} or (!$options{'f'} and !$ARGV[0])) {
 print "$0 v $ver\nUsage: $0 [-hqlr] [-m <host>] -f <file>|<address>\n";
 print "Options: -h  display this notice\n";
 print "         -q  quiet (no output, just exit with 0/1/2/3)\n";
 print "         -l  extended logging\n";
 print "         -r  test random address to verify verification\n";
 print "  -m <host>  no DNS lookup, just test this host\n";
 print "  -f <file>  parse file (one address per line)\n";
 print "  <address>  mail address to check\n\n";
 exit(100);
};

if ($options{'f'}) {
 if (-e $options{'f'}) {
  open FILE, "<$options{'f'}" or die("ERROR: Could not open file $options{'f'} for reading: $!");
 } else {
  die("ERROR: File $options{'f'} does not exist!\n");
 };
 $log = '';
 while(<FILE>) {
  chomp;
  ($status,$log) = checkdns($_,$log);
 };
 close FILE;
 # force exit(0)
 $status = 0;
} else {
 ($status,$log) = checkdns($ARGV[0]);
};

print $log if ($options{'l'});

# status 0: valid / batch processing
#        1: invalid
#        2: cannot verify
#        3: temporary (?) failure
exit($status);

################################################################
# Subroutinen #########################

sub checkdns {
 # - fester Host angegeben (-m)?
 # - sonst: MX-Record ermitteln
 # - bei Verbindungsproblemen naechsten MX versuchen
 # - falls kein MX vorhanden, Fallback auf A
 # -> jeweils Adresse testen via checksmtp()
 my ($address,$logging) = @_;
 my ($rr,$mailhost,$status,@mx);
 my $dnsresult = 'okay';
 # (my $lp = $address) =~ s/^([^@]+)@.*/$1/;
 (my $domain = $address) =~ s/[^@]+\@(\S*)$/$1/;

 $logging .=  "\n----- BEGIN $address -----\n";

 # DNS-Lookup unterdrueckt?
 if ($options{'m'}) {
  print "    Connection to $options{'m'} forced by -m.\n";
  $logging .=  "Connection to $options{'m'} forced by -m.\n";
  ($status,$logging) = checksmtp($options{'m'},$address,$domain,$logging);
  $logging .= "----- END $address -----\n";
  return ($status,$logging);
 };

 # Resolver-Objekt
 $resolve = Net::DNS::Resolver -> new();
 $resolve->usevc(1);
 $resolve->tcp_timeout(15);

 # MX-Record feststellen
 @mx = mx($resolve,$domain) or $dnsresult = $resolve->errorstring;
 print "    $domain (MX: $dnsresult)\n" if !($options{'q'});

 if (@mx) {
  WALKMX: foreach $rr (@mx) {
   $mailhost = $rr->exchange;
   print "    MX: $mailhost / $address\n" if !($options{'q'});
   $logging .= "Try MX: $mailhost\n";
   ($status,$logging) = checksmtp($mailhost,$address,$domain,$logging);
   last WALKMX if ($status < 3);
  };
 } elsif ($dnsresult eq 'NXDOMAIN' or $dnsresult eq 'NOERROR' or $dnsresult eq 'REFUSED') {
  # wenn kein MX-Record: A-Record feststellen
  $logging .= "MX error: $dnsresult\n";
  $dnsresult = 'okay';
  $query = $resolve->search($domain) or $dnsresult = $resolve->errorstring;
  print "    $domain (A: $dnsresult)\n" if !($options{'q'});
  if ($query) {
   foreach $rr ($query->answer) {
    next unless $rr->type eq "A";
    $mailhost = $rr->address;
    print "    A: $mailhost / $address\n" if !($options{'q'});
    $logging .= "Try A: $mailhost\n";
    ($status,$logging) = checksmtp($mailhost,$address,$domain,$logging);
   };
  } elsif ($dnsresult eq 'NXDOMAIN' or $dnsresult eq 'NOERROR' or $dnsresult eq 'REFUSED') {
   # wenn auch kein A-Record: what a pity ...
   print "  > NO DNS-RECORD (MX/A) FOUND.\n" if !($options{'q'});
   $logging .= "A error: $dnsresult\n";
   $status = 1;
  };
 };
 $logging .= "----- END $address -----\n";
 return ($status,$logging);
};

sub checksmtp {
 # - zu $mailhost verbinden, $adresse testen (SMTP-Dialog bis RCPT TO)
 # - ggf. (-r) testen, ob sicher ungueltige Adresse abgelehnt oder
 #   alles angenommen wird
 my($mailhost,$address,$domain,$logging)=@_;
 my($smtp,$status,$valid);
 $logging .= "-------------------------\n";
 CONNECT: if ($smtp = Net::SMTP->new($mailhost,Hello => $config{'helo'},Timeout => 30)) {
  $logging .= $smtp->banner;
  $logging .= "EHLO $config{'helo'}\n";
  $logging .= parse_reply($smtp->code,$smtp->message);
  $smtp->mail($config{'from'});
  $logging .= "MAIL FROM:<$config{'from'}>\n";
  $logging .= parse_reply($smtp->code,$smtp->message);
  # wird RCPT TO akzeptiert?
  $valid = $smtp->to($address);
  $logging .= "RCPT TO:<$address>\n";
  if ($smtp->code > 0) {
   # es kam eine Antwort auf RCPT TO
   $logging .= parse_reply($smtp->code,$smtp->message);
   if ($valid) {
    # RCPT TO akzeptiert
    $status = 0;
    if ($options{'r'}) {
     # werden sicher ungueltige Adressen abgewiesen?
     $valid = $smtp->to($config{'rand'}.'@'.$domain);
     $logging .= 'RCPT TO:<'.$config{'rand'}.'@'.$domain.">\n";
     if ($smtp->code > 0) {
      # es kam eine Antwort auf RCPT TO (fuer $rand)
      $logging .= parse_reply($smtp->code,$smtp->message);
      if ($valid) {
       # ungueltiges RCPT TO akzeptiert
       print "  > Sorry, cannot verify. You'll have to send a testmail ...\n" if !($options{'q'});
       $status = 2;
      };
     } else {
      # Timeout nach RCPT TO (fuer $rand)
      print "  > Temporary failure.\n" if !($options{'q'});
      $logging .= "---Timeout---\n";
      $smtp->quit;
      $status = 3;
     };
    };
    print "  > Address is valid.\n" if (!$status and !$options{'q'});
   } else {
    # RCPT TO nicht akzeptiert
    print "  > Address is INVALID.\n" if !($options{'q'});
    $status = 1;
   };
   # Verbindung beenden
   $smtp->quit;
   $logging .= "QUIT\n";
   $logging .= parse_reply($smtp->code,$smtp->message);
  } else {
   # Timeout nach RCPT TO
   print "  > Temporary failure.\n" if !($options{'q'});
   $logging .= "---Timeout---\n";
   $smtp->quit;
   $status = 3;
  };
 } else {
  # Verbindung fehlgeschlagen
  print "  > Temporary failure.\n" if !($options{'q'});
  $logging .= "---Timeout---\n";
  $status = 3;
 };
 return ($status,$logging);
};

sub parse_reply {
  my($code,$message)=@_;
  my($reply);
  $reply = $code . ' ' . $message;
  return $reply;
}

