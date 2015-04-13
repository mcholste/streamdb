# Introduction #

Explanation of the streamdb.conf config file.

# Example Config #

The only two config items that must be set to be correct are "data\_dir" which defines where the streams will permanently reside (there must be a lot of disk available on this partition), and "interface," which determines which ethernet interface to listen on.

```
{
        "retention": {
                "size": 50000000000 # maximum size in bytes before deleting oldest streams
        },
        "logdir": "/tmp", # where to send streamdb runtime logs
        "debug_level": "TRACE", # level at which to log
        "rollover_check_frequency": 20, # how often to check if we're overlimit (should not need to change)
        "db": { # connection information for the MySQL database
                "host": "localhost",
                "port": 3306,
                "database": "test",
                "username": "root",
                "password": ""
        },
        # !! interface is required !!
        "interface": "eth1", # interface to monitor
        "buffer_dir": "/dev/shm/", # where to write the temporary buffer files.  /dev/shm is memory
        # !! data_dir is required !!
        "data_dir": "/tmp", # where to keep the final raw stream files. These will get very large and should get their own partition.
        "collect_limit": 1000000, # max bytes per stream to collect
        "options": "-K 60", # stream timeout in seconds
        "vortex": "/usr/local/bin/vortex", # location of the vortex binary to use
        "daemonize": 1, # always run as a daemon (no need to add -D to streamdb.pl command line)
        "pid_file": "/var/run/streamdb.pid", # location of the pid file
}
```