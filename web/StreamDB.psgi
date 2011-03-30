#!/usr/bin/perl
use strict;
use Data::Dumper;
use Log::Log4perl;
use Config::JSON;
use Plack::Builder;
use Plack::Middleware::CrossOrigin;
use StreamClient;

my $config_file = '/etc/streamdb.conf';
if ($ENV{STREAMDB_CONF}){
	$config_file = $ENV{STREAMDB_CONF};
}

my $conf = new Config::JSON ( $config_file ) or die("Unable to open config file");

my $debug_level = $conf->get('debug_level') ? $conf->get('debug_level') : 'INFO';
	
# Setup logger
my $log_conf;
if ($conf->get('logdir')){
	my $log_file = $conf->get('logdir') . '/streamdb.log';
	$log_conf = qq(
		log4perl.category.StreamDB       = $debug_level, File
		log4perl.appender.File			 = Log::Log4perl::Appender::File
		log4perl.appender.File.filename  = $log_file
		log4perl.appender.File.syswrite = 1
		log4perl.appender.File.recreate = 1
		log4perl.appender.File.layout = Log::Log4perl::Layout::PatternLayout
		log4perl.appender.File.layout.ConversionPattern = * %p [%d] %F (%L) %M %P %m%n
		log4perl.filter.ScreenLevel               = Log::Log4perl::Filter::LevelRange
  		log4perl.filter.ScreenLevel.LevelMin  = INFO
  		log4perl.filter.ScreenLevel.LevelMax  = ERROR
  		log4perl.filter.ScreenLevel.AcceptOnMatch = true
  		log4perl.appender.Screen         = Log::Log4perl::Appender::Screen
		log4perl.appender.Screen.Filter = ScreenLevel 
		log4perl.appender.Screen.stderr  = 1
		log4perl.appender.Screen.layout = Log::Log4perl::Layout::PatternLayout
		log4perl.appender.Screen.layout.ConversionPattern = * %p [%d] %F (%L) %M %P %m%n
	);
}
else {
	$log_conf = qq(
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
}

Log::Log4perl::init( \$log_conf ) or die("Unable to init logger\n");
my $log = Log::Log4perl::get_logger('StreamDB')
	  or die("Unable to init logger\n");

builder {
	enable 'CrossOrigin', origins => '*', methods => '*', headers => '*';
	mount '/' => builder {
		StreamClient->new(conf => $conf, log => $log)->to_app;
	};
	mount '/favicon.ico' => sub { return [ 200, [ 'Content-Type' => 'text/plain' ], [ '' ] ]; };
};



