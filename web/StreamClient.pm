package StreamClient;
use Moose;
use Data::Dumper;
use Plack::Request;
use base 'Plack::Component';
use Date::Manip;
use HTTP::Parser;
use Encode;
use DBI;
use Data::Hexify;
use File::LibMagic qw(:easy);
use File::Temp qw(tempfile);
use Digest::SHA1 qw(sha1_hex);

has 'log' => ( is => 'ro', isa => 'Log::Log4perl::Logger', required => 1 );
has 'conf' => ( is => 'ro', isa => 'Config::JSON', required => 1 );
has 'db' => ( is => 'rw', isa => 'Object', required => 0 );
has 'magic' => (is => 'ro', isa => 'File::LibMagic', required => 1, default => sub {
	return new File::LibMagic();
});

our %Query_params = (
	srcip => qr/^(?<not>\!?)(?<srcip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/,
	dstip => qr/^(?<not>\!?)(?<dstip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/,
	srcport => qr/^(?<not>\!?)(?<srcport>\d{1,5})$/,
	dstport => qr/^(?<not>\!?)(?<dstport>\d{1,5})$/,
	start => qr/(?<start>.+)/, # start/end will be run through a parser for sanitization
	end => qr/(?<end>.+)/,
	offset => qr/^(?<offset>\d+)$/,
	limit => qr/^(?<limit>\d{1,5})$/,
	pcre => qr/(?<pcre>.+)/,
	as_hex => qr/^(?<as_hex>1)$/,
	raw => qr/^(?<raw>1)$/,
	sort => qr/^(?<sort>1)$/,
	direction => qr/^(?<direction>[cs])$/,
	quiet => qr/^(?<quiet>1)$/,
	reason => qr/^(?<not>\!?)(?<reason>[crteli])$/,
	filetype => qr/^(?<not>\!?)(?<filetype>[\w\s]+)/,
	submit => qr/^(?<submit>[\w\s]+)/,
	oid => qr/^(?<oid>\d+\-\d+\-\d+\-\d+)$/,
);


# Allow this to be openfpc compatible for Snorby
our %Param_translations = (
	sip => 'srcip',
	dip => 'dstip',
	spt => 'srcport',
	dpt => 'dstport',
	stime => 'start',
	etime => 'end',
	filename => undef, 
);

our $Default_limit = 10;
our %Reasons = (
	c => 'FIN',
	r => 'RST',
	t => 'SYN Timeout',
	e => 'Vortex exiting',
	l => 'Size cutoff',
	i => 'Time cutoff',
);

sub BUILD {
	my ($self, $params) = @_;
	
	$self->db(DBI->connect('dbi:mysql:database=' . $self->conf->get('db/database') . ';host=' 
		. $self->conf->get('db/host'), $self->conf->get('db/username'), $self->conf->get('db/password')));
		
	return $self;
}

sub call {
	my ($self, $env) = @_;
	
	my $req = Plack::Request->new($env);
	my $res = $req->new_response(200); # new Plack::Response
	$res->content_type('text/plain');
	
	my $body;
	eval {
		if ($req->query_parameters->{oid}){
			$body = $self->get_object($req->query_parameters->{oid})->{content};
		}
		else {
			my $result;
			$result = $self->query($req->query_parameters);
			
			$body .= 'Returning ' . (scalar @{ $result->{rows} }) . ' of ' . $result->{totalRecords} 
				. ' at offset '. $result->{startIndex}. ' from ' .(scalar localtime($result->{min}))
				. ' to ' . (scalar localtime($result->{max})) . "\n\n";
			foreach my $row (sort { $a->{timestamp} <=> $b->{timestamp} } @{ $result->{rows} }){
				for (my $i = 0; $i < @{ $row->{data} }; $i++){
					$body .= sprintf("%s %s:%d %s %s:%d %ds %d bytes %s %s\n\n%s\n\n", $row->{start}, 
						$row->{srcip}, $row->{srcport}, $row->{direction} eq 'c' ? '<-' : '->',
						$row->{dstip}, $row->{dstport}, $row->{duration}, $row->{length}, $Reasons{ $row->{reason} }, 
						$row->{objects}->[$i]->{meta}, $row->{data}->[$i]);
				}
			}
		}
	};
	if ($@){
		my $e = $@;
		$self->log->error($e);
		$body = $e . "\n" . usage();
	}
    $res->body($body);
    $res->finalize;
}

sub usage {
	my $msg = <<'EOT'
Usage:

Either srcip or dstip are required.
srcip => qr/^(?<not>\!?)(?<srcip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/,
dstip => qr/^(?<not>\!?)(?<dstip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/,
srcport => qr/^(?<not>\!?)(?<srcport>\d{1,5})$/,
dstport => qr/^(?<not>\!?)(?<dstport>\d{1,5})$/,
start => qr/(?<start>.+)/, # start/end will be run through a parser for sanitization
end => qr/(?<end>.+)/,
offset => qr/^(?<offset>\d+)$/,
limit => qr/^(?<limit>\d{1,5})$/,
pcre => qr/(?<pcre>.+)/,
as_hex => qr/^(?<as_hex>1)$/,
raw => qr/^(?<raw>1)$/, (do not gunzip/dechunk HTTP responses)
sort => qr/^(?<sort>1)$/, (sort in reverse order)
direction => qr/^(?<direction>[cs])$/,
quiet => qr/^(?<quiet>1)$/,
reason => qr/^(?<not>\!?)(?<reason>[crteli])$/,
filetype => qr/^(?<not>\!?)(?<filetype>[\w\s]+)/,
oid => qr/^(?<oid>\d+\-\d+\-\d+\-\d+)$/,

--srcip <Source IP address>
--dstip <Destinatinon IP address>
| --oid <oid> Retrieve a given object ID
<STDIN> will be used unless srcip or dstip are specified
[ --config <config location> ] Default /etc/streamdb.conf
[ --match <pcre match> ]
[ --limit <number of results to return> ] Default 10
[ --offset <number of results to skip> ] Default 0
[ --descending ] Reverse chronological order
[ --debug <level> ] Default WARN or whatever is in streamdb.conf (ERROR WARN INFO DEBUG TRACE)
[ --srcport <source port> ]
[ --dstport <destination port> ]
[ --start <start time>] Can be in almost any format, but should be quoted if multiword
[ --end <end time> ]
[ --direction <char> ] Character representing the direction, c to client, s from server
[ --reason <char> ] Termination reason for the flow: 
  c => Well formed TCP close
  r => Reset
  t => Time out
  e => Stream ended prematurely becuase vortex is exiting
  l => Stream size limit exceeded
  i => Connection exceeded idle limit
[ --verbose ] Prints header information and data for each stream matched, default is just data
[ --headers-only ] Prints only header information for each stream matched
[ --filetype ] PCRE match on the description of the stream as per libmagic

Examples: 
?srcip=192.168.1.1&filetype=executable


EOT
;
	return $msg;

}

sub query {
	my $self = shift;
	my $given_params = shift;
	my $is_retry = shift;
	$self->log->debug('given_params: ' . Dumper($given_params));
	
	# Parse the query
	die('No query params given') unless scalar keys %$given_params;
	
	foreach my $param (keys %$given_params){
		if (exists $Param_translations{$param}){
			if (defined $Param_translations{$param}){
				$given_params->{ $Param_translations{$param} } = delete $given_params->{$param};
			}
			else {
				# Allowed but useless
				delete $given_params->{$param};
			}
			next;
		}
	}
	
	# Validate all params by only using those found in the built-in %+ PCRE named-extraction hash
	my $validated_params = {};
	my $validated_not_params = {};
	foreach my $param (keys %$given_params){
		$given_params->{$param} =~ $Query_params{$param};
		my $not = $+{not} ? 1 : 0;
		
		foreach my $validated_param (keys %+){
			next if $validated_param eq 'not'; # can't modify a read-only hash, so we'll just skip it
			if ($not){
				$validated_not_params->{$validated_param} = $+{$validated_param};
			}
			else {
				$validated_params->{$validated_param} = $+{$validated_param};
			}
		}
	}
	
	# Check to be sure we have either a positive search for srcip or dstip
	unless ($validated_params->{srcip} or $validated_params->{dstip}){
		die('No valid srcip or dstip found to search on.');
	}
	
	my $start = 0;
	my $now = time();
	my $end = $now;
	if ($validated_params->{start} and $validated_params->{start} =~ /^\d+$/){
		# Fine as is
		$start = $validated_params->{start};
	}
	elsif ($validated_params->{start}){
		$start = UnixDate(ParseDate($validated_params->{start}), '%s');
	}
	
	if ($validated_params->{end} and $validated_params->{end} =~ /^\d+$/){
		# Fine as is
		$end = $validated_params->{end};
	}
	elsif ($validated_params->{end}){
		$end = UnixDate(ParseDate($validated_params->{end}), '%s');
	}
	
	if ($validated_params->{submit}){
		$self->{_STREAMDB_SUBMIT_FILETYPE} = $validated_params->{submit};
	}
	
	my ($query, $sth);
	
	# Create our temporary merge table
	my @placeholders = ($self->conf->get('db/database'));
	$query = 'SELECT table_name FROM INFORMATION_SCHEMA.tables WHERE table_schema=? AND table_name LIKE "streams%"' . "\n" .
		'AND ((create_time >= FROM_UNIXTIME(?) AND update_time < FROM_UNIXTIME(?)) ' .
		'OR FROM_UNIXTIME(?) BETWEEN create_time AND update_time OR FROM_UNIXTIME(?) BETWEEN create_time AND update_time)';
	push @placeholders, $start, $end, $start, $end;
	
	$sth = $self->db->prepare($query);
	$self->log->debug('Find tables query: ' . $query . ', placeholders: ' . join(',', @placeholders));
	$sth->execute(@placeholders);
	my @tables;
	while (my $row = $sth->fetchrow_hashref){
		push @tables, $row->{table_name};
	}
	# Now build the merge table
	$self->db->do('DROP TABLE IF EXISTS tmp_mrg') or die($DBI::errstr); # apparently, mysql doesn't like to redefine tmp merge tables sometimes
	$self->db->do('CREATE TEMPORARY TABLE tmp_mrg LIKE streams') or die($DBI::errstr);
	$query = 'ALTER TABLE tmp_mrg ENGINE=Merge UNION=(' . join(',', @tables) . ')';
	$self->log->debug('Merge table query: ' . $query) or die($DBI::errstr);
	$self->db->do($query);
	
	my $stats_select = 'SELECT COUNT(*) AS count, MIN(timestamp) AS min_timestamp, ' . 
		'MAX(timestamp) AS max_timestamp FROM tmp_mrg';
	
	my $data_select = 'SELECT offset, file_id, length, INET_NTOA(srcip) AS srcip, srcport, ' .
		'INET_NTOA(dstip) AS dstip, dstport, timestamp, FROM_UNIXTIME(timestamp) AS start, duration, reason, direction FROM tmp_mrg';
	@placeholders = ();
	my $where_clause = ' WHERE 1=1';
	
	if ($validated_params->{srcip}){
		$where_clause .= ' AND srcip=INET_ATON(?)';
		push @placeholders, $validated_params->{srcip};
	}
	elsif ($validated_not_params->{srcip}){
		$where_clause .= ' AND srcip!=INET_ATON(?)';
		push @placeholders, $validated_not_params->{srcip};
	}
	
	if ($validated_params->{dstip}){
		$where_clause .= ' AND dstip=INET_ATON(?)';
		push @placeholders, $validated_params->{dstip};
	}
	elsif ($validated_not_params->{dstip}){
		$where_clause .= ' AND dstip!=INET_ATON(?)';
		push @placeholders, $validated_not_params->{dstip};
	}
	
	if ($validated_params->{srcport}){
		$where_clause .= ' AND srcport=?';
		push @placeholders, $validated_params->{srcport};
	}
	elsif ($validated_not_params->{srcport}){
		$where_clause .= ' AND srcport!=?';
		push @placeholders, $validated_not_params->{srcport};
	}
	
	if ($validated_params->{dstport}){
		$where_clause .= ' AND dstport=?';
		push @placeholders, $validated_params->{dstport};
	}
	elsif ($validated_not_params->{dstport}){
		$where_clause .= ' AND dstport!=?';
		push @placeholders, $validated_not_params->{dstport};
	}
	
	if ($validated_params->{direction}){
		$where_clause .= ' AND direction=?';
		push @placeholders, $validated_params->{direction};
	}
	
	if ($validated_params->{reason}){
		$where_clause .= ' AND reason=?';
		push @placeholders, $validated_params->{reason};
	}
	elsif ($validated_not_params->{reason}){
		$where_clause .= ' AND reason!=?';
		push @placeholders, $validated_not_params->{reason};
	}
	
	if ($start){
		$where_clause .= ' AND timestamp >= ?';
		push @placeholders, $start;
	}
	
	if ($end != $now){
		$where_clause .= ' AND timestamp <= ?';
		push @placeholders, $end;
	}
	
	# Do the stats query
	$query = $stats_select . $where_clause;
	$sth = $self->db->prepare($query);
	$self->log->debug('stats query: ' . $query . ', placeholders: ' . join(',', @placeholders));
	$sth->execute(@placeholders);
	my $row = $sth->fetchrow_hashref;
	$self->log->debug('stats: ' . Dumper($row));
	my $ret = {
		totalRecords => $row->{count},
		min => $row->{min_timestamp},
		max => $row->{max_timestamp},
		rows => [],
	};
	
	# If we got no results, maybe we need to flip the src/dst
	if (not $ret->{totalRecords} and not $is_retry){
		if ($given_params->{srcip} and $given_params->{dstip}){
			my $tmp = $given_params->{dstip};
			$given_params->{dstip} = $given_params->{srcip};
			$given_params->{srcip} = $tmp;
		}
		elsif ($given_params->{srcip} and not $given_params->{dstip}){
			$given_params->{dstip} = delete $given_params->{srcip};
		}
		elsif ($given_params->{dstip} and not $given_params->{srcip}){
			$given_params->{srcip} = delete $given_params->{dstip};
		}
		
		if ($given_params->{srcport} and $given_params->{dstport}){
			my $tmp = $given_params->{dstport};
			$given_params->{dstport} = $given_params->{srcport};
			$given_params->{srcport} = $tmp;
		}
		elsif ($given_params->{srcport} and not $given_params->{dstport}){
			$given_params->{dstport} = delete $given_params->{srcport};
		}
		elsif ($given_params->{dstport} and not $given_params->{srcport}){
			$given_params->{dstport} = delete $given_params->{dstport};
		}
		
		# recurse and re-rerun with swapped params
		return $self->query($given_params, 1);
	}
	
	# limit and offset aren't actually in the query, it's an add-on param
	my $limit = $Default_limit;
	if ($validated_params->{limit}){
		$limit = int($validated_params->{limit});
	}
	my $offset = 0;
	if ($validated_params->{offset}){
		$offset = int($validated_params->{offset});
	}

	my $direction = 'ASC';
	if ($given_params->{sort}){
		$direction = 'DESC';
	}
	$query = $data_select . $where_clause . ' ORDER BY file_id ' . $direction . ', offset ' . $direction;
	if (not $validated_params->{pcre} and not $validated_params->{filetype}){
	 	$query .= ' LIMIT ?,?';
	 	push @placeholders, $offset, $limit;
	}
	
	# set pcre
	my $pcre;
	if ($validated_params->{pcre}){
		$pcre = qr/$validated_params->{pcre}/;
		$self->log->debug('searching for pcre ' . Dumper($pcre));
	}
	
	$self->log->debug('query: ' . $query . ', placeholders: ' . join(',', @placeholders));
	
	$sth = $self->db->prepare($query);
	$sth->execute(@placeholders);
	
	# Group the rows by file_id for more efficient retrieval
	my $file_ids = {};
	ROW_LOOP: while (my $row = $sth->fetchrow_hashref and scalar @{ $ret->{rows} } < $limit){
		# Cache the file handle here
		unless ($file_ids->{ $row->{file_id} }){
			my $fh = new IO::File;
			my $file_name = sprintf('%s/streams_%d', $self->conf->get('data_dir'), $row->{file_id});
			$fh->open($file_name) or die($!);
			$fh->binmode(1);
			$file_ids->{ $row->{file_id} } = $fh;
		}
		
		# Retrieve the actual data from the data file at the given offset
		$file_ids->{ $row->{file_id} }->seek($row->{offset}, 0) or die($!);
		my $buf;
		my $num_read = $file_ids->{ $row->{file_id} }->read($buf, $row->{length}, 0) 
			or (push @{ $ret->{rows} }, $row and next);
		
		# Parse for filetype meta content	
		if ($validated_params->{raw}){
			$row->{objects} = [ { data => $buf, meta => '' } ];
		}
		else {
			$row->{objects} = $self->_parse_content($buf);
		}
		
		$row->{data} = [];
		for (my $i = 0; $i < @{ $row->{objects} }; $i++){
			my $object = $row->{objects}->[$i];
			# Perform filetype match if requested
			if ($validated_params->{filetype}){
				#$self->log->trace('Checking meta ' . $meta . ' against ' . $validated_params->{filetype});
				if ($object->{meta} !~ /$validated_params->{filetype}/i){
					next;
				}
			}
			
			my $oid_str = 'oid=' . $self->_make_object_id($row, $i) . "\n\n";
		
			# Perform pcre match if requested
			if (defined $pcre){
				if ($object->{data} =~ $pcre){
					push @{ $row->{data} }, $oid_str . $self->_make_printable($object->{data}, $validated_params->{as_hex});
				}
			}
			else {
				push @{ $row->{data} }, $oid_str . $self->_make_printable($object->{data}, $validated_params->{as_hex});
			}
		}
		push @{ $ret->{rows} }, $row if scalar @{ $row->{data} };
	}
	
	# Experimental code for submitting data objects to VirusTotal
	if ($self->{_STREAMDB_SUBMIT_FILETYPE}){
		foreach my $row (@{ $ret->{rows} }){
			$row->{data} = '';
			foreach my $object (@{ $row->{objects} }){
				next if $object->{meta} =~ /INCOMPLETE/; # we know this is invalid, so don't bother submitting
				if ($object->{meta} =~ $self->{_STREAMDB_SUBMIT_FILETYPE}){
					$row->{data} .= Dumper($self->_submit($object->{data})) . "\n" . $object->{data};
					next;
				}
			}
		}
	}
		
	$ret->{recordsReturned} = scalar @{ $ret->{rows} };
	$ret->{startIndex} = $offset;
		
	return $ret;
}

sub get_object {
	my $self = shift;
	my $oid = shift;
	
	unless ($oid =~ /^(\d+)\-(\d+)\-(\d+)\-(\d+)$/){
		die('Invalid oid given');
	}
	my ($file_id, $offset, $length, $id) = ($1, $2, $3, $4);
	
	my $fh = new IO::File;
	my $file_name = sprintf('%s/streams_%d', $self->conf->get('data_dir'), $file_id);
	$fh->open($file_name) or die($!);
	$fh->binmode(1);
	$fh->seek($offset, 0) or die($!);
	my $buf;
	my $num_read = $fh->read($buf, $length, 0) or die('Data not found with oid ' . $oid);
	my $objects = $self->_parse_content($buf);
	return $objects->[$id];
}

sub _make_object_id {
	my $self = shift;
	my $row = shift;
	my $object_index = shift;
	
	return join('-', $row->{file_id}, $row->{offset}, $row->{length}, $object_index);
}

sub _parse_content {
	my $self = shift;
	my $buf = shift;
	
	my $orig = $buf;
	
	#$self->log->debug('buf: ' . Hexify($buf));
	
	my $objects = [];
	
	my $regexp = qr/^HTTP\/1\./;
	if ($buf =~ $regexp){
		my $responses = $self->_parse_http($buf, 'response');
		if (ref($responses)){
			$self->log->debug('got ' . scalar @$responses . ' responses');
			$buf = '';
			foreach my $response (@$responses){
				my $meta;
				#$self->log->debug('response: ' . Dumper($response));
				my $ok = $response->decode();
				if ($ok){
					$meta = $self->magic->describe_contents($response->decoded_content()) if defined $response->decoded_content();
					if ($response->content_length() > length($response->decoded_content())){
						$meta .= ' (INCOMPLETE)';
					}
				}
				else {
					$self->log->error('Error decoding response.');
					$meta = $self->magic->describe_contents($response->as_string()) if defined $response->as_string();
				}
				push @$objects, { content => $response->content(), data => $response->as_string(), meta => $meta };
			}
		}
		else {
			$self->log->warn('Unable to decode response, using raw buffer');
			my $meta = $self->magic->describe_contents($buf);
			push @$objects, { content => $buf, data => $buf, meta => $meta };
		}
	}
	else {
		my $meta = $self->magic->describe_contents($buf);
		push @$objects, { content => $buf, data => $buf, meta => $meta };
	}
	
	return $objects;
}

sub _make_printable {
	my $self = shift;
	my $buf = shift;
	my $as_hex = shift;
	
	# Sanitize for printing
	if ($as_hex){
		$buf = Hexify($buf);
	}
	else {
		$buf =~ s/[^\w\s[:print:]]/\./g;
	}
		
	return $buf;
}


sub _parse_http {
	my $self = shift;
	my $buf = shift;
	my $type = shift;
	
	my @objects;
	
	while ($buf){
		my $parser =  HTTP::Parser->new($type => 1);
		my $status;       
		eval {
			$status = $parser->add($buf);
			$self->log->debug('status: ' . $status . ', extra: ' . $parser->extra);
		};
		if ($@){
			$self->log->warn("Error parsing request: $@");
			return 0;
		}
		if ($status == 0){
			push @objects, $parser->object();
			#$self->log->debug('object: ' . Dumper($parser->object()));
			$buf = $parser->data();
		}
		else {
			$self->log->error('Parse error: status: ' . $status . ' state: ' . $parser->{state} . ' data left: ' . "\n" . length($parser->{data}));
			$objects[-1] and $objects[-1]->content($parser->{data});
			last;
		}
	}
	#$self->log->debug('objects: ' . Dumper(\@objects));
	
	return \@objects;
}

sub _submit {
	my $self = shift;
	my $data = shift;
	
	my $sha1 = sha1_hex($data);
	my $ret = {};
	$self->{_STREAMDB_SUBMITTED} ||= {};
	$self->log->debug('data sha1: ' . $sha1);
	if ($self->{_STREAMDB_SUBMITTED}->{$sha1}){
		return $self->{_STREAMDB_SUBMITTED}->{$sha1};
	}
	
	if ($self->conf->get('virustotal')){
		require VT::API;
		my $vt = new VT::API(key => $self->conf->get('virustotal/apikey'));
		
		
		my $result = $vt->get_file_report($sha1);
		if ($result and $result->{result}){
			$self->log->debug('Got cached virustotal result: ' . Dumper($result));
			$ret->{virustotal} = $result;
		}
		else {
			my ($fh, $filename) = tempfile();
			$fh->write($data);
			$fh->close;
			$result = $vt->scan_file($filename);
			unlink $filename;
			if ($result and $result->{result}){
				$self->log->debug('Submitted to virustotal with scan_id: ' . Dumper($result));
				$ret->{virustotal} = 'http://www.virustotal.com/file-scan/report.html?id=' . $result->{scan_id};
			}
			else {
				$self->log->error('Virustotal error');
			}
		}
	}
	
	$self->{_STREAMDB_SUBMITTED}->{$sha1} = $ret;
	return $ret;
}


1;

__END__
