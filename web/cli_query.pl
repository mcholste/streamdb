#!/usr/bin/perl

# This script is an example of how to use the StreamClient API from the command line.
# It takes command line options for config, srcip/dstip the PCRE match, and an optional limit.
# It will use the StreamClient to PCRE match each stream found until the limit has been reached.
# It can process hundreds of streams per second, so searching for a match from relatively unique srcip's or dstip's
# will complete in a few seconds. 


use strict;
use Data::Dumper;
use Time::HiRes qw(time);
use StreamClient;  
use Config::JSON;
use Log::Log4perl;
use Getopt::Long;

my $config_file = '/etc/streamdb.conf';
my ($srcip, $dstip, $match, $debug) = undef;
my $limit = 10;
GetOptions(
	'config=s' => \$config_file,
	'srcip=s' => \$srcip,
	'dstip=s' => \$dstip,
	'match=s' => \$match,
	'limit=i' => \$limit,
	'debug=s' => \$debug,
);

die ('no match given') unless $match;
 
my $conf = new Config::JSON($config_file);
my $debug_level = $debug ? $debug : $conf->get('debug_level') ? $conf->get('debug_level') : 'WARN';
my $log_conf = qq(
	log4perl.category.StreamDB       = $debug_level, Screen
	log4perl.filter.ScreenLevel               = Log::Log4perl::Filter::LevelRange
  	log4perl.filter.ScreenLevel.LevelMin  = TRACE
  	log4perl.filter.ScreenLevel.LevelMax  = ERROR
  	log4perl.filter.ScreenLevel.AcceptOnMatch = true
  	log4perl.appender.Screen         = Log::Log4perl::Appender::Screen
	log4perl.appender.Screen.Filter = ScreenLevel 
	log4perl.appender.Screen.stderr  = 1
	log4perl.appender.Screen.layout = Log::Log4perl::Layout::PatternLayout
	log4perl.appender.Screen.layout.ConversionPattern = * %p [%d] %F (%L) %M %P %m%n
);

Log::Log4perl::init( \$log_conf ) or die("Unable to init logger\n");
my $logger = Log::Log4perl::get_logger('StreamDB') or die("Unable to init logger\n"); 

my $start = time(); 

my $client = new StreamClient({conf => $conf, log => $logger}); 

my $query = { limit => $limit, pcre => $match };
if ($srcip){
	$query->{srcip} = $srcip;
}
if ($dstip){
	$query->{dstip} = $dstip;
}

my $res = $client->pcre_query($query);

my $end = time(); 

foreach my $match (@{ $res->{rows} }){
	print Dumper($match) . "\n";
}
my $dur = ($end - $start);
$logger->debug("Found " . scalar @{ $res->{rows} } . " matches"); 
$logger->debug("count: " . $res->{totalRecords} . " in " . $dur . " seconds for a rate of " . $res->{totalRecords}/$dur); 
