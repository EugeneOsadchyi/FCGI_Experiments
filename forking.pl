#!/usr/bin/perl

use strict;
use warnings;

use FCGI;

my $term = 0;

$\ = "\n";
$SIG{TERM} = sub{};
$SIG{INT} = sub { $term = 1 };

if(scalar @ARGV < 3) {
    print 'Error. Usage: $path $backlog $count';
    exit();
}

my $path    = $ARGV[0];
my $backlog = int($ARGV[1]);
my $count   = int($ARGV[2]);

print "[$$] Starting manager...";

my $socket = FCGI::OpenSocket($path, $backlog);
if(!$socket) {
    print "Error. Failed to open socket.";
    exit();
}

for (1..$count) {
    my $pid = fork();

    if($pid) {
        print "[$$] Started FCGI script $pid";
        print "[$$] Working...\n";

        FCGI::CloseSocket($socket);

        print "[$$] Closed $path SOCKET in manager";

    } else {
        print "[$$] I am FCGI script";

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

        print "[$$] FCGI exiting...";
        exit(0);
    }
}

while(!$term) {
    sleep(2);
}

print "[$$] Closing all FCGI childs...";
    #kill('TERM', $pid);

sleep(3);
    #print "[$$] Closed $pid";


print "[$$] Exiting manager...\n";
exit(0);
