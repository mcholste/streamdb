# Introduction #

Vortex IDS reads from the network and reassembles packets into streams.  This is a step-by-step how-to install Vortex.

# Get libnids #

Requirements (in Ubuntu package names): libglib2.0-dev libpcre3 libnet1 libpcap0.8-dev

Note: I highly recommend using a PF\_RING-enabled libpcap if you are monitoring a link with more than 100 Mb/sec.  See my write-up here: http://ossectools.blogspot.com/2011/09/bro-quickstart-cluster-edition.html for install help.

```
wget "http://surfnet.dl.sourceforge.net/project/libnids/libnids/1.24/libnids-1.24.tar.gz"
tar xzf libnids-1.24.tar.gz
cd libnids-1.24
./configure && make && sudo make install
```

# Get Vortex #
```
cd /tmp/vortex_install
wget "http://downloads.sourceforge.net/project/vortex-ids/vortex/2.9.0/vortex-2.9.0.tgz?r=http%3A%2F%2Fsourceforge.net%2Fprojects%2Fvortex-ids%2F&ts=1295723515&use_mirror=softlayer"
wget "http://downloads.sourceforge.net/project/vortex-ids/libbsf/1.0.1/libbsf-1.0.1.tgz?r=http%3A%2F%2Fsourceforge.net%2Fprojects%2Fvortex-ids%2Ffiles%2Flibbsf%2F1.0.1%2F&ts=1295723688&use_mirror=softlayer"
tar xzvf libbsf-1.0.1.tgz && cd libbsf
gcc -g -O3 -fPIC -shared -Wl,-soname,libbsf.so.1.0.1 libbsf.c -o libbsf.so.1.0.1
/usr/bin/install -c -c -m 644 libbsf.so.1.0.1 /usr/local/lib
ln -s /usr/local/lib/libbsf.so.1.0.1 /usr/local/lib/libbsf.so
/usr/bin/install -c -c -m 644 bsf.h /usr/local/include
cd /tmp/vortex_install
tar xzvf vortex-2.9.0.tgz && cd vortex-2.9.0
gcc -I/usr/local/include -O3 vortex.c -o vortex -lnids -lpthread -lbsf -DWITH_BSF -lpcap -lglib-2.0 -lnet -lgthread-2.0 -lrt
/usr/bin/install -c -c -m 755 vortex /usr/local/bin

```

# Install StreamDB #
It is **strongly** recommended that you install App::cpanminus first, as it provides the command line utility cpanm, which is vastly superior to the default cpan command line tool.  You can do this like so:
```
cpan App::cpanminus
```

Install the following Perl modules
```
cpanm File::Slurp
cpanm Config::JSON
cpanm Log::Log4perl
cpanm DBD::mysql
```

Once the components are installed, you can unzip the streamdb tarball and test everything out like this:
perl streamdb.pl -i eth1 -a test -d /tmp -b /tmp

Once this works, it is highly recommend you install a config file.  An example is distributed in this package.

On the web node (they can be the same host):
```
cpanm Config::JSON
cpanm Log::Log4perl
cpanm DBD::mysql
cpanm Plack
cpanm Moose
cpanm Date::Manip
cpanm HTTP::Parser
cpanm Encode
cpanm Data::Hexify
```

The Plack Perl web framework allows you to run a .psgi file from the command line.  To test the web interface, use Plackup (part of the Plack::Request package).  You will need a config file, but to start with you can use the one included in this package.  Start plackup like so:
STREAMDB\_CONF=../streamdb.conf plackup StreamDB.psgi
You can run plackup as a daemon if you want to serve the streams directly from the sensor over a web interface but you don't want to install Apache on the sensor.

You can also run it from Apache.  To run from Apache:
```
cpanm Plack::Handler::Apache2
```
Here's an example vhost config which assumes you've installed StreamDB to /usr/local/streamdb and runs at http://streamdb/ (you'll have to edit your hosts file or setup a proper DNS name to get to it):
```
<VirtualHost "*:80">
        ServerName streamdb
        <Location "/">
                Order Allow,Deny
                Allow from all
                SetHandler perl-script
                PerlSetEnv PERL5LIB /usr/local/streamdb/web
                PerlResponseHandler Plack::Handler::Apache2
                PerlSetVar psgi_app /usr/local/streamdb/web/StreamDB.psgi
        </Location>
</VirtualHost>
```

If you want the run vortex on one node and the web server on another (probably the best idea), then you will need to make the files on the sensor available over NFS and edit the streamdb.conf on the web sensor to point the data\_dir to the NFS directory (/mnt/nfs or whatever).  Just make sure that "data\_dir" in the streamdb.conf is configured.  The NFS setup on the vortex node would be:

edit /etc/exports:
/path/to/streamdb/data\_dir web.host.ip.address(ro,insecure,no\_root\_squash)

And on the web host:
```
mkdir /mnt/nfs
mount -t nfs vortex.host.ip.address:/path/to/streamdb/data /mnt/nfs -o soft,nolock,intr
```