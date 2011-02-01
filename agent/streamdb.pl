#!/usr/bin/perl
use strict;
use warnings;
use Data::Dumper;
use StreamWriter;
use Getopt::Std;

my %Opts;
getopts('c:Di:d:b:a:', \%Opts);

my $config_file;
if ($Opts{c}){
	$config_file = $Opts{c};
}

my $writer = new StreamWriter({ 
	config_file => $config_file, 
	interface => $Opts{i}, 
	daemonize => $Opts{D}, 
	buffer_dir => $Opts{b},
	data_dir => $Opts{b},
	database => $Opts{a},
}) or die($!);
$writer->run();