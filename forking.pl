#!/usr/bin/perl

use strict;
use warnings;

use FCGI;

my $term = 0;

$\ = "\n";
$SIG{INT} = sub { $term = 1 };

&main;

sub main {
    if(scalar @ARGV < 3) {
        print 'Error. Usage: $path $backlog $count';
        exit();
    }

    my $path    = $ARGV[0];
    my $backlog = int($ARGV[1]);
    my $count   = int($ARGV[2]);

    print "[$$-Manager] Starting...";

    my $socket = FCGI::OpenSocket($path, $backlog);
    if(!$socket) {
        print "Error. Failed to open socket.";
        exit();
    }

    for (1..$count) {
        my $pid = fork();
        process_fcgi($socket) unless($pid);
    }

    print "[$$-Manager] Working...\n";

    print "[$$-Manager] Closing socket $path ...";
    FCGI::CloseSocket($socket);

    while(!$term) {
        sleep(2);
    }

    print "[$$-Manager] Terminating all FCGIs...";
        #kill('TERM', $pid);
    sleep(3);
        #print "[$$] Closed $pid";
    print "[$$-Manager] Exiting...\n";
    exit(0);
}

sub process_fcgi {
    my $socket = shift;

    print "[$$-FCGI] Created";

    my $count = 0;
    my $request = FCGI::Request(
       \*STDIN, \*STDOUT, \*STDERR,
       \%ENV, int($socket || 0), 1
    );

    while($request->Accept() >= 0) {
        print "Content-type:text/plain;charset=utf-8\r\n\r\n";
        print "[$$]";
        print "Counter: $count";
        ++$count;
    }

    print "[$$-FCGI] Closing...";
    exit(0);
}
