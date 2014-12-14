FCGI Experiments
================

This is my experiments with FCGI
The script presents registration/login form and personal cabinet.

```
Usage:   ./forking.pl host backlog count
Example: ./forking.pl 127.0.0.1:9000 100 5
```

This script creates N instances of FCGI apps, and one instance of DB app;
In this project, DB is just a hash variable;

Part of NGINX config:

```
location / { 
    try_files $uri @index;
}

location @index {
    include      fastcgi_params;
    fastcgi_pass 127.0.0.1:9000;
}
```
