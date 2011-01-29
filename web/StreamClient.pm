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
#use File::LibMagic qw(:easy);

has 'log' => ( is => 'ro', isa => 'Log::Log4perl::Logger', required => 1 );
has 'conf' => ( is => 'ro', isa => 'Config::JSON', required => 1 );
has 'db' => ( is => 'rw', isa => 'Object', required => 0 );

our %Query_params = (
	srcip => qr/^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/,
	dstip => qr/^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/,
	srcport => qr/^\d{1,5}$/,
	dstport => qr/^\d{1,5}$/,
	start => qr/.+/, # start/end will be run through a parser for sanitization
	end => qr/.+/,
	offset => qr/^\d+$/,
	limit => qr/^\d{1,5}$/,
	pcre => qr/.+/,
	as_hex => qr/.+/,
	raw => qr/.+/,
	sort => qr/.+/,
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
		my $result;
		if ($req->query_parameters->{pcre}){
			$result = $self->pcre_query($req->query_parameters);
		}
		else {
			$result = $self->query($req->query_parameters);
		}
		
		$body .= 'Returning ' . (scalar @{ $result->{rows} }) . ' of ' . $result->{totalRecords} 
			. ' at offset '. $result->{startIndex}. ' from ' .(scalar localtime($result->{min}))
			. ' to ' . (scalar localtime($result->{max})) . "\n\n";
		foreach my $row (sort { $a->{timestamp} <=> $b->{timestamp} } @{ $result->{rows} }){
			$body .= sprintf("%s %s:%d %s %s:%d %ds %d bytes %s\n\n%s\n\n", $row->{start}, 
				$row->{srcip}, $row->{srcport}, $row->{direction} eq 'c' ? '<-' : '->',
				$row->{dstip}, $row->{dstport}, $row->{duration}, $row->{length}, $Reasons{ $row->{reason} }, $row->{data});
		}
	};
	if ($@){
		my $e = $@;
		$self->log->error($e);
		$body = $e . "\n" . $self->_usage();
	}
    $res->body($body);
    #$self->_get_headers($title)
    $res->finalize;
}

sub _usage {
	my $self = shift;
	my $msg = <<'EOT'

Usage: 
srcip => qr/^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/,
dstip => qr/^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/,
srcport => qr/^\d{1,5}$/,
dstport => qr/^\d{1,5}$/,
start => qr/.+/,
end => qr/.+/,
offset => qr/^\d+$/,
limit => qr/^\d{1,5}$/,
pcre => qr/.+/,
as_hex => qr/.+/,
raw => qr/.+/, (do not gunzip/dechunk HTTP responses)
sort => qr/.+/, (sort in reverse order)
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
		if (not $Query_params{$param} or $given_params->{$param} !~ $Query_params{$param}){
			die('Invalid param: ' . $param . '=' . $given_params->{$param});
		}
	}
	
	my $start = 0;
	my $now = time();
	my $end = $now;
	if ($given_params->{start} and $given_params->{start} =~ /^\d+$/){
		# Fine as is
		$start = $given_params->{start};
	}
	elsif ($given_params->{start}){
		$start = UnixDate(ParseDate($given_params->{start}), '%s');
	}
	
	if ($given_params->{end} and $given_params->{end} =~ /^\d+$/){
		# Fine as is
		$end = $given_params->{end};
	}
	elsif ($given_params->{end}){
		$end = UnixDate(ParseDate($given_params->{end}), '%s');
	}
	
	my ($query, $sth);
	
	# Create our temporary merge table
	my @placeholders = ($self->conf->get('db/database'));
	$query = 'SELECT table_name FROM INFORMATION_SCHEMA.tables WHERE table_schema=? AND table_name LIKE "streams%"' . "\n" .
		'AND ((create_time >= ? AND update_time < FROM_UNIXTIME(?)) ' .
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
	$self->db->do('DROP TABLE tmp_mrg'); # in case it was there from previous query
	$query = 'CREATE TEMPORARY TABLE tmp_mrg LIKE streams';
	$self->db->do($query);
	$query = 'ALTER TABLE tmp_mrg ENGINE=Merge UNION=(' . join(',', @tables) . ')';
	$self->log->debug('Merge table query: ' . $query);
	$self->db->do($query);
	
	my $stats_select = 'SELECT COUNT(*) AS count, MIN(timestamp) AS min_timestamp, ' . 
		'MAX(timestamp) AS max_timestamp FROM tmp_mrg';
	
	my $data_select = 'SELECT offset, file_id, length, INET_NTOA(srcip) AS srcip, srcport, ' .
		'INET_NTOA(dstip) AS dstip, dstport, FROM_UNIXTIME(timestamp) AS start, duration, reason, direction FROM tmp_mrg';
	@placeholders = ();
	my $where_clause = ' WHERE 1=1';
	
	# Translate ip to srcip or dstip
	if ($given_params->{ip}){
		$where_clause .= ' AND (srcip=INET_ATON(?) OR dstip=INET_ATON(?)';
		push @placeholders, $given_params->{ip}, $given_params->{ip};
	}
	if ($given_params->{srcip}){
		$where_clause .= ' AND srcip=INET_ATON(?)';
		push @placeholders, $given_params->{srcip};
	}
	if ($given_params->{dstip}){
		$where_clause .= ' AND dstip=INET_ATON(?)';
		push @placeholders, $given_params->{dstip};
	}
	if ($given_params->{srcport}){
		$where_clause .= ' AND srcport=?';
		push @placeholders, $given_params->{srcport};
	}
	if ($given_params->{dstport}){
		$where_clause .= ' AND dstport=?';
		push @placeholders, $given_params->{dstport};
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
	if ($given_params->{limit}){
		$limit = int($given_params->{limit});
	}
	my $offset = 0;
	if ($given_params->{offset}){
		$offset = int($given_params->{offset});
	}
	my $order_by_dir = 'ASC';
	if ($given_params->{sort}){
		$order_by_dir = 'DESC';
	}
	$query = $data_select . $where_clause . ' ORDER BY file_id, offset ' . $order_by_dir . ' LIMIT ?,?';
	push @placeholders, $offset, $limit;
	
	# set pcre
	my $pcre;
	if ($given_params->{pcre}){
		$pcre = qr/$given_params->{pcre}/;
		$self->log->debug('searching for pcre ' . Dumper($pcre));
	}
	
	$self->log->debug('query: ' . $query . ', placeholders: ' . join(',', @placeholders));
	
	$sth = $self->db->prepare($query);
	$sth->execute(@placeholders);
	
	my @rows;
	# Group the rows by file_id for more efficient retrieval
	my $file_ids = {};
	while (my $row = $sth->fetchrow_hashref){
		unless ($file_ids->{ $row->{file_id} }){
			my $fh = new IO::File;
			my $file_name = sprintf('%s/streams_%d', $self->conf->get('data_dir'), $row->{file_id});
			$fh->open($file_name) or die($!);
			$fh->binmode(1);
			$file_ids->{ $row->{file_id} } = {
				fh => $fh,
				rows => [],
			};
		}
		push @{ $file_ids->{ $row->{file_id} }->{rows} }, $row;
	}
	
	foreach my $file_id (keys %$file_ids){
		foreach my $row (@{ $file_ids->{ $file_id }->{rows} }){
			my $buf;
			
			$file_ids->{ $file_id }->{fh}->seek($row->{offset}, 0) or die($!);
			my $num_read = $file_ids->{ $file_id }->{fh}->read($buf, $row->{length}, 0) 
				or (push @{ $ret->{rows} }, $row and next);
			
			$buf = $self->_parse_content($buf) unless $given_params->{raw};
			
			# Perform pcre match if requested
			if (defined $pcre){
				if ($buf =~ $pcre){
					$row->{data} = $self->_make_printable($buf, $given_params->{as_hex});
					push @{ $ret->{rows} }, $row;
				}
			}
			else {
				$row->{data} = $self->_make_printable($buf, $given_params->{as_hex});
				push @{ $ret->{rows} }, $row;
			}
		}
	}
	
	$ret->{recordsReturned} = scalar @{ $ret->{rows} };
	$ret->{startIndex} = $offset;
		
	return $ret;
}

sub pcre_query {
	my $self = shift;
	my $given_params = shift;
	die ('no srcip or dstip given') unless ($given_params->{srcip} or $given_params->{dstip});
	my $original_limit = delete $given_params->{limit};
	my $query = $given_params;
	$query->{limit} = 1000;
	
	my @matches;
	my $offset = 0;
	my $total_searched = 0;
	my $bytes_searched = 0;
	my $total_to_search = 1;
	my ($min, $max);
	
	while ($total_searched < $total_to_search){
		$query->{offset} = $offset;
		my $res = $self->query($query);
		$total_to_search = $res->{totalRecords} unless $total_to_search;
		$min = $res->{min};
		$max = $res->{max};
		foreach my $r (@{ $res->{rows} }){
			$total_searched++; 
			$bytes_searched += $r->{length};
			if ($r->{data}){ 
				push @matches, $r; 
			}
		}
		$self->log->debug("offset: $offset, bytes: $bytes_searched"); 
		$offset += 1000;
		last if scalar @matches >= $original_limit;
	}
	return {
		rows => \@matches,
		recordsReturned => scalar @matches,
		totalRecords => $total_to_search,
		startIndex => 0,
		min => $min,
		max => $max
	}
}

sub _parse_content {
	my $self = shift;
	my $buf = shift;
	my $orig = $buf;
	
	#TODO all kinds of content parsers here
#	my $meta = '';
#	if ($buf){
#		$meta = MagicBuffer($buf);
#	}
	#$self->log->debug('buf: ' . Hexify($buf));
	
	my $regexp = qr/^HTTP\/1\./;
	if ($buf =~ $regexp){
		my $responses = $self->_parse_http($buf, 'response');
		$self->log->debug('got ' . scalar @$responses . ' responses');
		$buf = '';
		foreach my $response (@$responses){
			#$self->log->debug('response: ' . Dumper($response));
			my $ok = $response->decode();
			unless ($ok){
				$self->log->error('Error decoding response.');
			}
			
			$buf .= $response->as_string();
		}
	}
	
	return $buf ? $buf : $orig;
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
		};
		if ($@){
			$self->log->warn("Error parsing request: $@");
			last;
		}
		if ($status == 0){
			push @objects, $parser->object();
			#$self->log->debug('object: ' . Dumper($parser->object()));
			$buf = $parser->data();
		}
		else {
			$self->log->error('Parse error: status: ' . $status . ' state: ' . $parser->{state} . ' data left: ' . "\n" . length($parser->{data}));
			last;
		}
	}
	
	return \@objects;
}

1;

__END__
