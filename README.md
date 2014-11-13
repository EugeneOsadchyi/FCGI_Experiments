FCGI_Experiments
================

My experiments with FCGI

Usage: ./forking.pl 127.0.0.1:9000 100 1

This script creates N instances of FCGI apps. 
Every connection to it's port increments script's inner counter. 

You are able to see this value in your browser. 
