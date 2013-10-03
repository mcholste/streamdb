package StreamWriter;
use strict;
use Data::Dumper;
use File::Slurp qw(slurp);
use DBI;
use IO::File;
use Config::JSON;
use Socket;
use Log::Log4perl;
use Net::Server::Daemonize qw(daemonize);

our $Prefix = 'streams_';
our $Num_tables = 100;

$SIG{CHLD} = 'IGNORE'; # will do the wait() so we don't create zombies

sub new {
	my $class = shift;
	my $args = shift;
	
	my $conf;
	if ($args->{config_file}){
		$conf = new Config::JSON($args->{config_file}) or die('Unable to open config file ' . $args->{config_file});
	}
	else {
		$conf = Config::JSON->create('/tmp/streamdb.conf');
	} 
	
	my $self = { _ID => $conf->get('id') ? $conf->get('id') : 0, _CONF => $conf };
	
	bless $self, $class;
	
	my $size_limit = $self->conf->get('retention/size');
	unless ($size_limit){
		die('No retention size specified in config');
	}
	if ($size_limit =~ /(\d+)([GMT])$/){
		if( $2 eq 'T' ) {
			$size_limit = $1 * 2**40;
		}
		elsif( $2 eq 'G' ) {
			$size_limit = $1 * 2**30;
		} 
		elsif( $2 eq 'M' ) {
			$size_limit = $1 * 2**20;
		}
	}
	unless ($size_limit){
		die('Invalid retention size specified in config');
	}
	
	$self->{_RETENTION_SIZE} = $size_limit;
	
	my $debug_level = $self->conf->get('debug_level') ? $self->conf->get('debug_level') : 'INFO';
	
	# Setup logger
	my $log_conf;
	if ($self->conf->get('logdir')){
		my $log_file = $self->conf->get('logdir') . '/streamdb.log';
		$log_conf = qq(
			log4perl.category.StreamDB       = $debug_level, File, Screen
			log4perl.appender.File			 = Log::Log4perl::Appender::File
			log4perl.appender.File.filename  = $log_file
			log4perl.appender.File.syswrite = 1
			log4perl.appender.File.recreate = 1
			log4perl.appender.File.layout = Log::Log4perl::Layout::PatternLayout
			log4perl.appender.File.layout.ConversionPattern = * %p [%d] %F (%L) %M %P %m%n
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
	$self->{_LOGGER} = Log::Log4perl::get_logger('StreamDB') or die("Unable to init logger\n");
	
	my $host = $conf->get('db/host') ? $conf->get('db/host') : '127.0.0.1';
	my $port = $conf->get('db/port') ? $conf->get('db/port') : 3306;
	$self->{_DB_NAME} = $args->{database} ? $args->{database} : $conf->get('db/database') ? $conf->get('db/database') : 'test';
	my $username = $conf->get('db/username') ? $conf->get('db/username') : 'root';
	my $password = $conf->get('db/password') ? $conf->get('db/password') : ''; 
	$self->{_DBH} = DBI->connect("dbi:mysql:host=$host;port=$port;database=$self->{_DB_NAME}", 
		$username, $password, { InactiveDestroy => 1 }) or die($DBI::errstr);
	$self->{_DBH}->{mysql_auto_reconnect} = 1; # we will auto-reconnect on disconnect
	$self->{_DBH}->{HandleError} = \&_sql_error_handler;
	
	# Find our starting table id
	my ($query, $sth, $row);
	
	$self->{_DATA_FILE_ID} = 0;
	opendir(DIR, $self->conf->get('data_dir'));
	while (my $short_file = readdir(DIR)){
		if ($short_file =~ /^$Prefix(\d+)$/o){
			my $part_id = $1;
			if ($part_id > $self->{_DATA_FILE_ID}){
				$self->{_DATA_FILE_ID} = $part_id;
			}
		}
	}
	close(DIR);
	
	$self->log->debug('Initial file id: ' . $self->{_DATA_FILE_ID});
	
	$self->{_TABLE_ID_ROLLOVER} = int($self->{_RETENTION_SIZE} / 2**32);
	if ($self->{_TABLE_ID_ROLLOVER} > $Num_tables){
		$self->{_TABLE_ID_ROLLOVER} = int($self->{_TABLE_ID_ROLLOVER} / $Num_tables);
	}
	else {
		$Num_tables = $self->{_TABLE_ID_ROLLOVER};
	}
	$self->log->debug('retention size: ' . $self->{_RETENTION_SIZE} . ' div 4gb: ' . int($self->{_RETENTION_SIZE} / 2**32));
	$self->log->debug("Using a table id rollover of $self->{_TABLE_ID_ROLLOVER} and Num_tables $Num_tables");

	$self->_init_db();
	
	if ($conf->get('vortex') and -f $conf->get('vortex')){
		$self->{_VORTEX} = $conf->get('vortex');
	}
	else {
		$self->{'_VORTEX'} = '/usr/local/bin/vortex';
		if (-f $self->{_VORTEX}){
			$self->log->warn('No vortex configured, defaulting to /usr/local/bin/vortex');
		}
		else {
			die('Unable to find a vortex executable.');
		}
	}
	
	$self->{_BATCH_SIZE} = 100;
	if ($self->conf->get('batch_size')){
		$self->{_BATCH_SIZE} = int( $self->conf->get('batch_size') );
	}
	
	if ($conf->get('interface')){
		$self->{_INTERFACE} = $conf->get('interface');
	}
	elsif ($args->{interface}){
		$self->{_INTERFACE} = $args->{interface};
	}
	else {
		$self->log->warn('Defaulting to interface eth1, this may not be what you want!');
		$self->{_INTERFACE} = 'eth1';
	}
	
	if (defined $args->{read_file}){
		if (-f $args->{read_file}){
			$self->{_READ_FILE} = $args->{read_file};
			$self->log->debug('Reading from pcap file ' . $self->{_READ_FILE});
		}
		else {
			die('Cannot find file: ' . $args->{read_file});
		}
	}
	
	my $collect_limit = 200_000;
	if ($self->conf->get('collect_limit')){
		$collect_limit = $self->conf->get('collect_limit');
	}
	$self->{_OPTIONS} = '-e -l -k -S ' . $collect_limit . ' -C ' . $collect_limit . ' -T 10 -E 10 ';
	if ($conf->get('options')){
		$self->{_OPTIONS} .= $conf->get('options');
	}
	
	if ($self->{_READ_FILE}){
		$self->{_OPTIONS} .= " -r $self->{_READ_FILE}";
	}
	else {
		$self->{_OPTIONS} .= " -i $self->{_INTERFACE}";
	}
	
	if ($args->{buffer_dir}){
		$self->{_BUFFER_DIR} = $args->{buffer_dir};
	}
	elsif ($conf->get('buffer_dir')){
		$self->{_BUFFER_DIR} = $conf->get('buffer_dir');
	}
	else {
		$self->log->warn('Defaulting to the current directory as buffer_dir.');
		$self->{_BUFFER_DIR} = './';
	}
	
	if ($args->{data_dir}){
		$self->{_DATA_DIR} = $args->{data_dir};
	}
	elsif ($conf->get('data_dir')){
		$self->{_DATA_DIR} = $conf->get('data_dir');
	}
	else {
		$self->log->warn('Defaulting to the current directory as data_dir.');
		$self->{_DATA_DIR} = './';
	}
	
	$self->{_ROLLOVER_CHECK} = $self->conf->get('rollover_check_frequency') ? $self->conf->get('rollover_check_frequency') : 10;

	
	if (($args->{daemonize} or $self->conf->get('daemonize'))){
		my $user = $self->conf->get('user') ? $self->conf->get('user') : 'root';
		my $group = $self->conf->get('group') ? $self->conf->get('group') : 'root';
			
		my $pid_file = $self->conf->get('pid_file') ? $self->conf->get('pid_file') : '/var/run/streamdb_' . $self->{_ID} . '.pid';
		print "Daemonizing...\n";
		daemonize($user, $group, $pid_file);
	}
	
	return $self;
}

sub _init_db {
	my $self = shift;

	my ($query, $sth, $row);
	
	# Verify the streamdb table exists
	$query = 'SELECT table_name FROM INFORMATION_SCHEMA.tables WHERE table_schema=? AND table_name="streams"';
	$sth = $self->db->prepare($query);
	$sth->execute($self->{_DB_NAME});
	$row = $sth->fetchrow_hashref;
	unless ($row){
		$self->log->warn("Creating streams table");
		$query = <<EOT
CREATE TABLE streams (
	offset INT UNSIGNED NOT NULL,
	file_id SMALLINT UNSIGNED NOT NULL,
	length INT UNSIGNED NOT NULL,
	srcip INT UNSIGNED NOT NULL,
	srcport MEDIUMINT UNSIGNED NOT NULL,
	dstip INT UNSIGNED NOT NULL,
	dstport MEDIUMINT UNSIGNED NOT NULL,
	timestamp INT UNSIGNED NOT NULL,
	duration INT UNSIGNED NOT NULL,
	reason ENUM ('c', 'r', 't', 'e', 'l', 'i') NOT NULL,
	direction ENUM ('s', 'c') NOT NULL,
	PRIMARY KEY (offset, file_id),
	KEY (srcip),
	KEY (dstip),
	KEY (timestamp)
) ENGINE=MyISAM
EOT
;
		$self->db->do($query) or die('Unable to create table');
	}
	
	return 1;
}

sub _open_data_fh {
	my $self = shift;
	
	$self->{_DATA_FILE_NAME} = $self->{_DATA_DIR} . '/' . $Prefix . $self->{_DATA_FILE_ID};
	my $fh = new IO::File;
	$fh->open($self->{_DATA_FILE_NAME}, O_WRONLY|O_APPEND|O_CREAT) or die($!);
	$fh->binmode(1);
	$fh->autoflush(1);
	$fh->print("\0");
	$self->{_DATA_FH} = $fh;

	$self->log->debug('Using data file ' . $self->{_DATA_FILE_NAME});
	
	$self->_check_table();
	
	return 1;
}


sub conf {
	my $self = shift;
	return $self->{_CONF};
}

sub log {
	my $self = shift;
	return $self->{_LOGGER};
}

sub db {
	my $self = shift;
	return $self->{_DBH};
}

sub run {
	my $self = shift;
	my ($query, $sth);
	
	# Load any pre-existing tsv's
	opendir(DIR, $self->{_BUFFER_DIR});
	while (my $short_file = readdir(DIR)){
		my $file = $self->{_BUFFER_DIR} . '/' . $short_file;
		if ($short_file =~ /^(tcp\-(\d+)\-(\d+)\-(\d+)\-(\w)\-(\d+)\-(\d+\.\d+\.\d+\.\d+)\:(\d+)\w(\d+\.\d+\.\d+\.\d+)\:(\d+))/){
			#TODO load existing buffers
			# delete existing buffers
			$self->log->warn('Deleting leftover buffer ' . $file);
			unlink $file;
		}
	}
	closedir(DIR);
	
	$self->_check_rollover();
	$self->_open_data_fh();
	
	my $last_ring_errors = 0;
	my @to_insert;
	
	$| = 1;
	my $cmd = "$self->{_VORTEX} $self->{_OPTIONS} -t $self->{_BUFFER_DIR} 2>&1";
	$self->log->debug("cmd: $cmd");
	open(FH, "-|", "$cmd");
	while (<FH>){
		my $line_num = $.;
		chomp;
		my $file = $_;
		#VORTEX_STATS PCAP_RECV: 674814420 PCAP_DROP: 0 VTX_BYTES: 153363091517 VTX_EST: 8245678 VTX_WAIT: 0 VTX_CLOSE_TOT: 8242666 VTX_CLOSE: 5127749 VTX_LIMIT: 1728 VTX_POLL: 0 VTX_TIMOUT: 5 VTX_IDLE: 1355256 VTX_RST: 1757928 VTX_EXIT: 0 VTX_BSF: 0
		if ($file =~ /^VORTEX_STATS/){
			#TODO implement stats someday
		}
		#VORTEX_ERRORS TOTAL: 119275 IP_SIZE: 0 IP_FRAG: 0 IP_HDR: 0 IP_SRCRT: 0 TCP_LIMIT: 5 TCP_HDR: 0 TCP_QUE: 119270 TCP_FLAGS: 0 UDP_ALL: 0 SCAN_ALL: 0 VTX_RING: 0 VTX_IO: 0 VTX_MEM: 0 OTHER: 0
		elsif ($file =~ /^VORTEX_ERRORS.*VTX_RING: (\d+)/){
			my $errors = $1;
			if ($errors > $last_ring_errors){
				my $new_errors = $errors - $last_ring_errors;
				$self->log->error('Dropped ' . $new_errors . ' connections because we could not process them fast enough.');
			}
			$last_ring_errors = $errors;
		}
		#{proto}-{connection_serial_number}-{connection_start_time}-{connection_end_time}-{connection_end_reason}-{connection_size}-{client_ip}:{client_port}{direction}{server_ip}:{server_port}
		elsif (my ($header, $serial_number, $start, $end, $reason, $length, $srcip, $srcport, $direction, $dstip, $dstport) = 
			$file =~ /(tcp\-(\d+)\-(\d+)\-(\d+)\-(\w)\-(\d+)\-(\d+\.\d+\.\d+\.\d+)\:(\d+)(\w)(\d+\.\d+\.\d+\.\d+)\:(\d+))/){
				
			my $offset = $self->{_DATA_FH}->tell or die($!);
			#my $buf = $header . ' ' . slurp($file);
			my $buf = slurp($file);
			
			# Check if we are going to exceed 4GB offset which can't be stored in 32-bit ID in MySQL
			if ($offset > ((2**32) - 1)){
				$self->_data_file_rollover();
				$offset = $self->{_DATA_FH}->tell or die($!);
			}
			
			$self->{_DATA_FH}->print($buf) or die($!);
					
			push @to_insert, [ $offset, $self->{_DATA_FILE_ID}, length($buf), 
				unpack('N*', inet_aton($srcip)), $srcport, unpack('N*', inet_aton($dstip)), $dstport, $start, ($end-$start), '"' . $reason . '"', '"' . $direction . '"' ];
			
			unlink($file);
		}
		else {
			$self->log->warn('Unknown input: ' . $file);
		}
		
		# Check to see if it's time to batch insert
		if (scalar @to_insert >= $self->{_BATCH_SIZE}){
			$self->_insert(\@to_insert);
			@to_insert = ();
		}
#		if ($line_num % ($self->{_BATCH_SIZE} * $self->{_ROLLOVER_CHECK}) == 0){ # This is expensive, so we only do it every ROLLOVER_CHECK times
#			$self->_check_rollover();
#			#$self->log->trace("line num: $line_num, batch size: $self->{_BATCH_SIZE}, rollover check: $self->{_ROLLOVER_CHECK}, test: " . $. % ($self->{_BATCH_SIZE} * $self->{_ROLLOVER_CHECK}));
#		}
	}
	close(FH);
	if (scalar @to_insert){
		$self->_insert(\@to_insert);
	}
}

sub _insert {
	my $self = shift;
	my $records = shift;
	
	my ($query, $sth);
	$query = 'INSERT INTO streams (offset, file_id, length, srcip, srcport, dstip, dstport, timestamp, duration, reason, direction) VALUES';
	foreach my $record (@$records){
		$query .= '(' . join(',', @$record) . '),';
	}
	chop($query); #removes the last comma
	my $rows = $self->db->do($query);
	#$self->log->trace('Inserted ' . $rows . ' rows.');
}

sub _sql_error_handler {
	my $errstr = shift;
	my $dbh = shift;
	my $query = $dbh->{Statement};
	
	my $logger = Log::Log4perl::get_logger("Streamdb");
	$errstr = sprintf("SQL ERROR: %s\nQuery: %s\n",	$errstr, $query);
	$logger->error($errstr);
	
	return 1; # Stops default RaiseError from happening
}

sub _check_table {
	my $self = shift;
	
	my ($query, $sth);
	
	# Check to see if we need to create a new table and rollover
	if ($self->{_DATA_FILE_ID} and $self->{_DATA_FILE_ID} % $self->{_TABLE_ID_ROLLOVER} == 0){
		my $cur_file_id = ($self->{_DATA_FILE_ID} - $self->{_TABLE_ID_ROLLOVER});
		my $rolled_table = $Prefix . $cur_file_id;
		$query = 'RENAME TABLE streams TO ' . $rolled_table;
		$self->log->debug('Rolling streams table to table name : ' . $rolled_table);
		$self->db->do($query);
		# instantiate the shiny new streams table;
		$query = 'CREATE TABLE streams LIKE ' . $rolled_table;
		$self->db->do($query);
	}
}


sub _data_file_rollover {
	my $self = shift;
	
	my ($query, $sth);
	# See if we need a new data file
	$self->log->info('Rolling over data file.');
	$self->{_DATA_FILE_ID}++;
	
	# Make sure we're under SMALLINT
	if ($self->{_DATA_FILE_ID} >= 2**16){
		$self->log->info(q{Congratulations! You've created 65535 files, wrapping around to 1!});
		$self->{_DATA_FILE_ID} = 1;
	}
	
	# Start the new fh
	$self->{_DATA_FH}->close();
	$self->_open_data_fh();
	
	$self->_check_rollover();
	
	return 1;
}

sub _check_rollover {	
	my $self = shift;
	
	#$self->log->trace('checking rollover');
	
	# Are we over the retention size?
	while (($self->_get_db_size() + $self->_get_files_size()) > $self->{_RETENTION_SIZE}){
		$self->_drop_oldest();
	}
}

sub _drop_oldest {
	my $self = shift;
	my ($query, $sth);
		
	$query = 'SELECT table_name FROM INFORMATION_SCHEMA.tables WHERE table_schema=? ' . "\n" .
		'AND table_name LIKE "' . $Prefix . '%" ORDER BY create_time ASC LIMIT 1';
	$sth = $self->db->prepare($query);
	$sth->execute($self->{_DB_NAME});
	my $row = $sth->fetchrow_hashref;
	my $table_name = $row->{table_name};
	$query = 'DROP TABLE ' . $table_name;
	$self->db->do($query);
	$self->log->info('Dropped oldest table ' . $table_name);
	
	# Drop corresponding files
	$table_name =~ /^$Prefix(\d+)$/;
	my $file_id = $1;
	opendir(DIR, $self->conf->get('data_dir'));
	while (my $short_file = readdir(DIR)){
		if ($short_file =~ /^$Prefix(\d+)$/o){
			my $part_id = $1;
			if ($part_id >= $file_id and $part_id < ($file_id + $self->{_TABLE_ID_ROLLOVER})){
				my $data_file_name = $self->conf->get('data_dir') . '/' . $Prefix . $part_id;
				$self->log->info('Dropping data file ' . $data_file_name);
				unlink $data_file_name;
			}
		}
	}
	close(DIR);
	
}

sub _get_db_size {
	my $self = shift;
	my ($query, $sth);
	$query = 'SELECT data_length+index_length AS size FROM INFORMATION_SCHEMA.tables WHERE table_schema=? AND table_name="streams"';
	$sth = $self->db->prepare($query);
	$sth->execute($self->{_DB_NAME});
	my $row = $sth->fetchrow_hashref;
	return $row->{size};
}

sub _get_files_size {
	my $self = shift;
	my $files_size = 0;
	opendir(DIR, $self->{_DATA_DIR});
	while (my $short_file = readdir(DIR)){
		next unless $short_file =~ /^$Prefix/;
		my $file = $self->{_DATA_DIR} . '/' . $short_file;
		$files_size += -s $file;
	}
	close(DIR);
	return $files_size;
}


1;

__END__
