StreamDB is a high-performance framework for storing network streams.  The current version uses Vortex IDS to read the streams from a file or network interface and saves them to an indexed DB and data file.  Web code provides a URL-based query interface.  There is also a command-line interface which includes the ability to read piped queries from STDIN.  In addition to almost instant retrieval by IP address, StreamDB also allows PCRE searches and file type searches on streams if an IP address is provided as an initial filter.  The system can handle recording gigabit linespeed networks and can retrieve arbitrary streams from terabytes of data in milliseconds.  It is designed to be a complimentary tool to intrusion detection systems to aid security analysts.

Here are some query examples:
```
http://streamdb/?srcip=10.0.0.1
http://streamdb/?dstip=10.0.0.1
http://streamdb/?srcip=10.0.0.1&dstip=1.1.1.1
http://streamdb/?srcip=10.0.0.1&dstip=1.1.1.1&dstport=80
http://streamdb/?srcip=10.0.0.1&dstip=1.1.1.1&dstport=80&start=2011-01-22 00:00:00
http://streamdb/?srcip=10.0.0.1&dstip=1.1.1.1&dstport=80&start=2011-01-22 00:00:00&end=2011-01-23 00:00:00
http://streamdb/?srcip=10.0.0.1&dstip=1.1.1.1&dstport=80&start=2 weeks ago&end=now
http://streamdb/?srcip=10.0.0.1&pcre=example.com
http://streamdb/?srcip=10.0.0.1&pcre=\xff\xff\xff\xff\xff
http://streamdb/?srcip=10.0.0.1&sort=1&as_hex=1
http://streamdb/?srcip=10.0.0.1&raw=1
http://streamdb/?srcip=10.0.0.1&offset=1000&limit=200
http://streamdb/?srcip=10.0.0.1&filetype=executable
http://streamdb/?srcip=10.0.0.1&dstport!80
http://streamdb/?oid=2323-332-1-0
```