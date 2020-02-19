#!/bin/bash

if [ ! -p /home/vagrant/host_queue ]; then
    mkfifo -m 0600 /home/vagrant/host_queue
fi

nohup tail -f /home/vagrant/host_queue | sh &
