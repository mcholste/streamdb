#!/usr/bin/perl

# Receives a file upload from StreamDB.  Invoke via
# plackup -p 80 -D
# or use starman
# starman --listen :80 --daemonize

use strict;
use Plack::Builder;

builder {
        mount '/' => builder {
                App->new()->to_app;
        };
};

package App;
use strict;
use Data::Dumper;
use base qw(Plack::Component);
use Plack::Request;

our $Sandbox_drop_folder = '/home/cuckoo/cuckoo/inbox';

sub call {
        my ($self, $env) = @_;

        my $req = Plack::Request->new($env);
        my $res = $req->new_response(200);
        $res->body(Dumper($req->uploads));
        my $file =  $Sandbox_drop_folder . '/' . $req->uploads->{'filename'}->filename;
        open(FH, "> $file");
        my $content = $req->content;
        $content =~ /\x0d\x0a(MZ.*)/; # Trim MIME header
        print FH $1;
        close(FH);
        qx(/home/cuckoo/run-sample.sh $file);
        $res->finalize;
}
